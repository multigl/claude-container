flavor     := env_var_or_default("FLAVOR", "vertex")
image      := env_var_or_default("IMAGE", "claude-" + flavor + ":latest")
bin_dir    := env_var_or_default("BIN_DIR", env_var("HOME") + "/.local/bin")
gcloud_vol := env_var_or_default("GCLOUD_VOL", "claude-vertex-gcloud")
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

# Build the vertex image
build-vertex:
    docker build --target vertex -t claude-vertex:latest {{here}}

# Build the gateway image
build-gateway:
    docker build --target gateway -t claude-gateway:latest {{here}}

# Build both images (shared base layer is cached, so the second is cheap)
build-all: build-vertex build-gateway

# One-time gcloud ADC login (vertex only; saved to docker volume, not host)
auth:
    CLAUDE_FLAVOR={{flavor}} {{here}}/claude-launcher.sh auth

# Run `claude` against the current directory (uses {{flavor}})
run:
    CLAUDE_FLAVOR={{flavor}} {{here}}/claude-launcher.sh

# Open a bash shell inside the container
shell:
    CLAUDE_FLAVOR={{flavor}} {{here}}/claude-launcher.sh shell

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

# Wipe the gcloud creds volume (vertex; forces re-auth)
reset-auth:
    docker volume rm {{gcloud_vol}} || true

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
        && echo "  ok: {{image}} present" \
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
        helper="${CLAUDE_GATEWAY_KEY_HELPER:-$HOME/.local/bin/litellm-key-helper}"; \
        test -x "$helper" \
            && echo "  ok: key-helper present: $helper" \
            || echo "  MISSING: executable key-helper at $helper"; \
    fi
    @echo "== wrapper on PATH =="
    @command -v claude-{{flavor}} >/dev/null \
        && echo "  ok: $(command -v claude-{{flavor}})" \
        || echo "  MISSING: run 'just install' (or add {{bin_dir}} to PATH)"
