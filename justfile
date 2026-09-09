flavor     := env("FLAVOR", "personal")
image      := env("IMAGE", "claude-" + flavor + ":latest")
bin_dir    := env("BIN_DIR", env("HOME") + "/.local/bin")
here       := justfile_directory()

# Show available recipes
default:
    @just --list --unsorted

# Build the {{flavor}} image (FLAVOR=personal|vertex|gateway) via the resolved runtime
build:
    {{here}}/bin/container-runtime.sh build --flavor {{flavor}} --image {{image}} --context {{here}}

# Rebuild the {{flavor}} image without cache (via the resolved runtime)
rebuild:
    {{here}}/bin/container-runtime.sh build --flavor {{flavor}} --image {{image}} --context {{here}} --no-cache

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

# Build the personal image
build-personal:
    {{here}}/bin/container-runtime.sh build --flavor personal --image claude-personal:latest --context {{here}}

# Build all images (shared base layer is cached, so each additional one is cheap)
build-all: build-vertex build-gateway build-personal

# Rebuild the vertex image without cache (via the resolved runtime)
rebuild-vertex:
    {{here}}/bin/container-runtime.sh build --flavor vertex --image claude-vertex:latest --context {{here}} --no-cache

# Rebuild the gateway image without cache (via the resolved runtime)
rebuild-gateway:
    {{here}}/bin/container-runtime.sh build --flavor gateway --image claude-gateway:latest --context {{here}} --no-cache

# Rebuild the personal image without cache (via the resolved runtime)
rebuild-personal:
    {{here}}/bin/container-runtime.sh build --flavor personal --image claude-personal:latest --context {{here}} --no-cache

# Rebuild all images from scratch (base built no-cache once, then reused)
rebuild-all:
    {{here}}/bin/container-runtime.sh build --flavor vertex --image claude-vertex:latest --context {{here}} --no-cache
    {{here}}/bin/container-runtime.sh build --flavor gateway --image claude-gateway:latest --context {{here}}
    {{here}}/bin/container-runtime.sh build --flavor personal --image claude-personal:latest --context {{here}}

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

# Symlink ALL flavor commands (claude-vertex + claude-gateway + claude-personal) to the launcher
install-all:
    {{here}}/install.sh --local --all

# Remove the wrapper symlinks
uninstall:
    rm -f {{bin_dir}}/claude-vertex {{bin_dir}}/claude-gateway {{bin_dir}}/claude-personal

# Wipe the {{flavor}} credentials (forces re-auth). Paths come from the flavor driver.
reset-auth:
    @CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-launcher.sh reset-auth

# Remove the {{flavor}} image (via the resolved runtime)
clean:
    @rt="$({{here}}/bin/container-runtime.sh --resolve)"; bin="$rt"; [ "$rt" = apple ] && bin=container; \
        [ "$rt" = none ] || $bin image rm {{image}} || true

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
    @CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-launcher.sh doctor-auth
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
