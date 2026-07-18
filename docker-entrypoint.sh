#!/usr/bin/env bash
# Seed /home/claude/.claude (bind-mounted from the host state dir, e.g.
# ~/.local/state/vida-claude-container/<flavor>/claude) from
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

# Vertex flavor only: point ADC at the bind-mounted gcloud config dir.
# Exported here (not in the Dockerfile ENV) so Hadolint doesn't flag the
# *_CREDENTIALS name pattern as a baked-in secret. The gateway flavor leaves
# CLAUDE_CODE_USE_VERTEX unset and skips all gcloud/ADC handling -- it auths
# via the apiKeyHelper bind-mounted at /opt/claude/api-key-helper instead.
if [[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-${GCLOUD_DIR}/application_default_credentials.json}"
fi
export HOME=/home/claude

# Remap the `claude` user to the host's UID/GID when the wrapper passes
# them in. Lets writes into the $PWD bind-mount land with host ownership
# on Linux engines (macOS Docker translates implicitly, so this is a no-op
# there). Build-time UID is just a placeholder.
if [[ -n "${HOST_UID:-}" && "$HOST_UID" != "$(id -u claude)" ]]; then
    groupmod -g "${HOST_GID:-$HOST_UID}" claude 2>/dev/null || true
    usermod -u "$HOST_UID" -g "${HOST_GID:-$HOST_UID}" claude
fi

mkdir -p "$DEST"
[[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]] && mkdir -p "$GCLOUD_DIR"
# Only chown the writable bind-mounts we actually need to own. A blanket
# `chown -R /home/claude` would traverse host-mounted ~/.gitconfig and
# ~/.ssh (mounted :ro) and fail with EROFS, killing the container under
# set -e.
chown claude:claude /home/claude
chown -R claude:claude "$DEST"
[[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]] && chown -R claude:claude "$GCLOUD_DIR"
# Gateway: the Okta token-cache volume arrives root-owned; hand it to claude so
# the non-root apiKeyHelper can write its cache. Dir exists only when mounted.
[[ -d /home/claude/.local/share/litellm ]] && chown -R claude:claude /home/claude/.local/share/litellm

# Normally seed only fills in missing files (--ignore-existing / cp -n) so user
# edits survive. CLAUDE_RESEED=1 (set by `claude-<flavor> reseed`) instead
# OVERWRITES the seeded files with the image's current version -- used to push
# updated settings/plugins to engineers who already have a config dir. Either
# way dotclaude.json is excluded (handled separately below).
if [[ -d "$SEED" ]]; then
    if [[ -n "${CLAUDE_RESEED:-}" ]]; then
        rsync_mode=()      # overwrite existing seeded files
        cp_mode=(-r)
    else
        rsync_mode=(--ignore-existing)
        cp_mode=(-rn)
    fi
    if command -v rsync >/dev/null 2>&1; then
        gosu claude rsync -a "${rsync_mode[@]}" \
            --exclude=dotclaude.json \
            "$SEED"/ "$DEST"/
    else
        gosu claude cp "${cp_mode[@]}" "$SEED"/. "$DEST"/
    fi
fi

# Merge the user's settings override (mounted ro at
# ~/.claude/settings.override.json by the launcher when present) onto the seeded
# settings.json, in place. Re-applied every launch so the override's keys win.
# The base settings.json keeps its normal seeded lifecycle (preserved across
# launches via --ignore-existing; refreshed only by `reseed`), so writes made by
# /setup-vertex survive. jq `*` deep-merges objects; arrays/scalars are replaced
# by the override. Removing a key from the override does not auto-revert the base
# until the next reseed (in-place merge) -- documented behavior.
SETTINGS="$DEST/settings.json"
OVERRIDE="$DEST/settings.override.json"
if [[ -f "$OVERRIDE" && -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    if gosu claude /opt/claude/merge-settings.sh "$SETTINGS" "$OVERRIDE" > "$tmp"; then
        cat "$tmp" > "$SETTINGS"
        chown claude:claude "$SETTINGS" 2>/dev/null || true
    fi
    rm -f "$tmp"
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
# only contributes credentials. Without this, an older host claude.json
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
# host instead of duplicating them in the config `env` file. Re-applied every
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

# --- git identity + gh credential helper -------------------------------------
# Write a container-owned ~/.gitconfig that INCLUDES the launcher-seeded, ro
# identity file (mounted at ~/.gitconfig-identity). git ignores the include if the
# path is absent, so this is safe when no identity was seeded. Signing intent
# (gpg.format/signingkey/commit.gpgsign) lives in the identity file and is off
# unless the engineer enables it there.
GITCONFIG=/home/claude/.gitconfig
cat > "$GITCONFIG" <<'EOF'
[include]
    path = /home/claude/.gitconfig-identity
[safe]
    directory = *
[init]
    defaultBranch = main
EOF
chown claude:claude "$GITCONFIG"

# Register gh as the HTTPS credential helper when a token was injected (GH_TOKEN
# is passed in by the wrapper). HTTPS-scoped only -- SSH remotes are unaffected.
if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    gosu claude env HOME=/home/claude GH_TOKEN="$GH_TOKEN" gh auth setup-git 2>/dev/null || true
fi
# -----------------------------------------------------------------------------

exec_env=( HOME=/home/claude )
if [[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]]; then
    exec_env+=( "GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS" )
fi
exec gosu claude env "${exec_env[@]}" "$@"
