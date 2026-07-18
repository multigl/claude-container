#!/usr/bin/env bash
# Deep-merge a Claude Code settings override onto a base settings.json.
# Usage: merge-settings.sh BASE OVERRIDE   -> merged JSON on stdout
# jq's `*` deep-merges objects; arrays and scalars are REPLACED by the override.
set -euo pipefail

base="${1:?usage: merge-settings.sh BASE OVERRIDE}"
override="${2:?usage: merge-settings.sh BASE OVERRIDE}"

jq -s '.[0] * .[1]' "$base" "$override"
