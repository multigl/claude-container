#!/usr/bin/env bash
# install.sh --local --dry-run planning. Stubs runtime + uname/sw_vers on PATH;
# asserts the printed PLAN without building or symlinking anything.
cd "$(dirname "$0")"
source ./lib.sh
INSTALL="$(pwd)/../install.sh"

plan() {  # plan KEY=VAL ...  (HAVE_APPLE, OSTYPE_STUB, ARCH_STUB, MACOS_MAJOR, CLAUDE_SKIP_APPLE_GATE)
    for kv in "$@"; do export "$kv"; done
    local bin; bin="$(mktemp -d)"
    for rt in docker podman container; do
        printf '#!/usr/bin/env bash\ncase "$1 $2" in "info "*|"info"|"system status") exit 0;; esac\nexit 0\n' > "$bin/$rt"
        chmod +x "$bin/$rt"
    done
    printf '#!/usr/bin/env bash\n[[ "$1" == "-m" ]] && { echo "%s"; exit 0; }\necho "%s"\n' "${ARCH_STUB:-arm64}" "${OSTYPE_STUB:-Linux}" > "$bin/uname"
    printf '#!/usr/bin/env bash\necho "%s.0"\n' "${MACOS_MAJOR:-26}" > "$bin/sw_vers"
    chmod +x "$bin/uname" "$bin/sw_vers"
    [[ "${HAVE_APPLE-}" == 1 ]] || rm -f "$bin/container"
    local home; home="$(mktemp -d)"
    env HOME="$home" PATH="$bin:$PATH" bash "$INSTALL" --local --dry-run 2>&1
    rm -rf "$bin" "$home"
    unset OSTYPE_STUB ARCH_STUB MACOS_MAJOR HAVE_APPLE CLAUDE_SKIP_APPLE_GATE
}

# Linux, docker present -> plan builds vertex via docker, symlinks wrappers
out="$(plan OSTYPE_STUB=Linux)"
assert_contains "$out" "runtime: docker"          "linux dry-run resolves docker"
assert_contains "$out" "build: vertex"            "dry-run plans vertex build"
assert_contains "$out" "symlink: claude-vertex"   "dry-run plans wrapper symlink"
assert_not_contains "$out" "APPLE GATE"           "linux never apple-gates"

# eligible macOS without apple -> APPLE GATE stop
out="$(plan OSTYPE_STUB=Darwin HAVE_APPLE=)"
assert_contains "$out" "APPLE GATE"               "eligible mac w/o apple -> gate"

# eligible macOS, skip-gate -> proceeds with docker
out="$(plan OSTYPE_STUB=Darwin HAVE_APPLE= CLAUDE_SKIP_APPLE_GATE=1)"
assert_contains "$out" "runtime: docker"          "skip-apple-gate proceeds on mac"

# Intel mac (ineligible) -> no gate, docker
out="$(plan OSTYPE_STUB=Darwin ARCH_STUB=x86_64 HAVE_APPLE=)"
assert_not_contains "$out" "APPLE GATE"           "intel mac ineligible -> no gate"

# --- dry-run creates no side effects (BIN_DIR must not be mkdir'd) ---
drh="$(mktemp -d)"; drbin="$(mktemp -d)"
for rt in docker podman container; do printf '#!/usr/bin/env bash\ncase "$1 $2" in "info "*|"info"|"system status") exit 0;; esac\nexit 0\n' > "$drbin/$rt"; chmod +x "$drbin/$rt"; done
printf '#!/usr/bin/env bash\n[[ "$1" == "-m" ]] && { echo x86_64; exit 0; }\necho Linux\n' > "$drbin/uname"; chmod +x "$drbin/uname"
env HOME="$drh" PATH="$drbin:$PATH" bash "$INSTALL" --local --dry-run >/dev/null 2>&1
assert_eq "" "$(ls -A "$drh/.local/bin" 2>/dev/null || true)" "dry-run does not create BIN_DIR"
assert_eq "absent" "$([[ -d "$drh/.local/bin" ]] && echo present || echo absent)" "dry-run does not mkdir BIN_DIR"
rm -rf "$drh" "$drbin"

finish
