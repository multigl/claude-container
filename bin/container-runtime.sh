#!/usr/bin/env bash
# Container-runtime dispatcher. Detects an available runtime (priority
# apple > docker > podman), honoring the CLAUDE_RUNTIME override, then sources
# the matching driver from bin/runtimes/<rt>.sh and exposes rt_* functions.
#
# Standalone entrypoints (for tests + justfile + doctor):
#   container-runtime.sh --resolve        # print chosen runtime or "none"
#   container-runtime.sh build ARGS...    # build via the resolved driver
# When sourced (CR_SOURCED=1), it defines functions and does not act.
set -uo pipefail

CR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- host shape (each isolated so tests can stub the underlying tool) --------
_cr_os()   { uname -s 2>/dev/null; }
_cr_arch() { uname -m 2>/dev/null; }
_cr_macos_major() { sw_vers -productVersion 2>/dev/null | cut -d. -f1; }

_cr_is_macos() { [[ "$(_cr_os)" == "Darwin" ]]; }
_cr_is_linux() { [[ "$(_cr_os)" == "Linux"  ]]; }

# apple `container` needs Apple Silicon + macOS 26+
_cr_apple_eligible() {
    _cr_is_macos || return 1
    [[ "$(_cr_arch)" == "arm64" ]] || return 1
    local maj; maj="$(_cr_macos_major)"
    [[ -n "$maj" && "$maj" -ge 26 ]]
}

# --- availability probes (installed AND functional) -------------------------
_cr_have_docker() { command -v docker    >/dev/null 2>&1 && docker info          >/dev/null 2>&1; }
_cr_have_podman() { command -v podman    >/dev/null 2>&1 && podman info          >/dev/null 2>&1; }
_cr_have_apple()  { _cr_apple_eligible   && command -v container >/dev/null 2>&1 && container system status >/dev/null 2>&1; }

# Is a specific runtime available on this host?
cr_available() {  # cr_available docker|podman|apple
    case "$1" in
        docker) _cr_have_docker ;;
        podman) _cr_have_podman ;;
        apple)  _cr_is_macos && _cr_have_apple ;;
        *) return 1 ;;
    esac
}

# Resolve the runtime to use: override if set+available, else first available in
# priority order. Prints the name, or "none".
cr_resolve() {
    if [[ -n "${CLAUDE_RUNTIME:-}" ]]; then
        if cr_available "$CLAUDE_RUNTIME"; then printf '%s\n' "$CLAUDE_RUNTIME"; return 0; fi
        printf 'none\n'; return 0
    fi
    local rt
    for rt in apple docker podman; do
        if cr_available "$rt"; then printf '%s\n' "$rt"; return 0; fi
    done
    printf 'none\n'
}

# Source the driver for a resolved runtime; makes rt_* available.
cr_load_driver() {  # cr_load_driver <runtime>
    # shellcheck source=/dev/null
    source "$CR_DIR/runtimes/$1.sh"
}

# --- CLI (only when executed, not sourced) ----------------------------------
if [[ "${CR_SOURCED:-0}" != 1 ]]; then
    case "${1:-}" in
        --resolve) cr_resolve ;;
        build)
            shift
            flavor=""; image=""; ctx="."
            while [[ $# -gt 0 ]]; do case "$1" in
                --flavor) flavor="$2"; shift 2 ;;
                --image)  image="$2";  shift 2 ;;
                --context) ctx="$2";   shift 2 ;;
                *) shift ;;
            esac; done
            rt="$(cr_resolve)"; [[ "$rt" == none ]] && { echo "no runtime" >&2; exit 1; }
            cr_load_driver "$rt"
            cmd="$(rt_build_cmd "$flavor" "$image" "$ctx")"
            echo ">> [$rt] $cmd"
            eval "$cmd"
            ;;
        *) echo "usage: container-runtime.sh --resolve | build --flavor F --image I [--context DIR]" >&2; exit 2 ;;
    esac
fi
