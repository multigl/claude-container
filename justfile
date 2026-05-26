image      := env_var_or_default("IMAGE", "claude-vertex:latest")
bin_dir    := env_var_or_default("BIN_DIR", env_var("HOME") + "/.local/bin")
gcloud_vol := env_var_or_default("GCLOUD_VOL", "claude-vertex-gcloud")
here       := justfile_directory()

# Show available recipes
default:
    @just --list --unsorted

# Build the image
build:
    docker build -t {{image}} {{here}}

# Rebuild the image without cache
rebuild:
    docker build --no-cache -t {{image}} {{here}}

# One-time gcloud ADC login (saved to docker volume, not host)
auth:
    {{here}}/claude-vertex.sh auth

# Run `claude` against the current directory
run:
    {{here}}/claude-vertex.sh

# Open a bash shell inside the container
shell:
    {{here}}/claude-vertex.sh shell

# Symlink wrapper to {{bin_dir}}/claude-vertex
install:
    mkdir -p {{bin_dir}}
    ln -sf {{here}}/claude-vertex.sh {{bin_dir}}/claude-vertex
    @echo "installed: {{bin_dir}}/claude-vertex"
    @echo "ensure {{bin_dir}} is on PATH"

# Remove the wrapper symlink
uninstall:
    rm -f {{bin_dir}}/claude-vertex

# Wipe the gcloud creds volume (forces re-auth)
reset-auth:
    docker volume rm {{gcloud_vol}} || true

# Remove the image
clean:
    docker rmi {{image}} || true

# Self-check: docker running, image built, auth volume populated, wrapper on PATH
doctor:
    @echo "== docker =="
    @docker version --format 'client: {{{{.Client.Version}}}}  server: {{{{.Server.Version}}}}' \
        || { echo "  FAIL: docker not running"; exit 1; }
    @echo "== image =="
    @docker image inspect {{image}} >/dev/null 2>&1 \
        && echo "  ok: {{image}} present" \
        || echo "  MISSING: run 'just build'"
    @echo "== auth volume =="
    @docker volume inspect {{gcloud_vol}} >/dev/null 2>&1 \
        && echo "  ok: volume {{gcloud_vol}} exists" \
        || echo "  MISSING: run 'just auth'"
    @docker run --rm -v {{gcloud_vol}}:/g alpine \
        test -f /g/application_default_credentials.json 2>/dev/null \
        && echo "  ok: ADC credentials present" \
        || echo "  MISSING ADC: run 'just auth'"
    @echo "== wrapper on PATH =="
    @command -v claude-vertex >/dev/null \
        && echo "  ok: $(command -v claude-vertex)" \
        || echo "  MISSING: run 'just install' (or add {{bin_dir}} to PATH)"
