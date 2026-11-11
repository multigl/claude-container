#!/usr/bin/env bash
# Tests for the launcher's --print-paths (pure path resolution, no side effects)
# plus first-launch seeding, migrate-memory and state-dir permissions.
cd "$(dirname "$0")"
source ./lib.sh

# Run --print-paths in an isolated HOME with a controlled env. Prints
# "<scratchHOME>\n<launcher output>"; caller checks emptiness then removes the dir.
# NOTE: no assert_* calls in here -- this runs inside $(...) so its stdout is
# captured, and assert output would be swallowed / corrupt the head/tail split.
run_paths() {  # run_paths KEY=VAL...
    local home; home="$(mktemp -d)"
    local out
    out="$(env -i HOME="$home" PATH="$PATH" "$@" "$LAUNCHER" --print-paths 2>/dev/null)"
    printf '%s\n%s' "$home" "$out"
}

# --- XDG unset -> ~/.config + ~/.local/state defaults, vertex flavor ---
res="$(run_paths CLAUDE_FLAVOR=vertex)"; home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_eq "" "$(ls -A "$home" 2>/dev/null)" "no side effects (vertex defaults)"
assert_contains "$out" "CFG_DIR=$home/.config/claude-container/vertex"       "vertex config default"
assert_contains "$out" "STATE_DIR=$home/.local/state/claude-container/vertex" "vertex state default"
assert_contains "$out" "STATE_CLAUDE_DIR=$home/.local/state/claude-container/vertex/claude"        "vertex .claude dir"
assert_contains "$out" "HOST_DOTCLAUDE=$home/.local/state/claude-container/vertex/claude/claude.json" "vertex .claude.json (inside claude/ dir mount)"
assert_contains "$out" "CRED_GCLOUD_DIR=$home/.local/state/claude-container/vertex/creds/gcloud" "vertex gcloud cred dir"
assert_contains "$out" "HOST_SETTINGS=$home/.config/claude-container/vertex/settings.override.json" "vertex override path"
assert_contains "$out" "HOST_CONFIG=$home/.config/claude-container/vertex/config.toml" "vertex config.toml default"
assert_contains "$out" "RUNTIME=" "print-paths includes RUNTIME"
assert_contains "$out" "VERSION=" "print-paths includes VERSION"
rm -rf "$home"

# --- gateway flavor -> distinct per-flavor dirs ---
res="$(run_paths CLAUDE_FLAVOR=gateway)"; home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_contains "$out" "CFG_DIR=$home/.config/claude-container/gateway"        "gateway config default"
assert_contains "$out" "STATE_DIR=$home/.local/state/claude-container/gateway" "gateway state default"
assert_contains "$out" "CRED_OKTA_DIR=$home/.local/state/claude-container/gateway/creds/okta" "gateway okta cred dir"
rm -rf "$home"

# --- --print-runtime resolves the runtime (docker stub present) ---
rtbin="$(mktemp -d)"; printf '#!/usr/bin/env bash\ncase "$1 $2" in "info "*|"info") exit 0;; esac\nexit 0\n' > "$rtbin/docker"; chmod +x "$rtbin/docker"
prhome="$(mktemp -d)"
pr="$(env -i HOME="$prhome" PATH="$rtbin:/usr/bin:/bin" CLAUDE_FLAVOR=vertex "$LAUNCHER" --print-runtime 2>/dev/null)"
assert_contains "$pr" "RUNTIME=docker" "--print-runtime resolves docker when only docker present"
rm -rf "$rtbin" "$prhome"

# --- XDG_CONFIG_HOME / XDG_STATE_HOME honored ---
res="$(run_paths CLAUDE_FLAVOR=vertex XDG_CONFIG_HOME=/x/cfg XDG_STATE_HOME=/x/state)"
home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_contains "$out" "CFG_DIR=/x/cfg/claude-container/vertex"     "XDG_CONFIG_HOME honored"
assert_contains "$out" "STATE_DIR=/x/state/claude-container/vertex" "XDG_STATE_HOME honored"
rm -rf "$home"

# --- config override env vars redirect their target ---
res="$(run_paths CLAUDE_FLAVOR=vertex CLAUDE_CONFIG=/tmp/my.toml CLAUDE_SETTINGS=/tmp/my.json)"
home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
assert_contains "$out" "HOST_CONFIG=/tmp/my.toml"   "CLAUDE_CONFIG override honored"
assert_contains "$out" "HOST_SETTINGS=/tmp/my.json" "CLAUDE_SETTINGS override honored"
rm -rf "$home"

# --- image resolution: CLAUDE_IMAGE > config.toml image > published GHCR default ---
run_paths_with_conf() {  # run_paths_with_conf CONF_TEXT KEY=VAL...  (flavor via CLAUDE_FLAVOR)
    local conf="$1"; shift
    local home; home="$(mktemp -d)"
    local flavor=personal kv
    for kv in "$@"; do [[ "$kv" == CLAUDE_FLAVOR=* ]] && flavor="${kv#CLAUDE_FLAVOR=}"; done
    mkdir -p "$home/.config/claude-container/$flavor"
    printf '%s\n' "$conf" > "$home/.config/claude-container/$flavor/config.toml"
    local out
    out="$(env -i HOME="$home" PATH="$PATH" "$@" "$LAUNCHER" --print-paths 2>/dev/null)"
    printf '%s\n%s' "$home" "$out"
}

