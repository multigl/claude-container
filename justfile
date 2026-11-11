flavor     := env("FLAVOR", "personal")
image      := env("IMAGE", "claude-" + flavor + ":latest")
bin_dir    := env("BIN_DIR", env("HOME") + "/.local/bin")
here       := justfile_directory()

# Show available recipes
default:
    @just --list --unsorted

# Build the launcher binary into bin/claude-container
build-launcher:
    cd {{here}} && go build -o bin/claude-container ./cmd/claude-container

# Build one image with the resolved runtime. Apple's CLI is `container`; all three
# take the same build flags. CLAUDE_CODE_VERSION, when set, pins claude-code.
_image-build target image no_cache="": build-launcher
    @rt="$({{here}}/bin/claude-container --print-runtime | sed -n 's/^RUNTIME=//p')"; \
        bin="$rt"; [ "$rt" = apple ] && bin=container; \
        [ -n "$rt" ] && [ "$rt" != none ] || { echo "no runtime" >&2; exit 1; }; \
        echo ">> [$rt] build {{target}} -> {{image}}"; \
        $bin build -f {{here}}/Containerfile --target {{target}} -t {{image}} {{no_cache}} \
            ${CLAUDE_CODE_VERSION:+--build-arg CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION"} {{here}}

# Build the {{flavor}} image (FLAVOR=personal|vertex|gateway) via the resolved runtime
build: (_image-build flavor image)

# Rebuild the {{flavor}} image without cache (via the resolved runtime)
rebuild: (_image-build flavor image "--no-cache")

# Local dev: rebuild {{flavor}} pinned to the latest published claude-code. The
# container's claude-code is deliberately non-self-updating (pinned + ephemeral +
# non-root). Installed machines don't build: `claude-<flavor> update` pulls the
# CI-published image instead. Override the version with CLAUDE_CODE_VERSION.
update: build-launcher
    ver="${CLAUDE_CODE_VERSION:-$(npm view @anthropic-ai/claude-code version)}"; \
    CLAUDE_CODE_VERSION="$ver" just _image-build {{flavor}} {{image}}; \
    echo ">> built {{image}} with claude-code $ver"

# Build the vertex image
build-vertex: (_image-build "vertex" "claude-vertex:latest")

# Build the gateway image
build-gateway: (_image-build "gateway" "claude-gateway:latest")

# Build the personal image
build-personal: (_image-build "personal" "claude-personal:latest")

# Build all images (shared base layer is cached, so each additional one is cheap)
build-all: build-vertex build-gateway build-personal

# Rebuild the vertex image without cache (via the resolved runtime)
rebuild-vertex: (_image-build "vertex" "claude-vertex:latest" "--no-cache")

# Rebuild the gateway image without cache (via the resolved runtime)
rebuild-gateway: (_image-build "gateway" "claude-gateway:latest" "--no-cache")

# Rebuild the personal image without cache (via the resolved runtime)
rebuild-personal: (_image-build "personal" "claude-personal:latest" "--no-cache")

# Rebuild all images from scratch (base built no-cache once, then reused)
rebuild-all: rebuild-vertex build-gateway build-personal

# One-time login for {{flavor}} (gcloud ADC, or Okta device login) -> cred bind dir
auth: build-launcher
    CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-container auth

# Run all test suites: pytest, Go unit tests, then the bash suites
test:
    uv run pytest -q
    cd {{here}} && go test ./...
    {{here}}/tests/run.sh

# Run `claude` against the current directory (uses {{flavor}})
run: build-launcher
    CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-container

# Open a bash shell inside the container
shell: build-launcher
    CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-container shell

# Overwrite host config's seeded files (settings + plugins) from the image
reseed: build-launcher
    CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-container reseed

# Install the binary and the claude-{{flavor}} link into {{bin_dir}}
install: build-launcher
    {{here}}/install.sh --local {{here}}/bin/claude-container --flavor {{flavor}}

# Install the binary and ALL flavor links (claude-vertex + claude-gateway + claude-personal)
install-all: build-launcher
    {{here}}/install.sh --local {{here}}/bin/claude-container --all

# Remove the flavor links and the binary
uninstall:
    rm -f {{bin_dir}}/claude-vertex {{bin_dir}}/claude-gateway {{bin_dir}}/claude-personal {{bin_dir}}/claude-container

# Wipe the {{flavor}} credentials (forces re-auth). Paths come from the flavor driver.
reset-auth: build-launcher
    @CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-container reset-auth

# Remove the {{flavor}} image (via the resolved runtime)
clean: build-launcher
    @rt="$({{here}}/bin/claude-container --print-runtime | sed -n 's/^RUNTIME=//p')"; bin="$rt"; [ "$rt" = apple ] && bin=container; \
        [ -z "$rt" ] || [ "$rt" = none ] || $bin image rm {{image}} || true

# Self-check: runtime resolved, image built, flavor auth present, wrapper on PATH
doctor: build-launcher
    @CLAUDE_FLAVOR={{flavor}} {{here}}/bin/claude-container doctor
