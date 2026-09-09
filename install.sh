#!/usr/bin/env bash
# Installer for the containerized Claude distribution.
#   curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash
# or, from a checkout:  just install  ->  install.sh --local
set -euo pipefail

REPO="multigl/claude-container"
REF="${CLAUDE_INSTALL_REF:-main}"
PREFIX="${INSTALL_DIR:-$HOME/.local/share/claude-container/src}"
LEGACY_PREFIX="$HOME/.local/share/vida-claude-container/src"
BIN_DIR="${CLAUDE_BIN_DIR:-$HOME/.local/bin}"
FLAVORS=(vertex)
LOCAL=0 DRYRUN=0 NO_APPLE_GATE="${CLAUDE_SKIP_APPLE_GATE:-0}"

while [[ $# -gt 0 ]]; do case "$1" in
    --local) LOCAL=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --all) FLAVORS=(vertex gateway personal); shift ;;
    --flavor) FLAVORS=("$2"); shift 2 ;;
    --runtime) export CLAUDE_RUNTIME="$2"; shift 2 ;;
    --no-apple-gate) NO_APPLE_GATE=1; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done

say() { printf '%s\n' "$*"; }
plan() { printf 'PLAN %s\n' "$*"; }

# Locate the source tree: cwd for --local, else the clone target.
if [[ "$LOCAL" == 1 ]]; then SRC="$(cd "$(dirname "$0")" && pwd)"; else SRC="$PREFIX"; fi

# --- runtime detection (reuse the dispatcher when the tree is available) -----
detect_runtime() {
    if [[ -x "$SRC/bin/container-runtime.sh" ]]; then
        CLAUDE_RUNTIME="${CLAUDE_RUNTIME:-}" "$SRC/bin/container-runtime.sh" --resolve
    else
        if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then echo docker
        elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then echo podman
        else echo none; fi
    fi
}

apple_eligible() { [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] && [[ "$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)" -ge 26 ]]; }

# --- apple gate --------------------------------------------------------------
if apple_eligible && ! command -v container >/dev/null 2>&1 && [[ "$NO_APPLE_GATE" != 1 ]]; then
    say "APPLE GATE: this Mac can run Apple 'container' (faster, native)."
    say "  Install it: https://github.com/apple/container/releases  then re-run this installer."
    say "  To skip and use docker/podman instead: re-run with --no-apple-gate"
    [[ "$DRYRUN" == 1 ]] && { plan "stop: apple gate"; exit 0; }
    exit 3
fi

# --- fetch (remote mode) -----------------------------------------------------
# Clone BEFORE runtime detection so detect_runtime can use the cloned tree's
# dispatcher (bin/container-runtime.sh) — which is what resolves Apple 'container'.
if [[ "$LOCAL" != 1 ]]; then
    # One-time: move a checkout made under the legacy namespace. The installer
    # re-symlinks the wrappers on every run, so they follow the move.
    if [[ -d "$LEGACY_PREFIX/.git" && ! -e "$PREFIX" ]]; then
        if [[ "$DRYRUN" == 1 ]]; then plan "move: $LEGACY_PREFIX -> $PREFIX";
        else mkdir -p "$(dirname "$PREFIX")" && mv "$LEGACY_PREFIX" "$PREFIX" && say "moved checkout: $LEGACY_PREFIX -> $PREFIX"; fi
    fi

    if [[ "$DRYRUN" == 1 ]]; then plan "fetch: $REPO@$REF -> $PREFIX";
    else
        mkdir -p "$(dirname "$PREFIX")"
        if [[ -d "$PREFIX/.git" ]]; then git -C "$PREFIX" pull --ff-only;
        else git clone --branch "$REF" "https://github.com/$REPO.git" "$PREFIX"; fi
    fi
    SRC="$PREFIX"
fi

RT="$(detect_runtime)"
if [[ "$RT" == none ]]; then
    say "No usable container runtime. Install docker or podman (or Apple 'container' on macOS 26+)."
    exit 1
fi
say "runtime: $RT"

# --- build -------------------------------------------------------------------
for f in "${FLAVORS[@]}"; do
    img="claude-$f:latest"
    if [[ "$DRYRUN" == 1 ]]; then plan "build: $f ($img) via $RT"; continue; fi
    say "building $f …"
    CLAUDE_RUNTIME="$RT" "$SRC/bin/container-runtime.sh" build --flavor "$f" --image "$img" --context "$SRC"
done

# --- symlink wrappers --------------------------------------------------------
[[ "$DRYRUN" == 1 ]] || mkdir -p "$BIN_DIR" 2>/dev/null || true
for f in "${FLAVORS[@]}"; do
    if [[ "$DRYRUN" == 1 ]]; then plan "symlink: claude-$f -> $SRC/bin/claude-launcher.sh"; continue; fi
    ln -sf "$SRC/bin/claude-launcher.sh" "$BIN_DIR/claude-$f"
    say "installed: $BIN_DIR/claude-$f"
done

if [[ "$DRYRUN" != 1 ]]; then
    say ""
    say "Done. Ensure $BIN_DIR is on PATH, then:"
    for f in "${FLAVORS[@]}"; do say "  claude-$f auth   # one-time login"; done
fi
