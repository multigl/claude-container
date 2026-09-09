#!/usr/bin/env bash
# The launcher doubles as a library: sourcing it with CLAUDE_LAUNCHER_LIB=1 must
# define its pure helpers and stop before any side effect. Mirrors the
# CLAUDE_ENTRYPOINT_LIB=1 guard in bin/container-entrypoint.sh.
cd "$(dirname "$0")"
source ./lib.sh
LAUNCHER="$(pwd)/../bin/claude-launcher.sh"

# Source in a scratch HOME and report which helpers exist + whether anything was written.
probe="$(
  h="$(mktemp -d)"
  (
    export CLAUDE_LAUNCHER_LIB=1 HOME="$h"
    source "$LAUNCHER"
    for fn in _conf_get _is_truthy _resolve_ssh_pubkey_literal _stage_git_identity; do
      declare -f "$fn" >/dev/null 2>&1 && printf 'have:%s\n' "$fn"
    done
    printf 'NS:%s\n' "${NS:-unset}"
  ) 2>/dev/null
  printf 'residue:[%s]\n' "$(ls -A "$h" 2>/dev/null | tr '\n' ' ')"
  rm -rf "$h"
)"

assert_contains "$probe" "have:_conf_get"                   "sourcing defines _conf_get"
assert_contains "$probe" "have:_is_truthy"                  "sourcing defines _is_truthy"
assert_contains "$probe" "have:_resolve_ssh_pubkey_literal" "sourcing defines _resolve_ssh_pubkey_literal"
assert_contains "$probe" "have:_stage_git_identity"         "sourcing defines _stage_git_identity"
assert_contains "$probe" "NS:claude-container"              "NS constant available when sourced"
assert_contains "$probe" "residue:[]"                       "sourcing writes nothing into HOME"

finish
