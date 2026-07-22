#!/usr/bin/env bash
# Tests for bin/claude-launcher.sh --print-paths (pure path resolution, no side effects)
cd "$(dirname "$0")"
source ./lib.sh
LAUNCHER="$(pwd)/../bin/claude-launcher.sh"

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
assert_contains "$out" "STATE_CLAUDE_DIR=$home/.local/state/vida-claude-container/vertex/claude"        "vertex .claude dir"
assert_contains "$out" "HOST_DOTCLAUDE=$home/.local/state/vida-claude-container/vertex/claude/claude.json" "vertex .claude.json (inside claude/ dir mount)"
assert_contains "$out" "CRED_GCLOUD_DIR=$home/.local/state/vida-claude-container/vertex/creds/gcloud" "vertex gcloud cred dir"
assert_contains "$out" "HOST_SETTINGS=$home/.config/vida-claude-container/vertex/settings.override.json" "vertex override path"
assert_contains "$out" "HOST_ENV_FILE=$home/.config/vida-claude-container/vertex/env"       "vertex env default"
assert_contains "$out" "HOST_MOUNTS_FILE=$home/.config/vida-claude-container/vertex/mounts" "vertex mounts default"
assert_contains "$out" "HOST_GITCONFIG=$home/.config/vida-claude-container/vertex/gitconfig" "vertex gitconfig default"
assert_contains "$out" "RUNTIME=" "print-paths includes RUNTIME"
rm -rf "$home"

# --- gateway flavor -> distinct per-flavor dirs ---
res="$(run_paths CLAUDE_FLAVOR=gateway)"; home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_contains "$out" "CFG_DIR=$home/.config/vida-claude-container/gateway"        "gateway config default"
assert_contains "$out" "STATE_DIR=$home/.local/state/vida-claude-container/gateway" "gateway state default"
assert_contains "$out" "CRED_OKTA_DIR=$home/.local/state/vida-claude-container/gateway/creds/okta" "gateway okta cred dir"
rm -rf "$home"

# --- --print-runtime resolves the runtime (docker stub present) ---
rtbin="$(mktemp -d)"; printf '#!/usr/bin/env bash\ncase "$1 $2" in "info "*|"info") exit 0;; esac\nexit 0\n' > "$rtbin/docker"; chmod +x "$rtbin/docker"
prhome="$(mktemp -d)"
pr="$(env -i HOME="$prhome" PATH="$rtbin:$PATH" CLAUDE_FLAVOR=vertex bash "$LAUNCHER" --print-runtime 2>/dev/null)"
assert_contains "$pr" "docker" "--print-runtime resolves docker when only docker present"
rm -rf "$rtbin" "$prhome"

# --- XDG_CONFIG_HOME / XDG_STATE_HOME honored ---
res="$(run_paths CLAUDE_FLAVOR=vertex XDG_CONFIG_HOME=/x/cfg XDG_STATE_HOME=/x/state)"
home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_contains "$out" "CFG_DIR=/x/cfg/vida-claude-container/vertex"     "XDG_CONFIG_HOME honored"
assert_contains "$out" "STATE_DIR=/x/state/vida-claude-container/vertex" "XDG_STATE_HOME honored"
rm -rf "$home"

# --- config override env vars redirect their target ---
res="$(run_paths CLAUDE_FLAVOR=vertex CLAUDE_ENV_FILE=/tmp/my.env CLAUDE_SETTINGS=/tmp/my.json CLAUDE_MOUNTS_FILE=/tmp/my.mounts CLAUDE_GITCONFIG=/tmp/my.gitconfig)"
home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_contains "$out" "HOST_ENV_FILE=/tmp/my.env"        "CLAUDE_ENV_FILE override honored"
assert_contains "$out" "HOST_SETTINGS=/tmp/my.json"       "CLAUDE_SETTINGS override honored"
assert_contains "$out" "HOST_MOUNTS_FILE=/tmp/my.mounts"  "CLAUDE_MOUNTS_FILE override honored"
assert_contains "$out" "HOST_GITCONFIG=/tmp/my.gitconfig" "CLAUDE_GITCONFIG override honored"
rm -rf "$home"

# --- per-project key + dir (keyed on the launcher's $PWD) ---
# Assert the STRUCTURE (readable slug is a substring; dir = STATE_DIR/projects/<key>)
# rather than re-deriving the exact key, so the test isn't tautological.
res="$(run_paths CLAUDE_FLAVOR=vertex)"; home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
key="$(sed -n 's/^PROJECT_KEY=//p' <<<"$out")"
slug="$(printf '%s' "$PWD" | sed 's#/#-#g')"
assert_contains "$key" "$slug" "project key contains the readable slug of cwd"
assert_contains "$out" "HOST_PROJECT_DIR=$home/.local/state/vida-claude-container/vertex/projects/$key" "project dir = STATE_DIR/projects/<key>"
assert_eq "" "$(ls -A "$home" 2>/dev/null)" "no side effects (project key is pure)"
rm -rf "$home"

