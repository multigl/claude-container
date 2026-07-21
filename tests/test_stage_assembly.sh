#!/usr/bin/env bash
# Tests for the per-run stage directory that replaces the launcher's single-file
# bind mounts. Drives bin/claude-launcher.sh with a recording `docker` stub that
# captures the run argv and snapshots the staged dir's contents, in an isolated
# HOME with the optional host sources seeded (or not) by each case.
cd "$(dirname "$0")"
source ./lib.sh
LAUNCHER="$(pwd)/../bin/claude-launcher.sh"

# run_launch HOME -> echoes a REC dir holding:
#   argv      : one docker-run arg per line
#   stage-ls  : sorted `ls -A` of the dir bind-mounted at /opt/claude-stage
# Caller seeds host sources under HOME first, then inspects REC.
run_launch() {
    local home="$1"
    local bin rec; bin="$(mktemp -d)"; rec="$(mktemp -d)"
    cat > "$bin/docker" <<'STUB'
#!/usr/bin/env bash
{ for a in "$@"; do printf '%s\n' "$a"; done; } > "$REC/argv"
for a in "$@"; do
  case "$a" in
    *:/opt/claude-stage:ro) ls -A "${a%:/opt/claude-stage:ro}" 2>/dev/null | sort > "$REC/stage-ls" ;;
  esac
done
exit 0
STUB
    chmod +x "$bin/docker"
    env -i HOME="$home" PATH="$bin:$PATH" REC="$rec" CLAUDE_FLAVOR=vertex \
        bash "$LAUNCHER" </dev/null >/dev/null 2>&1 || true
    rm -rf "$bin"
    printf '%s' "$rec"
}

# --- all host sources present -> all staged, one dir mount, no file mounts ---
h="$(mktemp -d)"
cfg="$h/.config/vida-claude-container/vertex"
mkdir -p "$cfg" "$h/.claude"
printf '{"model":"x"}\n'      > "$cfg/settings.override.json"
printf '[user]\n'            > "$cfg/gitconfig"
printf '{"mcpServers":{}}\n' > "$h/.claude.json"
printf '#!/bin/sh\necho hi\n' > "$h/.claude/statusline-command.sh"
rec="$(run_launch "$h")"
argv="$(cat "$rec/argv" 2>/dev/null)"
ls="$(cat "$rec/stage-ls" 2>/dev/null)"

assert_contains "$argv" ":/opt/claude-stage:ro" "stage dir bind-mounted ro"
assert_contains "$ls" "settings.override.json"  "settings.override.json staged"
assert_contains "$ls" "host-claude.json"        "host ~/.claude.json staged as host-claude.json"
assert_contains "$ls" "statusline.sh"           "host statusline staged as statusline.sh"
assert_contains "$ls" "gitconfig-identity"      "git identity staged as gitconfig-identity"

# retired single-file mounts must be gone
assert_not_contains "$argv" "settings.override.json:/home/claude" "no settings.override.json file mount"
assert_not_contains "$argv" ".host-claude.json"                   "no .host-claude.json file mount"
assert_not_contains "$argv" ".gitconfig-identity"                 "no .gitconfig-identity file mount"
assert_not_contains "$argv" ":/opt/claude/statusline.sh"          "no statusline.sh file mount"
assert_not_contains "$argv" ":/home/claude/.claude.json"          "no .claude.json file mount"
rm -rf "$h" "$rec"

# --- optional sources absent -> those stage entries absent (no crash) ---
h="$(mktemp -d)"
mkdir -p "$h/.config/vida-claude-container/vertex"   # no override, no host claude.json, no statusline
rec="$(run_launch "$h")"
argv="$(cat "$rec/argv" 2>/dev/null)"
ls="$(cat "$rec/stage-ls" 2>/dev/null)"
assert_contains "$argv" ":/opt/claude-stage:ro"       "stage still mounted when sources absent"
assert_not_contains "$ls" "settings.override.json"    "absent override not staged"
assert_not_contains "$ls" "host-claude.json"          "absent host claude.json not staged"
assert_not_contains "$ls" "statusline.sh"             "absent statusline not staged"
rm -rf "$h" "$rec"

# --- stage dir is cleaned up after the run (no .stage.* left behind) ---
h="$(mktemp -d)"
mkdir -p "$h/.config/vida-claude-container/vertex"
rec="$(run_launch "$h")"
leftovers="$(ls -A "$h/.local/state/vida-claude-container/vertex/" 2>/dev/null | grep '^\.stage\.' || true)"
assert_eq "" "$leftovers" "stage dir removed after run"
rm -rf "$h" "$rec"

# --- rw .claude.json migration: old $STATE_DIR/claude.json -> claude/claude.json ---
h="$(mktemp -d)"
state="$h/.local/state/vida-claude-container/vertex"
mkdir -p "$state" "$h/.config/vida-claude-container/vertex"
printf '{"legacy":true}\n' > "$state/claude.json"     # old sibling location
rec="$(run_launch "$h")"
if [[ -f "$state/claude/claude.json" ]] && grep -q legacy "$state/claude/claude.json"; then
    moved=yes; else moved=no; fi
assert_eq "yes" "$moved" "legacy claude.json migrated into claude/ dir mount"
assert_eq "" "$(ls -A "$state"/claude.json 2>/dev/null || true)" "old sibling claude.json removed"
rm -rf "$h" "$rec"

finish
