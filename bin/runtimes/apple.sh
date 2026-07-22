#!/usr/bin/env bash
# apple `container` driver (macOS 26+, Apple Silicon). Each container is a
# lightweight VM; bind-mount ownership is translated through the VM file share
# like Docker Desktop, so the entrypoint remap is a no-op (no userns flag, no
# remap-skip signal). Flag surface (-v/--env-file/-e/--rm/-w/-it/build --target)
# matches docker per the apple/container command reference (v1.1.0).

rt_bin() { printf 'container\n'; }

rt_run_flags() { :; }

rt_build_cmd() { printf 'container build -f %s/Containerfile --target %s -t %s %s\n' "$3" "$1" "$2" "$3"; }

rt_run() { container run "$@"; }
