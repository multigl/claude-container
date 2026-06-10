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

# Remap the `claude` user to the host's UID/GID when the wrapper passes
# them in. Lets writes into the $PWD bind-mount land with host ownership
# on Linux engines (macOS Docker translates implicitly, so this is a no-op
# there). Build-time UID is just a placeholder.
if [[ -n "${HOST_UID:-}" && "$HOST_UID" != "$(id -u claude)" ]]; then
    groupmod -g "${HOST_GID:-$HOST_UID}" claude 2>/dev/null || true
    usermod -u "$HOST_UID" -g "${HOST_GID:-$HOST_UID}" claude
fi

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

# Ensure the container's mcpServers block always matches the seed's --
# container's command paths and server definitions are authoritative; host
# only contributes credentials. Without this, an older ~/.claude-vertex.json
# from a prior run could be missing the mcpServers skeleton entirely.
if [[ -f "$SEED/dotclaude.json" ]] && command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq -s '.[0] * {mcpServers: .[1].mcpServers}' \
        "$DOTCLAUDE" "$SEED/dotclaude.json" > "$tmp" \
        && cat "$tmp" > "$DOTCLAUDE"
    rm -f "$tmp"
fi

# Graft MCP credentials from host ~/.claude.json (mounted read-only at
# /home/claude/.host-claude.json by the wrapper) into the container's
# ~/.claude.json. Only the `env` (stdio) and `headers` (http) sub-blocks of
# servers that ALREADY exist in the container config are copied over -- the
# container keeps its own `command` paths (host paths like /opt/homebrew/bin
# don't exist in the image) and any servers the host has that the container
# doesn't are ignored. Lets you keep MCP credentials in one place on the
# host instead of duplicating them in ~/.claude-vertex.env. Re-applied every
# launch so host edits propagate.
HOST_DOTCLAUDE_RO=/home/claude/.host-claude.json
if [[ -f "$HOST_DOTCLAUDE_RO" ]] && command -v jq >/dev/null 2>&1; then
    if jq -e '.mcpServers' "$HOST_DOTCLAUDE_RO" >/dev/null 2>&1; then
        tmp="$(mktemp)"
        # For each server name present in BOTH files, deep-merge host's
        # env/headers into container's entry (host values win on conflict).
        jq -s '
          .[0] as $c | .[1] as $h |
          $c * {
            mcpServers: (
              $c.mcpServers
              | with_entries(
                  .key as $name | .value as $srv
                  | .value = (
                      $srv
                      + (if $h.mcpServers[$name].env
                         then {env: ((($srv.env // {}) + $h.mcpServers[$name].env))}
                         else {} end)
                      + (if $h.mcpServers[$name].headers
                         then {headers: ((($srv.headers // {}) + $h.mcpServers[$name].headers))}
                         else {} end)
                    )
                )
            )
          }
        ' "$DOTCLAUDE" "$HOST_DOTCLAUDE_RO" > "$tmp" \
            && cat "$tmp" > "$DOTCLAUDE"
        rm -f "$tmp"
    fi
fi

chown claude:claude "$DOTCLAUDE" 2>/dev/null || true
chmod 0644 "$DOTCLAUDE" 2>/dev/null || true

exec gosu claude env \
    HOME=/home/claude \
    GOOGLE_APPLICATION_CREDENTIALS="$GOOGLE_APPLICATION_CREDENTIALS" \
    "$@"
