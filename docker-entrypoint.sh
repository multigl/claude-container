#!/usr/bin/env bash
# Seed /home/claude/.claude (bind-mounted from host ~/.claude-vertex) from
# the image's /opt/claude-seed payload on first launch. Idempotent: existing
# files are preserved so user edits and prior plugin installs survive.
#
# Runs as root briefly to chown the bind-mounted volumes (named docker volume
# and host dir both arrive root-owned), then drops to the `claude` user via
# gosu. Claude Code refuses bypassPermissions mode when running as root.
set -euo pipefail

SEED=/opt/claude-seed
DEST=/home/claude/.claude
DOTCLAUDE=/home/claude/.claude.json
GCLOUD_DIR=/home/claude/.config/gcloud

# Path to the ADC file inside the bind-mounted gcloud config dir.
# Exported here (not in the Dockerfile ENV) so Hadolint doesn't flag the
# *_CREDENTIALS name pattern as a baked-in secret.
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-${GCLOUD_DIR}/application_default_credentials.json}"
export HOME=/home/claude

mkdir -p "$DEST" "$GCLOUD_DIR"
# Only chown the writable bind-mounts we actually need to own. A blanket
# `chown -R /home/claude` would traverse host-mounted ~/.gitconfig and
# ~/.ssh (mounted :ro) and fail with EROFS, killing the container under
# set -e.
chown claude:claude /home/claude
chown -R claude:claude "$DEST" "$GCLOUD_DIR"

if [[ -d "$SEED" ]]; then
    if command -v rsync >/dev/null 2>&1; then
        gosu claude rsync -a --ignore-existing \
            --exclude=dotclaude.json \
            "$SEED"/ "$DEST"/
    else
        gosu claude cp -rn "$SEED"/. "$DEST"/
    fi
fi

# Pre-fill ~/.claude.json (trust + onboarding flags) if empty/missing.
# Bind-mounted as a file from host so value persists across runs. Must
# write in-place (cat >) -- `install`/`cp` would try to rename-replace
# the mount point and fail with EBUSY.
if [[ -f "$SEED/dotclaude.json" ]] && [[ ! -s "$DOTCLAUDE" ]]; then
    cat "$SEED/dotclaude.json" > "$DOTCLAUDE"
fi
chown claude:claude "$DOTCLAUDE" 2>/dev/null || true
chmod 0644 "$DOTCLAUDE" 2>/dev/null || true

exec gosu claude env \
    HOME=/home/claude \
    GOOGLE_APPLICATION_CREDENTIALS="$GOOGLE_APPLICATION_CREDENTIALS" \
    "$@"
