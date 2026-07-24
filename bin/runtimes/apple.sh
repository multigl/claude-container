#!/usr/bin/env bash
# apple `container` driver (macOS 26+, Apple Silicon). Each container is a
# lightweight VM whose bind-mount file share PASSES HOST UIDs THROUGH (unlike
# Docker Desktop's uid-agnostic gRPC-FUSE). So the entrypoint's usermod remap to
# the host UID is REQUIRED, not a no-op: with claude remapped to the host uid,
# in-container ownership matches what the share presents and rsync never attempts
# chown/chgrp; keeping claude at uid 1000 (a skip signal) instead makes rsync try
# to fix the mismatched ownership and fail (EPERM). Hence NO remap-skip signal and
# no userns flag -- apple uses the same HOST_UID remap path as docker. (The share
# does reject the chown/utimensat *syscalls* on the mount regardless of uid, which
# is why the entrypoint's explicit chowns are best-effort and the seed rsync drops
# time preservation.) Flag surface (-v/--env-file/-e/--rm/-w/-it/build --target)
# matches docker per the apple/container command reference (v1.1.0).

rt_bin() { printf 'container\n'; }

rt_run_flags() { :; }

# SSH agent forwarding: apple `container --ssh` bind-mounts the real host
# $SSH_AUTH_SOCK through virtualization and sets SSH_AUTH_SOCK inside the guest,
# so we only add the flag -- no -v/-e (apple manages the in-guest socket path).
rt_ssh_flags() {
    [[ -n "${SSH_AUTH_SOCK:-}" ]] || return 0
    printf '%s\n' '--ssh'
}

rt_build_cmd() {  # rt_build_cmd <flavor> <image> <context>
    local ba=""
    [[ -n "${CLAUDE_CODE_VERSION:-}" ]] && ba=" --build-arg CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"
    printf 'container build -f %q/Containerfile --target %q -t %q%s %q\n' "$3" "$1" "$2" "$ba" "$3"
}

rt_run() { container run "$@"; }
