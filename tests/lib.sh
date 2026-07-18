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

finish() {
    printf '%s: %d run, %d failed\n' "${0##*/}" "$_tests_run" "$_tests_failed"
    [[ "$_tests_failed" -eq 0 ]]
}
