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
CLAUDE_ENTRYPOINT_LIB=1 source ../bin/docker-entrypoint.sh

# helper: arg1 HOST_UID, arg2 current claude uid, arg3 optional signal
run() { _CLAUDE_UID_REMAP="${3:-}" HOST_UID="$1" cr_should_remap "$2" && echo yes || echo no; }

assert_eq "yes" "$(run 1001 1000)"        "differing uid, no signal -> remap"
assert_eq "no"  "$(run 1000 1000)"        "matching uid -> no remap"
assert_eq "no"  "$(run '' 1000)"          "no HOST_UID -> no remap"
assert_eq "no"  "$(run 1001 1000 skip)"   "skip signal -> no remap even if differing"

finish
