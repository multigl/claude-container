#!/usr/bin/env bash
# The entrypoint's remap-gate decision, extracted into cr_should_remap so it is
# unit-testable without a container. Contract:
#   remap when HOST_UID is set AND differs from the current claude uid AND the
#   internal _CLAUDE_UID_REMAP signal is not "skip".
cd "$(dirname "$0")"
source ./lib.sh

# Source just the function out of the entrypoint. The entrypoint defines its
# functions, then early-returns when CLAUDE_ENTRYPOINT_LIB=1 (before it runs any
# container-only boot logic).
CLAUDE_ENTRYPOINT_LIB=1 source ../bin/container-entrypoint.sh

# helper: arg1 HOST_UID, arg2 current claude uid, arg3 optional signal
run() { _CLAUDE_UID_REMAP="${3:-}" HOST_UID="$1" cr_should_remap "$2" && echo yes || echo no; }

assert_eq "yes" "$(run 1001 1000)"        "differing uid, no signal -> remap"
assert_eq "no"  "$(run 1000 1000)"        "matching uid -> no remap"
assert_eq "no"  "$(run '' 1000)"          "no HOST_UID -> no remap"
assert_eq "no"  "$(run 1001 1000 skip)"   "skip signal -> no remap even if differing"

# --- cr_remap_user: non-fatal, testable remap wrapper ------------------------
# Override usermod/groupmod as shell functions (a function beats a PATH binary
# for an unqualified call) to record invocations and script their exit codes,
# without touching real system accounts.
_calls=""
groupmod() { _calls+="groupmod $*;"; return 0; }
usermod()  { _calls+="usermod $*;"; return "${_USERMOD_RC:-0}"; }

# Note: cr_remap_user is invoked as a plain foreground command (not inside
# "$( )") so its mutations to _calls land in *this* shell -- wrapping the call
# itself in command substitution would fork a subshell and any _calls updates
# made there would be discarded once it exits. Stderr is instead captured via
# a temp file redirect, which doesn't require a subshell.
_err_file="$(mktemp)"
trap 'rm -f "$_err_file"' EXIT

# success: differing uid + usermod succeeds -> usermod invoked, returns 0, no warn
_calls=""; _USERMOD_RC=0
HOST_UID=1001 HOST_GID=1001 cr_remap_user 1000 2>"$_err_file"; rc=$?
err="$(<"$_err_file")"
assert_eq 0 "$rc" "cr_remap_user success: returns 0"
assert_contains "$_calls" "usermod -u 1001" "cr_remap_user success: usermod called with host uid"
assert_not_contains "$err" "continuing as uid 1000" "cr_remap_user success: no warning"

# collision: usermod fails -> STILL returns 0 (non-fatal) and warns
_calls=""; _USERMOD_RC=1
HOST_UID=1001 HOST_GID=1001 cr_remap_user 1000 2>"$_err_file"; rc=$?
err="$(<"$_err_file")"
assert_eq 0 "$rc" "cr_remap_user collision: returns 0 (boot survives)"
assert_contains "$err" "continuing as uid 1000" "cr_remap_user collision: warns"

# skip: matching uid -> usermod never called
_calls=""; _USERMOD_RC=0
HOST_UID=1000 cr_remap_user 1000 >/dev/null 2>&1
assert_eq "" "$_calls" "cr_remap_user matching uid: usermod not called"

finish
