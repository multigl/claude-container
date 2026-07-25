#!/usr/bin/env bash
# Unit tests for the pure functions extracted from container-entrypoint.sh.
# Sourced as a library (CLAUDE_ENTRYPOINT_LIB=1) so no container boot runs.
cd "$(dirname "$0")"
source ./lib.sh
CLAUDE_ENTRYPOINT_LIB=1 source ../bin/container-entrypoint.sh

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed"; finish; exit $?
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# --- cr_graft_mcp_creds ------------------------------------------------------
# Container keeps its own command paths + existing env; host env/headers are
# grafted onto servers present in BOTH; host-only servers are ignored.
cat > "$work/c.json" <<'JSON'
{"trust":true,"mcpServers":{"jira":{"command":"/opt/x","env":{"KEEP":"1"}},"conf":{"command":"/opt/y"}}}
JSON
cat > "$work/h.json" <<'JSON'
{"mcpServers":{"jira":{"command":"/host/x","env":{"TOKEN":"secret"},"headers":{"H":"v"}},"extra":{"command":"/z"}}}
JSON
out="$(cr_graft_mcp_creds "$work/c.json" "$work/h.json")"
assert_eq "/opt/x"  "$(jq -r '.mcpServers.jira.command'   <<<"$out")" "graft: container command preserved"
assert_eq "1"       "$(jq -r '.mcpServers.jira.env.KEEP'  <<<"$out")" "graft: existing container env kept"
assert_eq "secret"  "$(jq -r '.mcpServers.jira.env.TOKEN' <<<"$out")" "graft: host env merged in"
assert_eq "v"       "$(jq -r '.mcpServers.jira.headers.H' <<<"$out")" "graft: host headers grafted"
assert_eq "null"    "$(jq -r '.mcpServers.extra'          <<<"$out")" "graft: host-only server ignored"
assert_eq "true"    "$(jq -r '.trust'                     <<<"$out")" "graft: top-level container keys preserved"

# --- cr_sync_mcp_servers -----------------------------------------------------
# Deep-merge (jq *) the seed's mcpServers over the container's: seed keys win on
# conflict and seed-only servers are added; unrelated top-level container keys stay.
cat > "$work/c2.json" <<'JSON'
{"trust":true,"mcpServers":{"a":{"command":"/old"},"local":{"command":"/only-here"}}}
JSON
cat > "$work/seed.json" <<'JSON'
{"mcpServers":{"a":{"command":"/seed"},"b":{"command":"/newb"}}}
JSON
out="$(cr_sync_mcp_servers "$work/c2.json" "$work/seed.json")"
assert_eq "/seed"      "$(jq -r '.mcpServers.a.command'     <<<"$out")" "sync: seed wins on shared server"
assert_eq "/newb"      "$(jq -r '.mcpServers.b.command'     <<<"$out")" "sync: seed-only server added"
assert_eq "/only-here" "$(jq -r '.mcpServers.local.command' <<<"$out")" "sync: container-only server survives"
assert_eq "true"       "$(jq -r '.trust'                    <<<"$out")" "sync: container top-level keys preserved"

# --- cr_render_gitconfig -----------------------------------------------------
# Valid [user] identity is included ahead of the static blocks; an invalid or
# missing identity file yields only the static blocks (never garbage).
printf '[user]\n\tname = Ada\n\temail = ada@x.dev\n' > "$work/id.ok"
out="$(cr_render_gitconfig "$work/id.ok")"
assert_contains "$out" "name = Ada"           "gitconfig: valid identity included"
assert_contains "$out" "directory = *"        "gitconfig: static [safe] present"
assert_contains "$out" "defaultBranch = main" "gitconfig: static [init] present"

printf 'this is not a user block\n' > "$work/id.bad"
out="$(cr_render_gitconfig "$work/id.bad")"
assert_not_contains "$out" "this is not a user block" "gitconfig: garbage identity dropped"
assert_contains     "$out" "directory = *"            "gitconfig: static blocks still emitted"

out="$(cr_render_gitconfig "$work/does-not-exist")"
assert_not_contains "$out" "[user]"            "gitconfig: missing file -> no [user]"
assert_contains     "$out" "defaultBranch = main" "gitconfig: missing file -> static blocks"

# --- cr_render_global_index --------------------------------------------------
# Global MEMORY.md bullets are inlined into ~/.claude/CLAUDE.md (one dir above
# memory-global/), so a bare-filename link would 404. Bare targets get the
# memory-global/ prefix; already-qualified targets (slash/URL) are left alone;
# an empty/missing index yields the placeholder.
cat > "$work/gmem.md" <<'MD'
# Memory index

- [byo provider spec](byo-provider-spec.md) — some hook
- [already qualified](memory-global/keep.md) — must not double-prefix
- [external](https://example.com/x.md) — URL untouched
MD
out="$(cr_render_global_index "$work/gmem.md")"
assert_contains     "$out" "](memory-global/byo-provider-spec.md)" "index: bare target prefixed"
assert_not_contains "$out" "](byo-provider-spec.md)"               "index: original bare target rewritten"
assert_contains     "$out" "](memory-global/keep.md)"              "index: already-qualified kept"
assert_not_contains "$out" "memory-global/memory-global"           "index: no double-prefix"
assert_contains     "$out" "](https://example.com/x.md)"          "index: URL target untouched"

printf '# Memory index\n\n_(none yet)_\n' > "$work/gmem-empty.md"
assert_eq "_(none yet)_" "$(cr_render_global_index "$work/gmem-empty.md")" "index: no bullets -> placeholder"
assert_eq "_(none yet)_" "$(cr_render_global_index "$work/does-not-exist.md")" "index: missing file -> placeholder"

finish
