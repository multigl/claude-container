flavor     := env_var_or_default("FLAVOR", "vertex")
image      := env_var_or_default("IMAGE", "claude-" + flavor + ":latest")
bin_dir    := env_var_or_default("BIN_DIR", env_var("HOME") + "/.local/bin")
gcloud_vol := env_var_or_default("GCLOUD_VOL", "claude-vertex-gcloud")
okta_vol   := env_var_or_default("OKTA_VOL", "claude-gateway-okta")
here       := justfile_directory()

# Show available recipes
default:
    @just --list --unsorted

# Build the {{flavor}} image (FLAVOR=vertex|gateway)
build:
    docker build --target {{flavor}} -t {{image}} {{here}}

# Rebuild the {{flavor}} image without cache
rebuild:
    docker build --no-cache --target {{flavor}} -t {{image}} {{here}}

# Update claude-code: rebuild {{flavor}} pinned to the latest published version.
# The container's claude-code is deliberately non-self-updating (pinned + ephemeral
# + non-root), so this is how you move it forward. Resolves latest from npm and
# passes it as CLAUDE_CODE_VERSION; the changed build arg busts just that layer.
# Override the target version with the CLAUDE_CODE_VERSION env var.
update:
    ver="${CLAUDE_CODE_VERSION:-$(npm view @anthropic-ai/claude-code version)}"; \
    docker build --target {{flavor}} --build-arg CLAUDE_CODE_VERSION="$ver" \
        -t {{image}} {{here}}; \
    echo ">> built {{image}} with claude-code $ver"

# Build the vertex image
build-vertex:
    docker build --target vertex -t claude-vertex:latest {{here}}

# Build the gateway image
build-gateway:
    docker build --target gateway -t claude-gateway:latest {{here}}

# Build both images (shared base layer is cached, so the second is cheap)
build-all: build-vertex build-gateway

# Rebuild the vertex image without cache
rebuild-vertex:
    docker build --no-cache --target vertex -t claude-vertex:latest {{here}}

# Rebuild the gateway image without cache
rebuild-gateway:
    docker build --no-cache --target gateway -t claude-gateway:latest {{here}}

# Rebuild both images from scratch (base built no-cache once, then reused)
rebuild-all:
    docker build --no-cache --target vertex -t claude-vertex:latest {{here}}
    docker build --target gateway -t claude-gateway:latest {{here}}

# One-time login for {{flavor}} (gcloud ADC, or Okta device login) -> docker volume
auth:
    CLAUDE_FLAVOR={{flavor}} {{here}}/claude-launcher.sh auth

# Run all test suites: gateway Okta helper (pytest) + bash suites (merge, paths)
test:
    uv run pytest -q
    {{here}}/tests/run.sh

# Run `claude` against the current directory (uses {{flavor}})
run:
    CLAUDE_FLAVOR={{flavor}} {{here}}/claude-launcher.sh

# Open a bash shell inside the container
shell:
    CLAUDE_FLAVOR={{flavor}} {{here}}/claude-launcher.sh shell

# Overwrite host config's seeded files (settings + plugins) from the image
reseed:
    CLAUDE_FLAVOR={{flavor}} {{here}}/claude-launcher.sh reseed

# Symlink wrapper to {{bin_dir}}/claude-{{flavor}}
install:
    mkdir -p {{bin_dir}}
    ln -sf {{here}}/claude-launcher.sh {{bin_dir}}/claude-{{flavor}}
    @echo "installed: {{bin_dir}}/claude-{{flavor}}"
    @echo "ensure {{bin_dir}} is on PATH"

# Symlink BOTH flavor commands (claude-vertex + claude-gateway) to the launcher
install-all:
    mkdir -p {{bin_dir}}
    ln -sf {{here}}/claude-launcher.sh {{bin_dir}}/claude-vertex
    ln -sf {{here}}/claude-launcher.sh {{bin_dir}}/claude-gateway
    @echo "installed: {{bin_dir}}/claude-vertex and {{bin_dir}}/claude-gateway"
    @echo "ensure {{bin_dir}} is on PATH"

# Remove the wrapper symlinks
uninstall:
    rm -f {{bin_dir}}/claude-vertex {{bin_dir}}/claude-gateway

# Wipe the {{flavor}} credential volume (forces re-auth)
reset-auth:
    @if [ "{{flavor}}" = "vertex" ]; then docker volume rm {{gcloud_vol}} || true; \
     else docker volume rm {{okta_vol}} || true; fi

# Remove the {{flavor}} image
clean:
    docker rmi {{image}} || true

# Self-check: docker running, image built, flavor auth present, wrapper on PATH
doctor:
    @echo "== docker =="
    @docker version --format 'client: {{{{.Client.Version}}}}  server: {{{{.Server.Version}}}}' \
        || { echo "  FAIL: docker not running"; exit 1; }
    @echo "== image ({{flavor}}) =="
    @docker image inspect {{image}} >/dev/null 2>&1 \
        && echo "  ok: {{image}} present (claude-code $(docker run --rm {{image}} claude --version 2>/dev/null || echo '?'))" \
        || echo "  MISSING: run 'just build' (FLAVOR={{flavor}})"
    @echo "== auth ({{flavor}}) =="
    @if [ "{{flavor}}" = "vertex" ]; then \
        docker volume inspect {{gcloud_vol}} >/dev/null 2>&1 \
            && echo "  ok: volume {{gcloud_vol}} exists" \
            || echo "  MISSING: run 'just auth'"; \
        docker run --rm -v {{gcloud_vol}}:/g alpine \
            test -f /g/application_default_credentials.json 2>/dev/null \
            && echo "  ok: ADC credentials present" \
            || echo "  MISSING ADC: run 'just auth'"; \
    else \
        docker volume inspect {{okta_vol}} >/dev/null 2>&1 \
            && docker run --rm -v {{okta_vol}}:/v alpine \
                test -f /v/okta.json 2>/dev/null \
            && echo "  ok: Okta token cache present" \
            || echo "  MISSING: run 'FLAVOR=gateway just auth'"; \
        env="${XDG_CONFIG_HOME:-$HOME/.config}/vida-claude-container/gateway/env"; \
        if [ -f "$env" ] && grep -Eq '^OKTA_CLIENT_ID=.+' "$env"; then \
            echo "  ok: OKTA_CLIENT_ID set in $env"; \
        else echo "  MISSING: set OKTA_CLIENT_ID in $env"; fi; \
    fi
    @echo "== wrapper on PATH =="
    @command -v claude-{{flavor}} >/dev/null \
        && echo "  ok: $(command -v claude-{{flavor}})" \
        || echo "  MISSING: run 'just install' (or add {{bin_dir}} to PATH)"
