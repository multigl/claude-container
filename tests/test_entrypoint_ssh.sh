#!/usr/bin/env bash
# Guard: the entrypoint must (1) preserve SSH_AUTH_SOCK into the gosu exec env so
# a forwarded agent survives the drop to the non-root claude user, and (2) create
# ~/.ssh. The final `exec gosu` can't be unit-run, so assert on the source.
cd "$(dirname "$0")"
source ./lib.sh
EP="$(pwd)/../bin/docker-entrypoint.sh"
src="$(cat "$EP")"

assert_contains "$src" 'exec_env+=( "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" )' "entrypoint preserves SSH_AUTH_SOCK into exec_env"
assert_contains "$src" '/home/claude/.ssh' "entrypoint ensures ~/.ssh"
assert_contains "$src" 'chown claude:claude "$SSH_AUTH_SOCK"' "entrypoint re-owns forwarded agent socket for non-root claude"

finish
