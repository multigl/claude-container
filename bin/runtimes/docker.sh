#!/usr/bin/env bash
# docker driver. Rootful docker (Linux) or Docker Desktop (macOS). Preserves the
# repo's existing behavior exactly: HOST_UID/HOST_GID remap in the entrypoint,
# plain :ro/:rw mount suffixes, no userns flag.

rt_bin() { printf 'docker\n'; }

# Extra `run` flags contributed by this driver (one token per line). None for
# docker; the launcher already passes -e HOST_UID/HOST_GID for the remap.
rt_run_flags() { :; }

# Echo the build command (as a string; caller evals or prints).
rt_build_cmd() {  # rt_build_cmd <flavor> <image> <context>
    printf 'docker build -f %s/Containerfile --target %s -t %s %s\n' "$3" "$1" "$2" "$3"
}

# Run the container: bin + --rm + caller flags + image + args.
rt_run() {  # rt_run <flag-array-via-env RT_FLAGS...> -- handled by launcher
    docker run "$@"
}
