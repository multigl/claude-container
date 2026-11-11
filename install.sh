#!/usr/bin/env bash
# Installer for the containerized Claude distribution. Downloads the release
# binary, links claude-<flavor> to it, and pulls the CI-published images; it
# never builds an image.
#   curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash
# or, from a checkout:  just install  ->  install.sh --local bin/claude-container
set -euo pipefail

RELEASE_URL="https://github.com/multigl/claude-container/releases/latest/download"
BIN_DIR="${CLAUDE_BIN_DIR:-$HOME/.local/bin}"
OLD_CLONE="$HOME/.local/share/claude-container/src"
FLAVORS=(personal)
LOCAL_BINARY="" DRYRUN=0 NO_APPLE_GATE="${CLAUDE_SKIP_APPLE_GATE:-0}"

while [[ $# -gt 0 ]]; do case "$1" in
    --local) LOCAL_BINARY="${2:?--local needs a path to a built claude-container}"; shift 2 ;;
    --dry-run) DRYRUN=1; shift ;;
    --all) FLAVORS=(personal vertex gateway); shift ;;
    --flavor) FLAVORS=("${2:?--flavor needs a name}"); shift 2 ;;
    --runtime) export CLAUDE_RUNTIME="${2:?--runtime needs a name}"; shift 2 ;;
    --no-apple-gate) NO_APPLE_GATE=1; shift ;;
    --bin-dir) BIN_DIR="${2:?--bin-dir needs a path}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done

say() { printf '%s\n' "$*"; }
plan() { printf 'PLAN %s\n' "$*"; }

apple_eligible() { [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] && [[ "$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)" -ge 26 ]]; }

# --- apple gate --------------------------------------------------------------
if apple_eligible && ! command -v container >/dev/null 2>&1 && [[ "$NO_APPLE_GATE" != 1 ]]; then
    say "APPLE GATE: this Mac can run Apple 'container' (faster, native)."
    say "  Install it: https://github.com/apple/container/releases  then re-run this installer."
    say "  To skip and use docker/podman instead: re-run with --no-apple-gate"
    [[ "$DRYRUN" == 1 ]] && { plan "stop: apple gate"; exit 0; }
    exit 3
fi

# --- platform ----------------------------------------------------------------
case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux) OS=linux ;;
    *) echo "unsupported OS: $(uname -s) (need Darwin or Linux)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) echo "unsupported architecture: $(uname -m) (need x86_64 or arm64)" >&2; exit 1 ;;
esac
ASSET="claude-container_${OS}_${ARCH}"

sha256_of() {
    if [[ "$OS" == darwin ]]; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# --- flavors linked into the old clone ----------------------------------------
# An upgrade from the bash install must relink every flavor it had, not just
# the default, or those commands keep running the stale scripts.
add_flavor() {
    local existing
    for existing in "${FLAVORS[@]}"; do [[ "$existing" == "$1" ]] && return; done
    FLAVORS+=("$1")
}
for link in "$BIN_DIR"/claude-*; do
    [[ -L "$link" ]] || continue
    flavor="${link##*/claude-}"
    case "$flavor" in personal|vertex|gateway) ;; *) continue ;; esac
    link_target="$(readlink "$link")"
    [[ "$link_target" == /* ]] || link_target="$BIN_DIR/$link_target"
    [[ "$link_target" == "$OLD_CLONE"/* ]] || continue
    add_flavor "$flavor"
    if [[ "$DRYRUN" == 1 ]]; then plan "migrate: claude-$flavor"; else say "migrating claude-$flavor off the old clone"; fi
done

# --- binary ------------------------------------------------------------------
TARGET="$BIN_DIR/claude-container"
if [[ "$DRYRUN" == 1 ]]; then
    if [[ -n "$LOCAL_BINARY" ]]; then
        plan "install: $TARGET from $LOCAL_BINARY"
    else
        plan "download: $ASSET"
        plan "verify: SHA256SUMS"
        plan "install: $TARGET"
    fi
else
    mkdir -p "$BIN_DIR"
    # Same directory as the target so the final mv is an atomic rename.
    STAGING="$(mktemp -d "$BIN_DIR/.claude-container-install.XXXXXX")"
    trap 'rm -rf "$STAGING"' EXIT
    if [[ -n "$LOCAL_BINARY" ]]; then
        cp "$LOCAL_BINARY" "$STAGING/claude-container"
    else
        say "downloading $ASSET …"
        curl -fsSL -o "$STAGING/claude-container" "$RELEASE_URL/$ASSET"
        curl -fsSL -o "$STAGING/SHA256SUMS" "$RELEASE_URL/SHA256SUMS"
        expected="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$STAGING/SHA256SUMS")"
        if [[ -z "$expected" ]]; then echo "no checksum for $ASSET in SHA256SUMS" >&2; exit 1; fi
        if [[ "$(sha256_of "$STAGING/claude-container")" != "$expected" ]]; then
            echo "checksum mismatch for $ASSET" >&2; exit 1
        fi
    fi
    chmod 755 "$STAGING/claude-container"
    mv -f "$STAGING/claude-container" "$TARGET"
    say "installed: $TARGET"
fi

# --- runtime -----------------------------------------------------------------
if [[ -n "${CLAUDE_RUNTIME:-}" ]]; then
    say "runtime: $CLAUDE_RUNTIME"
elif [[ "$DRYRUN" == 1 ]]; then
    plan "runtime: detect via claude-container --print-runtime"
else
    RT="$("$TARGET" --print-runtime 2>/dev/null | sed -n 's/^RUNTIME=//p')" || true
    if [[ -z "$RT" || "$RT" == none ]]; then
        say "No usable container runtime. Install docker or podman (or Apple 'container' on macOS 26+)."
        exit 1
    fi
    say "runtime: $RT"
    export CLAUDE_RUNTIME="$RT"
fi

# --- symlinks and image pull -------------------------------------------------
for flavor in "${FLAVORS[@]}"; do
    if [[ "$DRYRUN" == 1 ]]; then plan "symlink: claude-$flavor -> claude-container"; continue; fi
    ln -sf claude-container "$BIN_DIR/claude-$flavor"
    say "linked: $BIN_DIR/claude-$flavor"
done

# Through the just-installed command's `update`, so the pull lives in one place.
for flavor in "${FLAVORS[@]}"; do
    if [[ "$DRYRUN" == 1 ]]; then plan "update: $flavor"; continue; fi
    say "updating $flavor …"
    CLAUDE_FLAVOR="$flavor" "$BIN_DIR/claude-$flavor" update
done

if [[ -d "$OLD_CLONE" ]]; then
    say "old clone at $OLD_CLONE can be removed (the launcher is now a single binary)"
fi

if [[ "$DRYRUN" != 1 ]]; then
    say ""
    say "Done. Ensure $BIN_DIR is on PATH, then:"
    for flavor in "${FLAVORS[@]}"; do say "  claude-$flavor auth   # one-time login"; done
fi