image_of() { sed -n 's/^IMAGE=//p' <<<"$(tail -n +2 <<<"$1")"; }

res="$(run_paths CLAUDE_FLAVOR=personal)"
assert_eq "ghcr.io/multigl/claude-container:personal-latest" "$(image_of "$res")" "default image is published personal-latest"
rm -rf "$(head -1 <<<"$res")"

res="$(run_paths CLAUDE_FLAVOR=vertex)"
assert_eq "ghcr.io/multigl/claude-container:vertex-latest" "$(image_of "$res")" "default image follows flavor"
rm -rf "$(head -1 <<<"$res")"

res="$(run_paths_with_conf 'image = "local-dev:1"   # local dev' CLAUDE_FLAVOR=personal)"
assert_eq "local-dev:1" "$(image_of "$res")" "config.toml image key"
rm -rf "$(head -1 <<<"$res")"

res="$(run_paths_with_conf 'image = "claude-personal:latest"' CLAUDE_FLAVOR=personal CLAUDE_IMAGE=foo:bar)"
assert_eq "foo:bar" "$(image_of "$res")" "CLAUDE_IMAGE beats config.toml image"
rm -rf "$(head -1 <<<"$res")"

res="$(run_paths_with_conf 'image = "local-dev:1"' CLAUDE_FLAVOR=personal CLAUDE_IMAGE=)"
assert_eq "local-dev:1" "$(image_of "$res")" "empty CLAUDE_IMAGE treated as unset"
rm -rf "$(head -1 <<<"$res")"

# --- per-project key + dir (keyed on the launcher's $PWD) ---
# Assert the STRUCTURE (readable slug is a substring; dir = STATE_DIR/projects/<key>)
# rather than re-deriving the exact key, so the test isn't tautological.
res="$(run_paths CLAUDE_FLAVOR=vertex)"; home="$(head -1 <<<"$res")"; out="$(tail -n +2 <<<"$res")"
key="$(sed -n 's/^PROJECT_KEY=//p' <<<"$out")"
slug="$(printf '%s' "$PWD" | sed 's#/#-#g')"
assert_contains "$key" "$slug" "project key contains the readable slug of cwd"
assert_contains "$out" "HOST_PROJECT_DIR=$home/.local/state/claude-container/vertex/projects/$key" "project dir = STATE_DIR/projects/<key>"
assert_eq "" "$(ls -A "$home" 2>/dev/null)" "no side effects (project key is pure)"
rm -rf "$home"

