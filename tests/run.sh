#!/usr/bin/env bash
# Run every tests/test_*.sh, aggregate pass/fail into a single exit code.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$here"/test_*.sh; do
    echo "== ${t##*/} =="
    bash "$t" || rc=1
done
exit "$rc"
