#!/usr/bin/env bash
# Detection/selection for bin/container-runtime.sh. Everything the dispatcher
# probes (docker/podman/container binaries, uname, sw_vers) is stubbed on PATH,
# so no real runtime is required.
cd "$(dirname "$0")"
source ./lib.sh
DISPATCH="$(pwd)/../bin/container-runtime.sh"

# resolve_with builds a temp PATH dir with stub docker/podman/container (exit 0
# for info/system status), plus uname/sw_vers, then runs the dispatcher.
# Env: OSTYPE_STUB (Darwin|Linux), ARCH_STUB, MACOS_MAJOR,
# HAVE_DOCKER/HAVE_PODMAN/HAVE_APPLE (1/empty), CLAUDE_RUNTIME (override).
resolve_with() {  # resolve_with KEY=VAL ...
    local bin kv; bin="$(mktemp -d)"
    # KEY=VAL pairs arrive as positional args; export them so the HAVE_* gates
    # below see them (the *_STUB values also ride "$@" into the dispatcher's env
    # via env -i, so the uname/sw_vers stubs pick them up there).
    for kv in "$@"; do export "$kv"; done
    # PATH is kept to "$bin" only so any real docker/podman/container on the host
    # can't leak in; symlink the couple of real tools the dispatcher + stubs
    # still need (the dispatcher pipes sw_vers through cut; stubs run under bash).
    ln -s "$(command -v bash)" "$bin/bash"
    ln -s "$(command -v cut)"  "$bin/cut"
    for rt in docker podman container; do
        cat > "$bin/$rt" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "info "*|"system status"|"info") exit 0 ;;
esac
exit 0
S
        chmod +x "$bin/$rt"
    done
    cat > "$bin/uname" <<S
#!/usr/bin/env bash
[[ "\$1" == "-m" ]] && { echo "\${ARCH_STUB:-arm64}"; exit 0; }
echo "\${OSTYPE_STUB:-Darwin}"
S
    cat > "$bin/sw_vers" <<S
#!/usr/bin/env bash
echo "\${MACOS_MAJOR:-26}.0"
S
    chmod +x "$bin/uname" "$bin/sw_vers"
    [[ "${HAVE_DOCKER-1}" == 1 ]] || rm -f "$bin/docker"
    [[ "${HAVE_PODMAN-1}" == 1 ]] || rm -f "$bin/podman"
    [[ "${HAVE_APPLE-1}"  == 1 ]] || rm -f "$bin/container"
    env -i HOME=/tmp PATH="$bin" "$@" bash "$DISPATCH" --resolve 2>/dev/null
    rm -rf "$bin"
}

assert_eq "apple"  "$(resolve_with OSTYPE_STUB=Darwin)"                          "macOS all present -> apple"
assert_eq "docker" "$(resolve_with OSTYPE_STUB=Darwin HAVE_APPLE=)"              "macOS no apple -> docker"
assert_eq "podman" "$(resolve_with OSTYPE_STUB=Darwin HAVE_APPLE= HAVE_DOCKER=)" "macOS only podman -> podman"
assert_eq "docker" "$(resolve_with OSTYPE_STUB=Linux)"                           "Linux -> docker (apple gated out)"
assert_eq "podman" "$(resolve_with OSTYPE_STUB=Linux HAVE_DOCKER=)"              "Linux no docker -> podman"
assert_eq "docker" "$(resolve_with OSTYPE_STUB=Darwin ARCH_STUB=x86_64)"         "Intel mac -> apple ineligible -> docker"
assert_eq "docker" "$(resolve_with OSTYPE_STUB=Darwin MACOS_MAJOR=15)"           "old macOS -> apple ineligible -> docker"
assert_eq "podman" "$(resolve_with OSTYPE_STUB=Darwin CLAUDE_RUNTIME=podman)"    "override selects podman"
assert_eq "none"   "$(resolve_with OSTYPE_STUB=Linux CLAUDE_RUNTIME=apple)"      "override apple on Linux -> none"
assert_eq "none"   "$(resolve_with OSTYPE_STUB=Linux HAVE_DOCKER= HAVE_PODMAN=)" "nothing installed -> none"

finish
