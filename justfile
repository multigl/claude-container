flavor     := env_var_or_default("FLAVOR", "vertex")
image      := env_var_or_default("IMAGE", "claude-" + flavor + ":latest")
bin_dir    := env_var_or_default("BIN_DIR", env_var("HOME") + "/.local/bin")
here       := justfile_directory()

# Show available recipes
default:
    @just --list --unsorted

# Build the {{flavor}} image (FLAVOR=vertex|gateway) via the resolved runtime
build:
    {{here}}/bin/container-runtime.sh build --flavor {{flavor}} --image {{image}} --context {{here}}

# Rebuild the {{flavor}} image without cache
# TODO: rebuild-* still docker-specific (dispatcher build has no --no-cache flag yet)
rebuild:
    docker build -f {{here}}/Containerfile --no-cache --target {{flavor}} -t {{image}} {{here}}

# Update claude-code: rebuild {{flavor}} pinned to the latest published version.
# The container's claude-code is deliberately non-self-updating (pinned + ephemeral
# + non-root), so this is how you move it forward. Resolves latest from npm and
# passes it as CLAUDE_CODE_VERSION; the changed build arg busts just that layer.
# Override the target version with the CLAUDE_CODE_VERSION env var.
update:
    ver="${CLAUDE_CODE_VERSION:-$(npm view @anthropic-ai/claude-code version)}"; \
    CLAUDE_CODE_VERSION="$ver" {{here}}/bin/container-runtime.sh build --flavor {{flavor}} --image {{image}} --context {{here}}; \
    echo ">> built {{image}} with claude-code $ver"

# Build the vertex image
build-vertex:
    {{here}}/bin/container-runtime.sh build --flavor vertex --image claude-vertex:latest --context {{here}}

# Build the gateway image
build-gateway:
    {{here}}/bin/container-runtime.sh build --flavor gateway --image claude-gateway:latest --context {{here}}

# Build both images (shared base layer is cached, so the second is cheap)
build-all: build-vertex build-gateway

# Rebuild the vertex image without cache
rebuild-vertex:
    docker build -f {{here}}/Containerfile --no-cache --target vertex -t claude-vertex:latest {{here}}

# Rebuild the gateway image without cache
rebuild-gateway:
    docker build -f {{here}}/Containerfile --no-cache --target gateway -t claude-gateway:latest {{here}}

# Rebuild both images from scratch (base built no-cache once, then reused)
rebuild-all:
    docker build -f {{here}}/Containerfile --no-cache --target vertex -t claude-vertex:latest {{here}}
    docker build -f {{here}}/Containerfile --target gateway -t claude-gateway:latest {{here}}

# One-time login for {{flavor}} (gcloud ADC, or Okta device login) -> cred bind dir
auth:
    CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-launcher.sh auth

# Run all test suites: gateway Okta helper (pytest) + bash suites (merge, paths)
test:
    uv run pytest -q
    {{here}}/tests/run.sh

# Run `claude` against the current directory (uses {{flavor}})
run:
    CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-launcher.sh

# Open a bash shell inside the container
shell:
    CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-launcher.sh shell

# Overwrite host config's seeded files (settings + plugins) from the image
reseed:
    CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-launcher.sh reseed

# Symlink wrapper to {{bin_dir}}/claude-{{flavor}}
install:
    {{here}}/install.sh --local --flavor {{flavor}}

# Symlink BOTH flavor commands (claude-vertex + claude-gateway) to the launcher
install-all:
    {{here}}/install.sh --local --all

# Remove the wrapper symlinks
uninstall:
    rm -f {{bin_dir}}/claude-vertex {{bin_dir}}/claude-gateway

# Wipe the {{flavor}} credentials (forces re-auth). Creds are bind dirs now.
reset-auth:
    @paths="$(CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-launcher.sh --print-paths)"; \
        g="$(printf '%s\n' "$paths" | sed -n 's/^CRED_GCLOUD_DIR=//p')"; \
        o="$(printf '%s\n' "$paths" | sed -n 's/^CRED_OKTA_DIR=//p')"; \
        if [ "{{flavor}}" = vertex ]; then rm -rf "$g" && echo "wiped $g"; else rm -rf "$o" && echo "wiped $o"; fi

# Remove the {{flavor}} image (via the resolved runtime)
clean:
    @rt="$({{here}}/bin/container-runtime.sh --resolve)"; bin="$rt"; [ "$rt" = apple ] && bin=container; \
        [ "$rt" = none ] || $bin rmi {{image}} || true

# Self-check: runtime resolved, image built, flavor auth present, wrapper on PATH
doctor:
    @echo "== runtime =="
    @rt="$({{here}}/bin/container-runtime.sh --resolve)"; echo "  resolved: $rt"; \
        for c in apple docker podman; do \
            CR_SOURCED=1 bash -c 'source {{here}}/bin/container-runtime.sh; cr_available '"$c"' && echo "  available: '"$c"'"' || true; \
        done
    @echo "== image ({{flavor}}) =="
    @rt="$({{here}}/bin/container-runtime.sh --resolve)"; bin="$rt"; [ "$rt" = apple ] && bin=container; \
        if [ "$rt" = none ]; then echo "  SKIP: no runtime"; \
        elif $bin image inspect {{image}} >/dev/null 2>&1; then echo "  ok: {{image}} present"; \
        else echo "  MISSING: run 'just build' (FLAVOR={{flavor}})"; fi
    @echo "== auth ({{flavor}}) =="
    @paths="$(CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-launcher.sh --print-paths)"; \
        if [ "{{flavor}}" = vertex ]; then \
            d="$(printf '%s\n' "$paths" | sed -n 's/^CRED_GCLOUD_DIR=//p')"; \
            if [ -f "$d/application_default_credentials.json" ]; then echo "  ok: ADC credentials present ($d)"; \
            else echo "  MISSING ADC: run 'just auth'"; fi; \
        else \
            d="$(printf '%s\n' "$paths" | sed -n 's/^CRED_OKTA_DIR=//p')"; \
            if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then echo "  ok: Okta token cache present ($d)"; \
            else echo "  MISSING: run 'FLAVOR=gateway just auth'"; fi; \
            env="${XDG_CONFIG_HOME:-$HOME/.config}/vida-claude-container/gateway/env"; \
            if [ -f "$env" ] && grep -Eq '^OKTA_CLIENT_ID=.+' "$env"; then \
                echo "  ok: OKTA_CLIENT_ID set in $env"; \
            else echo "  MISSING: set OKTA_CLIENT_ID in $env"; fi; \
        fi
    @echo "== wrapper on PATH =="
    @command -v claude-{{flavor}} >/dev/null \
        && echo "  ok: $(command -v claude-{{flavor}})" \
        || echo "  MISSING: run 'just install' (or add {{bin_dir}} to PATH)"
    @echo "== memory ({{flavor}}) =="
    @paths="$(CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-launcher.sh --print-paths)"; \
        STATE_CLAUDE_DIR="$(printf '%s\n' "$paths" | sed -n 's/^STATE_CLAUDE_DIR=//p')"; \
        echo "  global tier: $STATE_CLAUDE_DIR/memory-global"; \
        if [ -n "$(ls -A "$STATE_CLAUDE_DIR/projects/-workspace" 2>/dev/null)" ]; then \
            echo "  WARN: legacy shared bucket present ($STATE_CLAUDE_DIR/projects/-workspace)"; \
            echo "        run 'claude-{{flavor}} migrate-memory' from the owning repo"; \
        else echo "  ok: no legacy shared bucket"; fi
