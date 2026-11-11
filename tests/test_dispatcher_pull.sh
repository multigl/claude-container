#!/usr/bin/env bash
# CLI `pull` subcommand of bin/container-runtime.sh: routes to the resolved
# driver's rt_pull. Runtime binaries are stubs that log argv, so nothing is pulled.
cd "$(dirname "$0")"
source ./lib.sh
DISPATCH="$(pwd)/../bin/container-runtime.sh"
REF="ghcr.io/multigl/claude-container:personal-latest"

# pull_with RUNTIMES PULL_RC [KEY=VAL...] -> prints "<rc>\n<stderr>\n--log--\n<log>"
pull_with() {
    local runtimes="$1" pull_rc="$2"; shift 2
    local bin log err rc rt; bin="$(mktemp -d)"; log="$(mktemp)"; err="$(mktemp)"
    ln -s "$(command -v bash)"    "$bin/bash"
    ln -s "$(command -v cut)"     "$bin/cut"
    ln -s "$(command -v dirname)" "$bin/dirname"
    for rt in $runtimes; do
        cat > "$bin/$rt" <<S
#!/usr/bin/env bash
case "\$1 \$2" in
  "info "*|"system status"|"info") exit 0 ;;
esac
echo "\${0##*/} \$*" >> "\$RTLOG"
exit $pull_rc
S
        chmod +x "$bin/$rt"
    done
    printf '#!/usr/bin/env bash\n[[ "$1" == "-m" ]] && { echo arm64; exit 0; }\necho Darwin\n' > "$bin/uname"
    printf '#!/usr/bin/env bash\necho "26.0"\n' > "$bin/sw_vers"
    chmod +x "$bin/uname" "$bin/sw_vers"
    env -i HOME=/tmp PATH="$bin" RTLOG="$log" "$@" \
        bash "$DISPATCH" pull --image "$REF" >/dev/null 2>"$err"
    rc=$?
    printf '%s\n%s\n--log--\n%s' "$rc" "$(cat "$err")" "$(cat "$log")"
    rm -rf "$bin" "$log" "$err"
}

out="$(pull_with "docker podman container" 0)"
assert_contains "$out" "container image pull $REF" "apple host pulls via container image pull"

out="$(pull_with "docker podman container" 0 CLAUDE_RUNTIME=docker)"
assert_contains "$out" "docker pull $REF" "docker override pulls via docker pull"

out="$(pull_with "docker podman container" 0 CLAUDE_RUNTIME=podman)"
assert_contains "$out" "podman pull $REF" "podman override pulls via podman pull"

out="$(pull_with "docker" 7 CLAUDE_RUNTIME=docker)"
assert_eq "7" "$(head -1 <<<"$out")" "failed pull propagates exit code"

out="$(pull_with "" 0)"
assert_eq "1" "$(head -1 <<<"$out")" "no runtime exits 1"
assert_contains "$out" "no runtime" "no runtime message"

finish
