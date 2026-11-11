#!/usr/bin/env bash
# Flavor selection and the per-flavor subcommands, driven from outside. An
# explicit unknown CLAUDE_FLAVOR must be a hard error rather than a silent
# fall-through to whichever branch happened to be the `else`. The
# driver-sourcing checks only apply to the bash launcher; the Go drivers are
# covered by internal/flavor/flavor_test.go.
cd "$(dirname "$0")"
source ./lib.sh
setup_host_tools
FLAVORS_DIR="$(pwd)/../bin/flavors"

if [[ "$LAUNCHER" == *.sh ]]; then
CONTRACT="fl_cred_dirs fl_cred_paths fl_run_flags fl_auth fl_seed_env fl_print_paths fl_doctor fl_legacy_volume"

for driver in "$FLAVORS_DIR"/*.sh; do
    name="$(basename "$driver" .sh)"
    defined="$(
      (
        export CLAUDE_LAUNCHER_LIB=1 HOME="$(mktemp -d)"
        source "$LAUNCHER"
        STATE_DIR="/x/state"; CFG_DIR="/x/cfg"; STATE_CLAUDE_DIR="/x/state/claude"
        source "$driver"
        for fn in $CONTRACT; do
            declare -f "$fn" >/dev/null 2>&1 && printf '%s\n' "$fn"
        done
      ) 2>/dev/null
    )"
    for fn in $CONTRACT; do
        assert_contains "$defined" "$fn" "$name driver defines $fn"
    done
done

# vertex still owns the gcloud cred dir, gateway still owns the okta one
vpaths="$(
  ( export CLAUDE_LAUNCHER_LIB=1 HOME="$(mktemp -d)"; source "$LAUNCHER"
    STATE_DIR="/x/state"; source "$FLAVORS_DIR/vertex.sh"; fl_print_paths ) 2>/dev/null
)"
assert_contains "$vpaths" "CRED_GCLOUD_DIR=/x/state/creds/gcloud" "vertex driver reports the gcloud cred dir"

gpaths="$(
  ( export CLAUDE_LAUNCHER_LIB=1 HOME="$(mktemp -d)"; source "$LAUNCHER"
    STATE_DIR="/x/state"; source "$FLAVORS_DIR/gateway.sh"; fl_print_paths ) 2>/dev/null
)"
assert_contains "$gpaths" "CRED_OKTA_DIR=/x/state/creds/okta" "gateway driver reports the okta cred dir"
fi

# with no CLAUDE_FLAVOR and an unrecognized invocation name, the default is personal
h="$(mktemp -d)"
out="$(env -i HOME="$h" PATH="$HOST_TOOLS" "$LAUNCHER" --print-paths 2>/dev/null)"
assert_contains "$out" "FLAVOR=personal" "default flavor is personal"
rm -rf "$h"

# an explicit unknown flavor is rejected, and the message names the known ones
h="$(mktemp -d)"
out="$(env -i HOME="$h" PATH="$HOST_TOOLS" CLAUDE_FLAVOR=nosuch "$LAUNCHER" --print-paths 2>&1)"; rc=$?
assert_contains "$out" "unknown flavor" "unknown CLAUDE_FLAVOR is rejected"
assert_contains "$out" "vertex"         "rejection lists the known flavors"
if [[ "$rc" -ne 0 ]]; then s=nonzero; else s=zero; fi
assert_eq "nonzero" "$s" "unknown flavor exits non-zero"
rm -rf "$h"

# --- reset-auth deletes exactly what fl_cred_paths names, no runtime needed ---
# The cred path is derived from --print-paths rather than hardcoded, so this
# test is correct both before and after the namespace rename in Task 4.
h="$(mktemp -d)"
cred="$(env -i HOME="$h" PATH="$HOST_TOOLS" CLAUDE_FLAVOR=vertex "$LAUNCHER" --print-paths 2>/dev/null | sed -n 's/^CRED_GCLOUD_DIR=//p')"
mkdir -p "$cred"
printf '{}\n' > "$cred/application_default_credentials.json"
out="$(env -i HOME="$h" PATH="$HOST_TOOLS" CLAUDE_FLAVOR=vertex "$LAUNCHER" reset-auth 2>&1)"; rc=$?
assert_eq "0" "$rc" "reset-auth exits 0 without a container runtime"
assert_contains "$out" "wiped" "reset-auth reports what it wiped"
if [[ -e "$cred" ]]; then s=present; else s=gone; fi
assert_eq "gone" "$s" "reset-auth removed the cred dir"
rm -rf "$h"

# --- reset-auth reports a failed removal honestly and exits non-zero ---
# Real permission-denied failure, not a mocked rm: strip write on the cred dir's
# parent so rm -rf can empty the cred dir but cannot unlink the dir itself.
h="$(mktemp -d)"
cred="$(env -i HOME="$h" PATH="$HOST_TOOLS" CLAUDE_FLAVOR=vertex "$LAUNCHER" --print-paths 2>/dev/null | sed -n 's/^CRED_GCLOUD_DIR=//p')"
parent="$(dirname "$cred")"
mkdir -p "$cred"
printf '{}\n' > "$cred/application_default_credentials.json"
chmod 500 "$parent"
out="$(env -i HOME="$h" PATH="$HOST_TOOLS" CLAUDE_FLAVOR=vertex "$LAUNCHER" reset-auth 2>&1)"; rc=$?
chmod 700 "$parent"
assert_contains "$out" "failed to remove" "reset-auth reports a removal that failed, not \"wiped\""
if [[ "$rc" -ne 0 ]]; then s=nonzero; else s=zero; fi
assert_eq "nonzero" "$s" "reset-auth exits non-zero when a removal fails"
rm -rf "$h"

# --- doctor reports the missing credential, no runtime needed ---
h="$(mktemp -d)"
out="$(env -i HOME="$h" PATH="$HOST_TOOLS" CLAUDE_FLAVOR=vertex "$LAUNCHER" doctor 2>&1)"; rc=$?
assert_eq "0" "$rc" "doctor exits 0 without a container runtime"
assert_contains "$out" "MISSING ADC" "doctor reports absent ADC credentials"
# The seeded config.toml leaves the project commented out, so a fresh install is
# reported as missing rather than silently 403ing later.
assert_contains "$out" "MISSING PROJECT" "doctor reports an unset vertex project"
rm -rf "$h"

# --- doctor reads the vertex project out of config.toml ---
h="$(mktemp -d)"
config="$(env -i HOME="$h" PATH="$HOST_TOOLS" CLAUDE_FLAVOR=vertex "$LAUNCHER" --print-paths 2>/dev/null | sed -n 's/^HOST_CONFIG=//p')"
mkdir -p "$(dirname "$config")"
printf '[env]\nANTHROPIC_VERTEX_PROJECT_ID = "acme-ai-prod"\n' > "$config"
out="$(env -i HOME="$h" PATH="$HOST_TOOLS" CLAUDE_FLAVOR=vertex "$LAUNCHER" doctor 2>&1)"
assert_contains     "$out" "ok: vertex project acme-ai-prod" "doctor reports the configured project"
assert_not_contains "$out" "MISSING PROJECT"                 "a configured project is not reported missing"
rm -rf "$h"

if [[ "$LAUNCHER" == *.sh ]]; then
# --- personal driver: no extra mount, credential inside the existing one ---
# probe_personal prints "defined" when FUNC exists, then whatever FUNC emits.
# Asserting bare emptiness would pass even if the driver file were missing:
# the "command not found" goes to the discarded stderr and stdout is empty.
probe_personal() {  # probe_personal FUNC
  ( export CLAUDE_LAUNCHER_LIB=1 HOME="$(mktemp -d)"
    source "$LAUNCHER"
    STATE_DIR="/x/state"; STATE_CLAUDE_DIR="/x/state/claude"
    source "$FLAVORS_DIR/personal.sh" || exit 1
    declare -f "$1" >/dev/null 2>&1 || exit 1
    printf 'defined\n'
    "$1" ) 2>/dev/null
}

assert_eq "defined" "$(probe_personal fl_run_flags)"     "personal driver defines fl_run_flags and it emits no run flags"
assert_eq "defined" "$(probe_personal fl_cred_dirs)"     "personal driver defines fl_cred_dirs and it creates no cred dir"
assert_eq "defined" "$(probe_personal fl_legacy_volume)" "personal driver defines fl_legacy_volume and it names no legacy volume"

pcred="$(
  ( export CLAUDE_LAUNCHER_LIB=1 HOME="$(mktemp -d)"; source "$LAUNCHER"
    STATE_DIR="/x/state"; STATE_CLAUDE_DIR="/x/state/claude"
    source "$FLAVORS_DIR/personal.sh"; fl_cred_paths ) 2>/dev/null
)"
assert_eq "/x/state/claude/.credentials.json" "$pcred" "personal credential is the file inside the .claude mount"
fi

# --- personal wrapper name maps to the personal flavor ---
lnh="$(mktemp -d)"; lnd="$(mktemp -d)"
ln -s "$LAUNCHER" "$lnd/claude-personal"
o="$(env -i HOME="$lnh" PATH="$HOST_TOOLS" "$lnd/claude-personal" --print-paths 2>&1)"
assert_contains "$o" "FLAVOR=personal" "claude-personal wrapper selects the personal flavor"
rm -rf "$lnh" "$lnd"

finish
