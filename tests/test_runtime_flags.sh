#!/usr/bin/env bash
# Per-driver flag assembly. Sourced with CR_SOURCED=1 so no host action runs;
# we assert the flags each driver contributes. `getenforce` is stubbed per case.
cd "$(dirname "$0")"
source ./lib.sh
export CR_SOURCED=1
CRDIR="$(pwd)/../bin"

load_driver() {  # load_driver docker|podman|apple
    unset -f rt_bin rt_run_flags rt_build_cmd rt_run 2>/dev/null
    source "$CRDIR/container-runtime.sh"
    source "$CRDIR/runtimes/$1.sh"
}

# docker driver -------------------------------------------------------------
load_driver docker
assert_eq "docker" "$(rt_bin)" "docker rt_bin"
flags="$(rt_run_flags)"
assert_not_contains "$flags" "userns"            "docker: no userns flag"
assert_not_contains "$flags" "_CLAUDE_UID_REMAP" "docker: no remap-skip (uses HOST_UID remap)"
build="$(rt_build_cmd vertex claude-vertex:latest /ctx)"
assert_contains "$build" "docker build"          "docker: build uses docker"
assert_contains "$build" "-f /ctx/Containerfile" "docker: build -f Containerfile"
assert_contains "$build" "--target vertex"       "docker: build --target"

finish
