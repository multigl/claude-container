#!/usr/bin/env bash
# Per-driver flag assembly. Sourced with CR_SOURCED=1 so no host action runs;
# we assert the flags each driver contributes. `getenforce` is stubbed per case.
cd "$(dirname "$0")"
source ./lib.sh
export CR_SOURCED=1
CRDIR="$(pwd)/../bin"

load_driver() {  # load_driver docker|podman|apple
    unset -f rt_bin rt_run_flags rt_ssh_flags rt_build_cmd rt_run 2>/dev/null
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

# docker: rt_ssh_flags -- socket bind + env when SSH_AUTH_SOCK set; empty otherwise
sflag="$(SSH_AUTH_SOCK=/tmp/agent.sock rt_ssh_flags)"
assert_contains "$sflag" "-v"                          "docker: rt_ssh_flags emits -v"
assert_contains "$sflag" "/tmp/agent.sock:/ssh-agent"  "docker: rt_ssh_flags binds socket"
assert_contains "$sflag" "SSH_AUTH_SOCK=/ssh-agent"    "docker: rt_ssh_flags sets container SSH_AUTH_SOCK"
snone="$(SSH_AUTH_SOCK= rt_ssh_flags)"
assert_eq "" "$snone" "docker: rt_ssh_flags empty when SSH_AUTH_SOCK unset"

# podman driver -------------------------------------------------------------
# rt_run_flags depends on getenforce (SELinux); stub it per case via PATH.
podman_flags_with_selinux() {  # arg: Enforcing|Disabled|absent
    local bin; bin="$(mktemp -d)"
    if [[ "$1" != absent ]]; then
        printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$bin/getenforce"; chmod +x "$bin/getenforce"
    fi
    ( export PATH="$bin:$PATH"; load_driver podman; rt_run_flags )
    rm -rf "$bin"
}
load_driver podman
assert_eq "podman" "$(rt_bin)" "podman rt_bin"
f="$(rt_run_flags)"
assert_contains "$f" "--userns=keep-id:uid=1000,gid=1000" "podman: keep-id userns"
assert_contains "$f" "_CLAUDE_UID_REMAP=skip"             "podman: remap-skip signal"
enf="$(podman_flags_with_selinux Enforcing)"
assert_contains "$enf" "label=disable"  "podman: SELinux enforcing -> label=disable"
noenf="$(podman_flags_with_selinux Disabled)"
assert_not_contains "$noenf" "label=disable" "podman: SELinux disabled -> no label opt"
absent="$(podman_flags_with_selinux absent)"
assert_not_contains "$absent" "label=disable" "podman: no getenforce -> no label opt"
bp="$(rt_build_cmd gateway claude-gateway:latest /ctx)"
assert_contains "$bp" "podman build" "podman: build uses podman"
assert_contains "$bp" "-f /ctx/Containerfile" "podman: build -f Containerfile"

# podman: rt_ssh_flags -- same socket bind + env as docker
psflag="$(SSH_AUTH_SOCK=/tmp/agent.sock rt_ssh_flags)"
assert_contains "$psflag" "/tmp/agent.sock:/ssh-agent" "podman: rt_ssh_flags binds socket"
assert_contains "$psflag" "SSH_AUTH_SOCK=/ssh-agent"   "podman: rt_ssh_flags sets container SSH_AUTH_SOCK"
psnone="$(SSH_AUTH_SOCK= rt_ssh_flags)"
assert_eq "" "$psnone" "podman: rt_ssh_flags empty when SSH_AUTH_SOCK unset"

# apple driver --------------------------------------------------------------
load_driver apple
assert_eq "container" "$(rt_bin)" "apple rt_bin is container"
fa="$(rt_run_flags)"
assert_not_contains "$fa" "userns"            "apple: no userns flag"
assert_not_contains "$fa" "_CLAUDE_UID_REMAP" "apple: no remap-skip (share passes host uids; uses HOST_UID remap like docker)"
ba="$(rt_build_cmd vertex claude-vertex:latest /ctx)"
assert_contains "$ba" "container build" "apple: build uses container"
assert_contains "$ba" "-f /ctx/Containerfile" "apple: build -f Containerfile"
assert_contains "$ba" "--target vertex" "apple: build --target"

# apple: rt_ssh_flags -- --ssh (apple forwards the real socket via the VM), and
# does NOT emit its own SSH_AUTH_SOCK env token (apple manages it in-guest).
asflag="$(SSH_AUTH_SOCK=/tmp/agent.sock rt_ssh_flags)"
assert_contains "$asflag" "--ssh"              "apple: rt_ssh_flags emits --ssh"
assert_not_contains "$asflag" "SSH_AUTH_SOCK"  "apple: rt_ssh_flags sets no SSH_AUTH_SOCK env token"
asnone="$(SSH_AUTH_SOCK= rt_ssh_flags)"
assert_eq "" "$asnone" "apple: rt_ssh_flags empty when SSH_AUTH_SOCK unset"

# build-arg forwarding (CLAUDE_CODE_VERSION) -----------------------------------
bc="$(CLAUDE_CODE_VERSION=9.9.9 bash -c 'source '"$CRDIR"'/container-runtime.sh; source '"$CRDIR"'/runtimes/docker.sh; rt_build_cmd vertex img /ctx')"
assert_contains "$bc" "--build-arg CLAUDE_CODE_VERSION=9.9.9" "docker: build arg forwarded when CLAUDE_CODE_VERSION set"
bc2="$(bash -c 'source '"$CRDIR"'/container-runtime.sh; source '"$CRDIR"'/runtimes/docker.sh; rt_build_cmd vertex img /ctx')"
assert_not_contains "$bc2" "build-arg" "docker: no build arg when CLAUDE_CODE_VERSION unset"

finish
