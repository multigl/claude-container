#!/usr/bin/env bash
# docker driver. Rootful docker (Linux) or Docker Desktop (macOS). Preserves the
# repo's existing behavior exactly: HOST_UID/HOST_GID remap in the entrypoint,
# plain :ro/:rw mount suffixes, no userns flag.

rt_bin() { printf 'docker\n'; }

# Extra `run` flags contributed by this driver (one token per line). None for
# docker; the launcher already passes -e HOST_UID/HOST_GID for the remap.
rt_run_flags() { :; }

# SSH agent forwarding: bind the host agent socket into the container and point
# the in-container SSH_AUTH_SOCK at it. One token per line (like rt_run_flags).
# Emitted only when the caller has enabled forwarding; empty socket -> nothing.
rt_ssh_flags() {
    [[ -n "${SSH_AUTH_SOCK:-}" ]] || return 0
    printf '%s\n' '-v'
    printf '%s\n' "${SSH_AUTH_SOCK}:/ssh-agent"
    printf '%s\n' '-e'
    printf '%s\n' 'SSH_AUTH_SOCK=/ssh-agent'
}

# Echo the build command (as a string; caller evals or prints).
rt_build_cmd() {  # rt_build_cmd <flavor> <image> <context>
    local ba="" nc=""
    [[ -n "${CLAUDE_CODE_VERSION:-}" ]] && ba=" --build-arg CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"
    [[ -n "${NO_CACHE:-}" ]] && nc=" --no-cache"
    printf 'docker build -f %q/Containerfile --target %q -t %q%s%s %q\n' "$3" "$1" "$2" "$nc" "$ba" "$3"
}

# Run the container: bin + --rm + caller flags + image + args.
rt_run() {  # rt_run <flag-array-via-env RT_FLAGS...> -- handled by launcher
    docker run "$@"
}
