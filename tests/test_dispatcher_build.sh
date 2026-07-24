#!/usr/bin/env bash
# CLI `build` subcommand of bin/container-runtime.sh: a `--no-cache` flag must
# thread NO_CACHE=1 into the resolved driver's rt_build_cmd, so `just rebuild`
# can route through the dispatcher instead of hardcoding `docker build`
# (see rebuild-recipe-wrong-runtime-bug memory). docker/podman/container are
# stubbed as no-op binaries that log their argv, so no real image build runs.
cd "$(dirname "$0")"
source ./lib.sh
DISPATCH="$(pwd)/../bin/container-runtime.sh"

build_with() {  # build_with EXTRA_ARGS...
    local bin log; bin="$(mktemp -d)"; log="$(mktemp)"
    ln -s "$(command -v bash)"    "$bin/bash"
    ln -s "$(command -v cut)"     "$bin/cut"
    ln -s "$(command -v dirname)" "$bin/dirname"
    for rt in docker podman container; do
        cat > "$bin/$rt" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "info "*|"system status"|"info") exit 0 ;;
esac
echo "$0 $*" >> "$RTLOG"
S
        chmod +x "$bin/$rt"
    done
    cat > "$bin/uname" <<'S'
#!/usr/bin/env bash
[[ "$1" == "-m" ]] && { echo arm64; exit 0; }
echo Darwin
S
    cat > "$bin/sw_vers" <<'S'
#!/usr/bin/env bash
echo "26.0"
S
    chmod +x "$bin/uname" "$bin/sw_vers"
    env -i HOME=/tmp PATH="$bin" RTLOG="$log" \
        bash "$DISPATCH" build --flavor vertex --image img --context /ctx "$@" >/dev/null 2>&1
    cat "$log"
    rm -rf "$bin" "$log"
}

out="$(build_with)"
assert_contains "$out" "container build"    "dispatcher build: resolves apple -> container build"
assert_not_contains "$out" "--no-cache"     "dispatcher build: no --no-cache by default"

out_nc="$(build_with --no-cache)"
assert_contains "$out_nc" "--no-cache"      "dispatcher build --no-cache: forwarded to driver"

finish
