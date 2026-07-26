#!/usr/bin/env bash
# podman driver (rootless Linux). Rootless podman maps the host user to container
# root, so bind mounts arrive root-owned and the entrypoint's usermod/chown remap
# is wrong. Fix: keep-id maps the host user onto the image's claude user (uid
# 1000), `--user 0:0` keeps the entrypoint root inside that userns (keep-id would
# otherwise default the container user to 1000 and break gosu -- see rt_run_flags),
# and we signal the entrypoint to SKIP its remap. On SELinux-enforcing
# hosts, disable label confinement for this container (simpler + safer than
# per-mount :z relabeling, which would relabel shared host dirs like ~/.claude).

rt_bin() { printf 'podman\n'; }

# SELinux enforcing? (getenforce present and not "Disabled").
_rt_selinux_on() {
    command -v getenforce >/dev/null 2>&1 || return 1
    local s; s="$(getenforce 2>/dev/null)"
    [[ -n "$s" && "$s" != "Disabled" ]]
}

rt_run_flags() {
    printf '%s\n' '--userns=keep-id:uid=1000,gid=1000'
    # keep-id also sets the container's DEFAULT USER to the mapped uid (1000), so
    # without this the entrypoint starts as claude, not root, and its first
    # `gosu claude ...` dies with `failed switching to "claude": operation not
    # permitted` (setgroups/setgid need CAP_SETGID). Force root inside the userns:
    # root is a subuid here, harmless on the host, and the entrypoint still drops
    # to claude (uid 1000 = the host user, via keep-id) for the session, so mount
    # writes land host-owned.
    printf '%s\n' '--user'
    printf '%s\n' '0:0'
    printf '%s\n' '-e'
    printf '%s\n' '_CLAUDE_UID_REMAP=skip'
    if _rt_selinux_on; then
        printf '%s\n' '--security-opt'
        printf '%s\n' 'label=disable'
    fi
}

# SSH agent forwarding: identical to docker. keep-id maps the host user onto
# claude (uid 1000), so the bind-mounted host socket is claude-accessible.
rt_ssh_flags() {
    [[ -n "${SSH_AUTH_SOCK:-}" ]] || return 0
    printf '%s\n' '-v'
    printf '%s\n' "${SSH_AUTH_SOCK}:/ssh-agent"
    printf '%s\n' '-e'
    printf '%s\n' 'SSH_AUTH_SOCK=/ssh-agent'
}

rt_build_cmd() {  # rt_build_cmd <flavor> <image> <context>
    local ba="" nc=""
    [[ -n "${CLAUDE_CODE_VERSION:-}" ]] && ba=" --build-arg CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"
    [[ -n "${NO_CACHE:-}" ]] && nc=" --no-cache"
    printf 'podman build -f %q/Containerfile --target %q -t %q%s%s %q\n' "$3" "$1" "$2" "$nc" "$ba" "$3"
}

rt_run() { podman run "$@"; }
