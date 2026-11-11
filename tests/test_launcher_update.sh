#!/usr/bin/env bash
# `claude-<flavor> update`: pulls the published flavor image through the resolved
# runtime, reports the label version, and warns when an override wins.
# Runtime binaries are recording stubs; nothing is pulled. Expects a dev build,
# whose pinned image is the floating <flavor>-latest tag.
cd "$(dirname "$0")"
source ./lib.sh
setup_host_tools

# run_update PULL_RC CONFIG_TEXT [KEY=VAL...] -> "<rc>\n<stdout+stderr>\n--log--\n<runtime argv log>"
# Linux host with docker, podman and container stubs; CLAUDE_RUNTIME defaults
# to docker. HOST_OS=Darwin makes it an apple-eligible macOS 26 arm64 host.
run_update() {
    local pull_rc="$1" config_text="$2"; shift 2
    local home bin log out rc runtime_binary host_os=Linux kv
    for kv in "$@"; do [[ "$kv" == HOST_OS=* ]] && host_os="${kv#HOST_OS=}"; done
    home="$(mktemp -d)"; bin="$(mktemp -d)"; log="$(mktemp)"
    mkdir -p "$home/.config/claude-container/personal" "$home/.config/claude-container/vertex"
    [[ -n "$config_text" ]] && printf '%s\n' "$config_text" > "$home/.config/claude-container/personal/config.toml"
    for runtime_binary in docker podman container; do
        cat > "$bin/$runtime_binary" <<S
#!/usr/bin/env bash
case "\$1 \$2" in
  "info "*|"info"|"system status") exit 0 ;;
  "image inspect") echo 2.3.1; exit 0 ;;
esac
echo "\${0##*/} \$*" >> "$log"
[[ "\$1 \$2" == "image pull" || "\$1" == pull ]] && exit $pull_rc
exit 0
S
    done
    printf '#!/usr/bin/env bash\n[[ "$1" == "-m" ]] && { echo arm64; exit 0; }\necho %s\n' "$host_os" > "$bin/uname"
    printf '#!/usr/bin/env bash\necho 26.0\n' > "$bin/sw_vers"
    chmod +x "$bin"/*
    out="$(env -i HOME="$home" PATH="$bin:$HOST_TOOLS" CLAUDE_FLAVOR=personal CLAUDE_RUNTIME=docker "$@" \
        "$LAUNCHER" update </dev/null 2>&1)"
    rc=$?
    printf '%s\n%s\n--log--\n%s' "$rc" "$out" "$(cat "$log")"
    rm -rf "$home" "$bin" "$log"
}
rc_of() { head -1 <<<"$1"; }
log_of() { sed -n '/^--log--$/,$p' <<<"$1"; }

out="$(run_update 0 "")"
assert_eq "0" "$(rc_of "$out")" "personal update exits 0"
assert_contains "$(log_of "$out")" "docker pull ghcr.io/multigl/claude-container:personal-latest" "personal pulls personal-latest"
assert_contains "$out" "claude-code 2.3.1" "reports pulled claude-code version"
assert_not_contains "$out" "image override active" "no override note by default"

out="$(run_update 0 "" CLAUDE_FLAVOR=vertex)"
assert_contains "$(log_of "$out")" ":vertex-latest" "vertex pulls vertex-latest"
assert_not_contains "$(log_of "$out")" ":personal-latest" "vertex never pulls personal-latest"

out="$(run_update 0 "" CLAUDE_FLAVOR=gateway)"
assert_contains "$(log_of "$out")" ":gateway-latest" "gateway pulls gateway-latest"

out="$(run_update 0 "" CLAUDE_IMAGE=claude-personal:latest)"
assert_contains "$(log_of "$out")" "docker pull ghcr.io/multigl/claude-container:personal-latest" "override still pulls published image"
assert_contains "$out" "image override active (claude-personal:latest)" "override note names the override"
assert_not_contains "$(log_of "$out")" "docker run" "update never runs a container"

out="$(run_update 0 "" CLAUDE_RUNTIME=podman)"
assert_contains "$(log_of "$out")" "podman pull ghcr.io/multigl/claude-container:personal-latest" "podman pulls via podman pull"

out="$(run_update 0 "" HOST_OS=Darwin CLAUDE_RUNTIME=)"
assert_contains "$(log_of "$out")" "container image pull ghcr.io/multigl/claude-container:personal-latest" "apple host pulls via container image pull"

out="$(run_update 1 "")"
assert_eq "1" "$(rc_of "$out")" "failed pull exits nonzero"
assert_contains "$out" "still private" "failed pull hints at private package"

# update itself exits 1 on any pull failure; passing the runtime's code through
# was the old dispatcher's behavior, not the launcher's.
out="$(run_update 7 "")"
assert_eq "1" "$(rc_of "$out")" "any failed pull exit code makes update exit 1"
assert_not_contains "$out" "claude-code 2.3.1" "failed pull reports no version"

out="$(run_update 0 "" CLAUDE_RUNTIME=apple)"
assert_eq "1" "$(rc_of "$out")" "no runtime exits 1"
assert_contains "$out" "no usable container runtime" "no runtime message"

out="$(run_update 0 $'image = "x:y"\nimgae = "typo"')"
assert_not_contains "$out" "unrecognized key 'image'" "image is a known config.toml key"
assert_contains "$out" "config.toml: unrecognized key 'imgae'" "typo'd key still warned about"

finish
