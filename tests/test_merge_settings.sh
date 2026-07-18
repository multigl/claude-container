#!/usr/bin/env bash
# Tests for bin/merge-settings.sh
cd "$(dirname "$0")"
source ./lib.sh
MERGE=../bin/merge-settings.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# scalar override wins; untouched base keys survive
printf '%s' '{"model":"base-model","theme":"dark"}' > "$tmp/base.json"
printf '%s' '{"model":"override-model"}'            > "$tmp/ovr.json"
out="$(bash "$MERGE" "$tmp/base.json" "$tmp/ovr.json")"
assert_eq "override-model" "$(jq -r .model  <<<"$out")" "scalar override wins"
assert_eq "dark"           "$(jq -r .theme  <<<"$out")" "untouched base key survives"

# nested object deep-merges
printf '%s' '{"env":{"A":"1","B":"2"}}' > "$tmp/base.json"
printf '%s' '{"env":{"B":"9","C":"3"}}' > "$tmp/ovr.json"
out="$(bash "$MERGE" "$tmp/base.json" "$tmp/ovr.json")"
assert_eq "1" "$(jq -r .env.A <<<"$out")" "nested untouched key survives"
assert_eq "9" "$(jq -r .env.B <<<"$out")" "nested override wins"
assert_eq "3" "$(jq -r .env.C <<<"$out")" "nested new key added"

# arrays are REPLACED wholesale, not concatenated (documented caveat)
printf '%s' '{"permissions":{"allow":["X","Y"]}}' > "$tmp/base.json"
printf '%s' '{"permissions":{"allow":["Z"]}}'     > "$tmp/ovr.json"
out="$(bash "$MERGE" "$tmp/base.json" "$tmp/ovr.json")"
assert_eq '["Z"]' "$(jq -c .permissions.allow <<<"$out")" "array replaced wholesale (caveat)"

# empty override is a no-op
printf '%s' '{"model":"base-model"}' > "$tmp/base.json"
printf '%s' '{}'                     > "$tmp/ovr.json"
out="$(bash "$MERGE" "$tmp/base.json" "$tmp/ovr.json")"
assert_eq "base-model" "$(jq -r .model <<<"$out")" "empty override no-op"

finish
