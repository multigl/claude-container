# tests/lib.sh -- minimal assert helpers for the plain-bash suites.
# Source this, call assert_* as needed, end the script with `finish`
# (its exit code is non-zero iff any assertion failed).
_tests_run=0
_tests_failed=0

assert_eq() {  # assert_eq EXPECTED ACTUAL [MSG]
    local expected="$1" actual="$2" msg="${3:-assert_eq}"
    _tests_run=$((_tests_run + 1))
    if [[ "$expected" == "$actual" ]]; then
        printf '  ok: %s\n' "$msg"
    else
        _tests_failed=$((_tests_failed + 1))
        printf '  FAIL: %s\n    expected: %q\n    actual:   %q\n' "$msg" "$expected" "$actual"
    fi
}

assert_contains() {  # assert_contains HAYSTACK NEEDLE [MSG]
    local haystack="$1" needle="$2" msg="${3:-assert_contains}"
    _tests_run=$((_tests_run + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  ok: %s\n' "$msg"
    else
        _tests_failed=$((_tests_failed + 1))
        printf '  FAIL: %s\n    needle:   %q\n    haystack: %q\n' "$msg" "$needle" "$haystack"
    fi
}

assert_not_contains() {  # assert_not_contains HAYSTACK NEEDLE [MSG]
    local haystack="$1" needle="$2" msg="${3:-assert_not_contains}"
    _tests_run=$((_tests_run + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '  ok: %s\n' "$msg"
    else
        _tests_failed=$((_tests_failed + 1))
        printf '  FAIL: %s\n    unwanted: %q\n    haystack: %q\n' "$msg" "$needle" "$haystack"
    fi
}

finish() {
    printf '%s: %d run, %d failed\n' "${0##*/}" "$_tests_run" "$_tests_failed"
    [[ "$_tests_failed" -eq 0 ]]
}

# Launcher under test: the Go binary, or LAUNCHER_BIN (bin/claude-launcher.sh
# for the bash launcher). Made absolute because suites cd and symlink to it; a
# relative LAUNCHER_BIN is taken from the repo root, since suites cd first.
_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="${LAUNCHER_BIN:-$_repo_root/bin/claude-container}"
[[ "$LAUNCHER" == /* ]] || LAUNCHER="$_repo_root/$LAUNCHER"
launch() { "$LAUNCHER" "$@"; }

# setup_host_tools sets HOST_TOOLS to a temp dir of symlinks to ordinary host
# tools, for a stub-only PATH="$fakes:$HOST_TOOLS". It deliberately leaves out
# docker, podman, container, gh and getenforce, so a launcher under test can
# only reach the suite's fakes. Call once per suite, before any launch.
setup_host_tools() {
    local tool source
    HOST_TOOLS="$(mktemp -d)"
    trap 'rm -rf "$HOST_TOOLS"' EXIT
    for tool in awk basename bash cat chmod cksum cp cut date dirname env find git grep \
                head id jq ln ls mkdir mktemp mv readlink realpath rm rmdir rsync sed sh sort \
                ssh-keygen stat sw_vers tail touch tr uname wc; do
        source="$(command -v "$tool" 2>/dev/null)" || continue
        [[ "$source" == /* ]] && ln -s "$source" "$HOST_TOOLS/$tool"
    done
}
