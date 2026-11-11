#!/usr/bin/env bash
# Static guards on the publish pipeline: rules a reviewer can't see break until a
# slow or wrong publish lands (cache busting, -latest moved off main, mutable
# third-party action refs, weekly check blind to a partially failed publish).
cd "$(dirname "$0")"
source ./lib.sh
WF="../.github/workflows/ci.yml"
CF="../Containerfile"

wf="$(cat "$WF")"
cf="$(cat "$CF")"

# A per-commit ARG in base becomes env for every later RUN and busts their cache.
assert_not_contains "$cf" "ARG VCS_REF" "Containerfile has no per-commit build arg"
assert_contains "$wf" "org.opencontainers.image.revision=" "revision label set by CI, outside the cache key"

for flavor in personal vertex gateway; do
    assert_contains "$wf" "cache-to: type=gha,scope=cc-$flavor,mode=max" "$flavor exports its own cache scope"
done

publish_if="$(sed -n '/^  publish:/,/^  [a-z]/p' "$WF" | grep -m1 '^    if:')"
assert_contains "$publish_if" "refs/heads/main" "publish (moves -latest) only runs on main"

third_party="$(grep -E '^\s*-?\s*uses:' "$WF" | grep -v 'uses: actions/')"
unpinned="$(grep -Ev 'uses: [^@]+@[0-9a-f]{40}( |$)' <<<"$third_party" || true)"
assert_eq "" "$unpinned" "third-party actions pinned to full commit SHAs"

assert_contains "$wf" "for flavor in personal vertex gateway" "weekly check reads every flavor's label"

finish