# --- collision guard: two distinct paths whose naive slug is identical must NOT
# --- map to the same PROJECT_KEY (hyphenated dir names are common). ---
run_paths_in() {  # run_paths_in DIR KEY=VAL...
    local d="$1"; shift
    local h; h="$(mktemp -d)"
    local o
    o="$(cd "$d" && env -i HOME="$h" PATH="$PATH" "$@" "$LAUNCHER" --print-paths 2>/dev/null)"
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

# --- config.toml seeding: vertex flavor gets model/region pins, gateway does not ---
# Seeding runs past the --print-paths early exit, so drive a real launch with a
# stub `docker` (exits 0) in an isolated HOME and inspect the seeded file.
# CLAUDE_RUNTIME and the bare PATH keep a real runtime or `gh` from being used.
seed_config() {  # seed_config FLAVOR  -> prints "<mode>\n<seeded config.toml>"
    local flavor="$1" home bin config
    home="$(mktemp -d)"; bin="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/docker"; chmod +x "$bin/docker"
    env -i HOME="$home" PATH="$bin:/usr/bin:/bin" CLAUDE_FLAVOR="$flavor" CLAUDE_RUNTIME=docker \
        "$LAUNCHER" </dev/null >/dev/null 2>&1 || true
    config="$home/.config/claude-container/$flavor/config.toml"
    stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config" 2>/dev/null
    cat "$config" 2>/dev/null
    rm -rf "$home" "$bin"
}

vconfig="$(seed_config vertex)"
assert_eq "600" "$(head -1 <<<"$vconfig")" "seeded config.toml is 600"
assert_contains "$vconfig" 'ANTHROPIC_MODEL = "claude-opus-5[1m]"'             "vertex config seeds opus 1m primary"
assert_contains "$vconfig" 'ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-5"' "vertex config seeds sonnet-5 pin"
assert_contains "$vconfig" 'ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5"' "vertex config seeds haiku pin"
assert_contains "$vconfig" 'VERTEX_REGION_CLAUDE_HAIKU_4_5 = "us-east5"'        "vertex config seeds haiku us-east5 override"
assert_contains "$vconfig" 'CLOUD_ML_REGION = "us"'                             "vertex config seeds us multi-region"

gconfig="$(seed_config gateway)"
if [[ "$gconfig" == *"VERTEX_REGION_CLAUDE_HAIKU_4_5"* ]]; then g=present; else g=absent; fi
assert_eq "absent" "$g" "gateway config has no vertex model/region block"
assert_contains "$gconfig" "OKTA_ISSUER = " "gateway config still seeds the gateway block"

# --- migrate-memory: empty docker mountpoint stub must not false-trigger ---
# The per-repo bind mount nests at ~/.claude/projects/-workspace (inside the
# $STATE_CLAUDE_DIR mount), so docker recreates that path as an EMPTY mountpoint
# stub on every run. migrate-memory must treat an empty legacy dir as
# nothing-to-migrate (and tidy the stub), not collide with the populated target.
migrate_run() {  # migrate_run HOME  -> prints merged stdout+stderr
    # migrate-memory is host-side; the docker stub (exits 0) only guards against
    # a launcher that probes a runtime before dispatch.
    local bin; bin="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/docker"; chmod +x "$bin/docker"
    env -i HOME="$1" PATH="$bin:/usr/bin:/bin" CLAUDE_FLAVOR=vertex CLAUDE_RUNTIME=docker \
        "$LAUNCHER" migrate-memory </dev/null 2>&1
    rm -rf "$bin"
}

# empty stub -> "nothing to migrate", stub removed
h="$(mktemp -d)"
legacy="$h/.local/state/claude-container/vertex/claude/projects/-workspace"
mkdir -p "$legacy"
out="$(migrate_run "$h")"
assert_contains "$out" "nothing to migrate" "empty legacy stub: nothing to migrate"
if [[ -d "$legacy" ]]; then s=present; else s=gone; fi
assert_eq "gone" "$s" "empty legacy stub tidied away"
rm -rf "$h"

# real legacy data -> migrated into the per-repo key, source emptied
h="$(mktemp -d)"
legacy="$h/.local/state/claude-container/vertex/claude/projects/-workspace"
mkdir -p "$legacy/memory"
printf 'fact\n' > "$legacy/memory/f.md"
out="$(migrate_run "$h")"
assert_contains "$out" "migrated" "real legacy data: migrated"
if [[ -e "$legacy/memory/f.md" ]]; then l=present; else l=gone; fi
assert_eq "gone" "$l" "legacy source moved out"
moved="$(find "$h/.local/state/claude-container/vertex/projects" -name f.md 2>/dev/null | head -1)"
if [[ -n "$moved" ]]; then m=found; else m=missing; fi
assert_eq "found" "$m" "fact landed under per-repo key"
rm -rf "$h"

# --- host-only subcommands don't require a container runtime (regression) ---
# migrate-memory is pure host-side (mv); it must work even when no runtime exists.
noRt="$(mktemp -d)"          # empty state; no runtime on a minimal PATH
mmhome="$(mktemp -d)"
mmout="$(env -i HOME="$mmhome" PATH="/usr/bin:/bin" CLAUDE_FLAVOR=vertex "$LAUNCHER" migrate-memory 2>&1)"; mmrc=$?
assert_eq "0" "$mmrc" "migrate-memory exits 0 without a runtime"
assert_not_contains "$mmout" "no usable container runtime" "migrate-memory does not require a runtime"
rm -rf "$noRt" "$mmhome"

# --- $STATE_CLAUDE_DIR is re-tightened to 0700 on every launch ---
# It holds claude.json with grafted MCP credentials for every flavor, and a
# plaintext OAuth token for the personal flavor. Same reasoning as the 600
# re-tighten on config.toml: a dir restored from a loose backup must not stay
# loose. Uses the seed_config stub-docker harness so the launcher runs to the end.
perm_home="$(mktemp -d)"; perm_bin="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$perm_bin/docker"; chmod +x "$perm_bin/docker"
mkdir -p "$perm_home/.local/state/claude-container/vertex/claude"
chmod 777 "$perm_home/.local/state/claude-container/vertex/claude"
env -i HOME="$perm_home" PATH="$perm_bin:/usr/bin:/bin" CLAUDE_FLAVOR=vertex CLAUDE_RUNTIME=docker \
    "$LAUNCHER" </dev/null >/dev/null 2>&1 || true
mode="$(ls -ld "$perm_home/.local/state/claude-container/vertex/claude" | cut -c1-10)"
assert_eq "drwx------" "$mode" "pre-existing loose STATE_CLAUDE_DIR is re-tightened to 0700"
rm -rf "$perm_home" "$perm_bin"

pconfig="$(seed_config personal)"
assert_contains "$pconfig" "CONTEXT7_API_KEY = " "personal config seeds the context7 key"
assert_not_contains "$pconfig" "JIRA_URL"         "personal config has no Atlassian block"
assert_not_contains "$pconfig" "OKTA_ISSUER"      "personal config has no Okta block"
assert_not_contains "$pconfig" "ANTHROPIC_MODEL"  "personal config pins no model"

finish
