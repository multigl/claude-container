#!/usr/bin/env bash
# Tests for bin/rebuild-memory-index.sh -- MEMORY.md is regenerated from the
# *.md fact files' frontmatter (name/description). Pure; no Docker.
cd "$(dirname "$0")"
source ./lib.sh
SCRIPT="$(pwd)/../bin/rebuild-memory-index.sh"

dir="$(mktemp -d)"

cat > "$dir/foo-bar.md" <<'EOF'
---
name: foo-bar
description: does the foo thing
metadata:
  type: project
---
body text
EOF

cat > "$dir/no-desc.md" <<'EOF'
---
name: no-desc
---
body text
EOF

cat > "$dir/url-desc.md" <<'EOF'
---
name: url-desc
description: see https://example.com/x for details
---
body text
EOF

cat > "$dir/quoted.md" <<'EOF'
---
name: quoted
description: "DONE: shipped, with colon"
---
body text
EOF

# A stale index that MUST be overwritten (it is derived data).
echo "STALE CONTENT" > "$dir/MEMORY.md"

bash "$SCRIPT" "$dir"
idx="$(cat "$dir/MEMORY.md")"

assert_contains "$idx" "# Memory index" "has header"
assert_contains "$idx" "- [foo bar](foo-bar.md) — does the foo thing" "entry with description, name dashes->spaces"
assert_contains "$idx" "- [no desc](no-desc.md)" "entry without description"
assert_contains "$idx" "- [url desc](url-desc.md) — see https://example.com/x for details" "description with colon preserved"
assert_contains "$idx" "- [quoted](quoted.md) — DONE: shipped, with colon" "quoted description: quotes stripped, colon preserved"
assert_eq "" "$(grep STALE "$dir/MEMORY.md" || true)" "stale index fully overwritten"

rm -rf "$dir"
finish
