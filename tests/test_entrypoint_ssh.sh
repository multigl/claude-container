#!/usr/bin/env bash
# cr_build_exec_env behavior: which vars survive the gosu drop to the claude user.
# The two root-only steps (~/.ssh creation, forwarded-socket chown) and the final
# `exec gosu` can't be unit-run non-root, so they stay asserted on source text.
cd "$(dirname "$0")"
source ./lib.sh
CLAUDE_ENTRYPOINT_LIB=1 source ../bin/container-entrypoint.sh
EP="$(pwd)/../bin/container-entrypoint.sh"
src="$(cat "$EP")"

# --- behavior: cr_build_exec_env (env prefixes make each case hermetic) ------
out="$(SSH_AUTH_SOCK=/ssh-agent CLAUDE_CODE_USE_VERTEX= cr_build_exec_env)"
assert_contains "$out" "HOME=/home/claude"        "exec env: always sets HOME"
assert_contains "$out" "SSH_AUTH_SOCK=/ssh-agent" "exec env: forwards SSH_AUTH_SOCK when set"

out="$(SSH_AUTH_SOCK= CLAUDE_CODE_USE_VERTEX= cr_build_exec_env)"
assert_not_contains "$out" "SSH_AUTH_SOCK" "exec env: no SSH_AUTH_SOCK line when unset"

out="$(SSH_AUTH_SOCK= CLAUDE_CODE_USE_VERTEX=1 GOOGLE_APPLICATION_CREDENTIALS=/adc.json cr_build_exec_env)"
assert_contains "$out" "GOOGLE_APPLICATION_CREDENTIALS=/adc.json" "exec env: vertex adds GAC"

out="$(SSH_AUTH_SOCK= CLAUDE_CODE_USE_VERTEX= cr_build_exec_env)"
assert_not_contains "$out" "GOOGLE_APPLICATION_CREDENTIALS" "exec env: no GAC line when vertex unset"

# --- root-only side-effect glue: not unit-runnable non-root, assert on source -
assert_contains "$src" '/home/claude/.ssh' "entrypoint ensures ~/.ssh (root-only glue)"
assert_contains "$src" 'chown claude:claude "$SSH_AUTH_SOCK"' "entrypoint re-owns forwarded socket (root-only glue)"

finish
