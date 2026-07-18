#!/usr/bin/env bash
# Tests for claude-launcher.sh --print-paths (pure path resolution, no side effects)
cd "$(dirname "$0")"
source ./lib.sh
LAUNCHER="$(pwd)/../claude-launcher.sh"

# Run --print-paths in an isolated HOME with a controlled env. Prints
# "<scratchHOME>\n<launcher output>"; caller checks emptiness then removes the dir.
# NOTE: no assert_* calls in here -- this runs inside $(...) so its stdout is
# captured, and assert output would be swallowed / corrupt the head/tail split.
run_paths() {  # run_paths KEY=VAL...
    local home; home="$(mktemp -d)"
    local out
    out="$(env -i HOME="$home" PATH="$PATH" "$@" bash "$LAUNCHER" --print-paths 2>/dev/null)"
    printf '%s\n%s' "$home" "$out"
}

# --- XDG unset -> ~/.config + ~/.local/state defaults, vertex flavor ---
res="$(run_paths CLAUDE_FLAVOR=vertex)"; home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_eq "" "$(ls -A "$home" 2>/dev/null)" "no side effects (vertex defaults)"
assert_contains "$out" "CFG_DIR=$home/.config/vida-claude-container/vertex"       "vertex config default"
assert_contains "$out" "STATE_DIR=$home/.local/state/vida-claude-container/vertex" "vertex state default"
assert_contains "$out" "HOST_CFG=$home/.local/state/vida-claude-container/vertex/claude"        "vertex .claude dir"
assert_contains "$out" "HOST_DOTCLAUDE=$home/.local/state/vida-claude-container/vertex/claude.json" "vertex .claude.json"
assert_contains "$out" "HOST_SETTINGS=$home/.config/vida-claude-container/vertex/settings.override.json" "vertex override path"
rm -rf "$home"

# --- gateway flavor -> distinct per-flavor dirs ---
res="$(run_paths CLAUDE_FLAVOR=gateway)"; home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_contains "$out" "CFG_DIR=$home/.config/vida-claude-container/gateway"        "gateway config default"
assert_contains "$out" "STATE_DIR=$home/.local/state/vida-claude-container/gateway" "gateway state default"
rm -rf "$home"

# --- XDG_CONFIG_HOME / XDG_STATE_HOME honored ---
res="$(run_paths CLAUDE_FLAVOR=vertex XDG_CONFIG_HOME=/x/cfg XDG_STATE_HOME=/x/state)"
home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_contains "$out" "CFG_DIR=/x/cfg/vida-claude-container/vertex"     "XDG_CONFIG_HOME honored"
assert_contains "$out" "STATE_DIR=/x/state/vida-claude-container/vertex" "XDG_STATE_HOME honored"
rm -rf "$home"

# --- config override env vars redirect their target ---
res="$(run_paths CLAUDE_FLAVOR=vertex CLAUDE_ENV_FILE=/tmp/my.env CLAUDE_SETTINGS=/tmp/my.json)"
home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_contains "$out" "HOST_ENV_FILE=/tmp/my.env"  "CLAUDE_ENV_FILE override honored"
assert_contains "$out" "HOST_SETTINGS=/tmp/my.json" "CLAUDE_SETTINGS override honored"
rm -rf "$home"

finish
