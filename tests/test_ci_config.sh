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

assert_contains "$wf" "actions/setup-go" "test and release jobs set up Go"
assert_contains "$wf" "go test ./..." "Go tests run in CI"
assert_contains "$wf" "go vet ./..." "go vet runs in CI"
assert_contains "$wf" 'test -z "$(gofmt -l .)"' "gofmt is enforced"

release_job="$(sed -n '/^  release:/,$p' "$WF")"
assert_contains "$(grep -m1 '^    needs:' <<<"$release_job")" "publish" "release waits for publish"
assert_contains "$release_job" "contents: write" "release job can create releases"
assert_contains "$wf" "gh release view" "release idempotency and weekly skip check"
assert_contains "$wf" 'gh release view "v$version-' "weekly skip requires the matching release"
for target in darwin/amd64 darwin/arm64 linux/amd64 linux/arm64; do
    assert_contains "$release_job" "$target" "release builds $target"
done
assert_contains "$release_job" 'GOOS="${target%/*}" GOARCH="${target#*/}"' "release sets GOOS/GOARCH per target"
assert_contains "$release_job" 'dist/claude-container_${target%/*}_${target#*/}' "release names assets claude-container_<os>_<arch>"
assert_contains "$release_job" "CGO_ENABLED=0" "release builds are static"
assert_contains "$release_job" "buildinfo.Version=v\$" "release stamps the tag as Version"

finish