# --- collision guard: two distinct paths whose naive slug is identical must NOT
# --- map to the same PROJECT_KEY (hyphenated dir names are common). ---
run_paths_in() {  # run_paths_in DIR KEY=VAL...
    local d="$1"; shift
    local h; h="$(mktemp -d)"
    local o
    o="$(cd "$d" && env -i HOME="$h" PATH="$PATH" "$@" bash "$LAUNCHER" --print-paths 2>/dev/null)"
    printf '%s\n%s' "$h" "$o"
}
cbase="$(mktemp -d)"
mkdir -p "$cbase/foo-bar/baz" "$cbase/foo/bar-baz"
rA="$(run_paths_in "$cbase/foo-bar/baz" CLAUDE_FLAVOR=vertex)"; hA="$(head -1 <<<"$rA")"; oA="$(tail -n +2 <<<"$rA")"
rB="$(run_paths_in "$cbase/foo/bar-baz" CLAUDE_FLAVOR=vertex)"; hB="$(head -1 <<<"$rB")"; oB="$(tail -n +2 <<<"$rB")"
keyA="$(sed -n 's/^PROJECT_KEY=//p' <<<"$oA")"
keyB="$(sed -n 's/^PROJECT_KEY=//p' <<<"$oB")"
if [[ -n "$keyA" && -n "$keyB" && "$keyA" != "$keyB" ]]; then collide=distinct; else collide=collision; fi
assert_eq "distinct" "$collide" "hyphenated paths do not collide onto one PROJECT_KEY"
rm -rf "$hA" "$hB" "$cbase"

# --- env-file seeding: vertex flavor gets model/region pins, gateway does not ---
# The env seed block runs past the --print-paths early exit, so drive the launcher
# with a stub `docker` (exits 0) in an isolated HOME: seeding happens before any
# docker call, the stubbed run/volume calls no-op, and we inspect the seeded file.
seed_env() {  # seed_env FLAVOR  -> prints seeded env-file contents
    local flavor="$1" home bin
    home="$(mktemp -d)"; bin="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/docker"; chmod +x "$bin/docker"
    env -i HOME="$home" PATH="$bin:$PATH" CLAUDE_FLAVOR="$flavor" \
        bash "$LAUNCHER" </dev/null >/dev/null 2>&1 || true
    cat "$home/.config/vida-claude-container/$flavor/env" 2>/dev/null
    rm -rf "$home" "$bin"
}

venv="$(seed_env vertex)"
assert_contains "$venv" "ANTHROPIC_MODEL=claude-opus-4-8[1m]"            "vertex env seeds opus 1m primary"
assert_contains "$venv" "ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5" "vertex env seeds sonnet-5 pin"
assert_contains "$venv" "ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5" "vertex env seeds haiku pin"
assert_contains "$venv" "VERTEX_REGION_CLAUDE_HAIKU_4_5=us-east5"        "vertex env seeds haiku us-east5 override"
assert_contains "$venv" "CLOUD_ML_REGION=us"                            "vertex env seeds us multi-region"

genv="$(seed_env gateway)"
if [[ "$genv" == *"VERTEX_REGION_CLAUDE_HAIKU_4_5"* ]]; then g=present; else g=absent; fi
assert_eq "absent" "$g" "gateway env has no vertex model/region block"
assert_contains "$genv" "OKTA_ISSUER=" "gateway env still seeds the gateway block"

# --- migrate-memory: empty docker mountpoint stub must not false-trigger ---
# The per-repo bind mount nests at ~/.claude/projects/-workspace (inside the
# $STATE_CLAUDE_DIR mount), so docker recreates that path as an EMPTY mountpoint
# stub on every run. migrate-memory must treat an empty legacy dir as
# nothing-to-migrate (and tidy the stub), not collide with the populated target.
migrate_run() {  # migrate_run HOME  -> prints merged stdout+stderr
    # migrate-memory is host-side, but the launcher's shared setup touches docker
    # before dispatch, so stub it (exits 0) like seed_env does.
    local bin; bin="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/docker"; chmod +x "$bin/docker"
    env -i HOME="$1" PATH="$bin:$PATH" CLAUDE_FLAVOR=vertex \
        bash "$LAUNCHER" migrate-memory </dev/null 2>&1
    rm -rf "$bin"
}

# empty stub -> "nothing to migrate", stub removed
h="$(mktemp -d)"
legacy="$h/.local/state/vida-claude-container/vertex/claude/projects/-workspace"
mkdir -p "$legacy"
out="$(migrate_run "$h")"
assert_contains "$out" "nothing to migrate" "empty legacy stub: nothing to migrate"
if [[ -d "$legacy" ]]; then s=present; else s=gone; fi
assert_eq "gone" "$s" "empty legacy stub tidied away"
rm -rf "$h"

# real legacy data -> migrated into the per-repo key, source emptied
h="$(mktemp -d)"
legacy="$h/.local/state/vida-claude-container/vertex/claude/projects/-workspace"
mkdir -p "$legacy/memory"
printf 'fact\n' > "$legacy/memory/f.md"
out="$(migrate_run "$h")"
assert_contains "$out" "migrated" "real legacy data: migrated"
if [[ -e "$legacy/memory/f.md" ]]; then l=present; else l=gone; fi
assert_eq "gone" "$l" "legacy source moved out"
moved="$(find "$h/.local/state/vida-claude-container/vertex/projects" -name f.md 2>/dev/null | head -1)"
if [[ -n "$moved" ]]; then m=found; else m=missing; fi
assert_eq "found" "$m" "fact landed under per-repo key"
rm -rf "$h"

# --- host-only subcommands don't require a container runtime (regression) ---
# migrate-memory is pure host-side (mv); it must work even when no runtime exists.
noRt="$(mktemp -d)"          # empty state; no runtime on a minimal PATH
mmhome="$(mktemp -d)"
mmout="$(env -i HOME="$mmhome" PATH="/usr/bin:/bin" CLAUDE_FLAVOR=vertex bash "$LAUNCHER" migrate-memory 2>&1)"; mmrc=$?
assert_eq "0" "$mmrc" "migrate-memory exits 0 without a runtime"
assert_not_contains "$mmout" "no usable container runtime" "migrate-memory does not require a runtime"
rm -rf "$noRt" "$mmhome"

finish
