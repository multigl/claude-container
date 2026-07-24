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

finish
