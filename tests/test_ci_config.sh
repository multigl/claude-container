#!/usr/bin/env bash
# Static guards on the publish pipeline: rules a reviewer can't see break until a
# slow or wrong publish lands (cache busting, -latest moved off main, mutable
# third-party action refs, weekly check blind to a partially failed publish).
cd "$(dirname "$0")"
source ./lib.sh
WF="../.github/workflows/ci.yml"
CF="../Containerfile"
BAKE="../docker-bake.hcl"

wf="$(cat "$WF")"
cf="$(cat "$CF")"
bake="$(cat "$BAKE")"

# A per-commit ARG in base becomes env for every later RUN and busts their cache.
assert_not_contains "$cf" "ARG VCS_REF" "Containerfile has no per-commit build arg"
assert_contains "$bake" '"org.opencontainers.image.revision" = REVISION' "revision label set by bake, outside the cache key"
assert_contains "$wf" 'REVISION: ${{ github.sha }}' "CI passes the commit as REVISION"

assert_contains "$bake" 'ref=${CACHE_PREFIX}-${flavor}' "cache ref is per flavor"
assert_contains "$bake" "ignore-error=true" "a failed cache export never fails a publish"
assert_contains "$wf" 'CACHE_PREFIX: ${{ env.IMAGE_REPO }}:cache-${{ matrix.arch }}' "cache is per architecture"
for flavor in personal vertex gateway; do
    target_block="$(sed -n "/^target \"$flavor\"/,/^}/p" "$BAKE")"
    assert_contains "$target_block" "cache_to(\"$flavor\")" "$flavor exports its own cache"
    assert_contains "$(grep -m1 'targets' <<<"$bake")" "\"$flavor\"" "bake default group builds $flavor"
done

publish_job="$(sed -n '/^  publish:/,/^  merge:/p' "$WF")"
assert_contains "$(grep -m1 '^    if:' <<<"$publish_job")" "refs/heads/main" "publish only runs on main"
assert_contains "$publish_job" "runner: ubuntu-24.04-arm" "arm64 builds on a native runner, not QEMU"
assert_not_contains "$publish_job" "setup-qemu-action" "no QEMU in publish"
assert_contains "$publish_job" "push-by-digest=true" "per-arch images push untagged, by digest"
assert_not_contains "$publish_job" ":personal-latest" "publish never tags -latest (merge does, after both arches)"

merge_job="$(sed -n '/^  merge:/,/^  release:/p' "$WF")"
assert_contains "$(grep -m1 '^    if:' <<<"$merge_job")" "refs/heads/main" "merge (moves -latest) only runs on main"
assert_contains "$(grep -m1 '^    needs:' <<<"$merge_job")" "publish" "merge waits for both architectures"
assert_contains "$merge_job" 'digests/digests-amd64/$flavor' "merge combines the amd64 digest"
assert_contains "$merge_job" 'digests/digests-arm64/$flavor' "merge combines the arm64 digest"
assert_contains "$merge_job" '-t "$IMAGE_REPO:$flavor-latest"' "merge tags -latest"
assert_contains "$merge_job" '-t "$IMAGE_REPO:$flavor-$VERSION-$SHA7"' "merge tags the pinned version"

# Seed dirs are baked into images, so only root-level docs may skip the build.
push_trigger="$(sed -n '/^  push:/,/^  schedule:/p' "$WF")"
assert_not_contains "$push_trigger" '"**.md"' "docs-only skip doesn't cover markdown baked from seed dirs"

third_party="$(grep -E '^\s*-?\s*uses:' "$WF" | grep -v 'uses: actions/')"
unpinned="$(grep -Ev 'uses: [^@]+@[0-9a-f]{40}( |$)' <<<"$third_party" || true)"
assert_eq "" "$unpinned" "third-party actions pinned to full commit SHAs"

assert_contains "$wf" "for flavor in personal vertex gateway" "weekly check reads every flavor's label"

assert_contains "$wf" "actions/setup-go" "test and release jobs set up Go"
assert_contains "$wf" "go test ./..." "Go tests run in CI"
assert_contains "$wf" "go vet ./..." "go vet runs in CI"
assert_contains "$wf" 'test -z "$(gofmt -l .)"' "gofmt is enforced"

plan_job="$(sed -n '/^  plan:/,/^  publish:/p' "$WF")"
assert_contains "$plan_job" "GH_REPO: \${{ github.repository }}" "plan job sets GH_REPO (no checkout)"
assert_contains "$plan_job" "release not found" "plan distinguishes release-not-found from other gh errors"

release_job="$(sed -n '/^  release:/,$p' "$WF")"
assert_contains "$(grep -m1 '^    needs:' <<<"$release_job")" "merge" "release waits for the tagged images"
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
assert_contains "$release_job" 'buildinfo.ImageRepo=${IMAGE_REPO}' "release stamps the published image repo"

finish
