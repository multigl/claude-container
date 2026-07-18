#!/usr/bin/env bash
# Regenerate MEMORY.md (the recall index) from the frontmatter of the *.md fact
# files in a memory directory. MEMORY.md is DERIVED data -- edit the fact files,
# not the index. Idempotent; safe to run every launch. One bullet per fact:
#   - [<name with dashes as spaces>](<file>) — <description>
# Usage: rebuild-memory-index.sh DIR
set -euo pipefail

dir="${1:?usage: rebuild-memory-index.sh DIR}"
[[ -d "$dir" ]] || { echo "rebuild-memory-index: not a directory: $dir" >&2; exit 1; }

# Extract one frontmatter field from the first `---`...`---` block. Splitting on
# the whole value (sub on $0) keeps colons in the value intact (e.g. URLs).
_field() {  # _field FILE KEY
    awk -v key="$2" '
        /^---[[:space:]]*$/ { n++; next }
        n==1 && $0 ~ "^"key": " { sub("^"key": *", ""); print; exit }
    ' "$1"
}

# YAML values containing special chars (e.g. a colon) are legally quoted. Strip
# one layer of matching leading/trailing single or double quotes.
_strip_quotes() {  # _strip_quotes VALUE
    local s="$1"
    case "$s" in
        '"'*'"') s="${s#\"}"; s="${s%\"}" ;;
        "'"*"'") s="${s#\'}"; s="${s%\'}" ;;
    esac
    printf '%s' "$s"
}

tmp="$(mktemp "$dir/.MEMORY.md.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '# Memory index\n\n' > "$tmp"

shopt -s nullglob
for f in "$dir"/*.md; do
    base="$(basename "$f")"
    [[ "$base" == "MEMORY.md" ]] && continue
    name="$(_strip_quotes "$(_field "$f" name)")"
    desc="$(_strip_quotes "$(_field "$f" description)")"
    [[ -z "$name" ]] && name="${base%.md}"
    title="${name//-/ }"
    if [[ -n "$desc" ]]; then
        printf -- '- [%s](%s) — %s\n' "$title" "$base" "$desc" >> "$tmp"
    else
        printf -- '- [%s](%s)\n' "$title" "$base" >> "$tmp"
    fi
done

mv "$tmp" "$dir/MEMORY.md"
chmod 0644 "$dir/MEMORY.md"
