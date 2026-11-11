#!/usr/bin/env bash
# `claude-<flavor> update`: pulls the published flavor image through the resolved
# runtime's driver, reports the label version, and warns when an override wins.
# Runtime binaries are recording stubs; nothing is pulled.
cd "$(dirname "$0")"
source ./lib.sh
LAUNCHER="$(pwd)/../bin/claude-launcher.sh"

# run_update PULL_RC CONF_TEXT [KEY=VAL...] -> "<rc>\n<stdout+stderr>\n--log--\n<runtime argv log>"
# Linux host, docker stub only; pass CLAUDE_RUNTIME=apple to force "no runtime".
run_update() {
    local pull_rc="$1" conf="$2"; shift 2
    local home bin log out rc; home="$(mktemp -d)"; bin="$(mktemp -d)"; log="$(mktemp)"
    mkdir -p "$home/.config/claude-container/personal" "$home/.config/claude-container/vertex"
    [[ -n "$conf" ]] && printf '%s\n' "$conf" > "$home/.config/claude-container/personal/launcher.conf"
    cat > "$bin/docker" <<S
#!/usr/bin/env bash
case "\$1 \$2" in
  "info "*|"info") exit 0 ;;
  "image inspect") echo 2.3.1; exit 0 ;;
esac
echo "docker \$*" >> "$log"
[[ "\$1" == pull ]] && exit $pull_rc
exit 0
S
    printf '#!/usr/bin/env bash\n[[ "$1" == "-m" ]] && { echo x86_64; exit 0; }\necho Linux\n' > "$bin/uname"
    chmod +x "$bin/docker" "$bin/uname"
    out="$(env -i HOME="$home" PATH="$bin:/usr/bin:/bin" CLAUDE_FLAVOR=personal CLAUDE_RUNTIME=docker "$@" \
        bash "$LAUNCHER" update </dev/null 2>&1)"
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

out="$(run_update 1 "")"
assert_eq "1" "$(rc_of "$out")" "failed pull exits nonzero"
assert_contains "$out" "still private" "failed pull hints at private package"

out="$(run_update 0 "" CLAUDE_RUNTIME=apple)"
assert_eq "1" "$(rc_of "$out")" "no runtime exits 1"
assert_contains "$out" "no container runtime available" "no runtime message"

out="$(run_update 0 $'image = x:y\nimgae = typo')"
assert_not_contains "$out" "unrecognized key 'image'" "image is a known launcher.conf key"
assert_contains "$out" "unrecognized key 'imgae'" "typo'd key still warned about"

finish
