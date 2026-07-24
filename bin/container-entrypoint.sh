#!/usr/bin/env bash
# Seed /home/claude/.claude (bind-mounted from the host state dir, e.g.
# ~/.local/state/vida-claude-container/<flavor>/claude) from
# the image's /opt/claude-seed payload on first launch. Idempotent: existing
# files are preserved so user edits and prior plugin installs survive.
#
# Runs as root briefly to chown the bind-mounted volumes (named docker volume
# and host dir both arrive root-owned), then drops to the `claude` user via
# gosu. Claude Code refuses bypassPermissions mode when running as root.

# Remap-gate predicate (pure; unit-tested by tests/test_entrypoint_remap.sh).
# Remap the claude user to the host UID/GID unless the runtime already handled
# ownership (podman rootless keep-id sets _CLAUDE_UID_REMAP=skip) or there's no
# host UID / it already matches.
cr_should_remap() {  # cr_should_remap <current_claude_uid>
    [[ "${_CLAUDE_UID_REMAP:-}" == skip ]] && return 1
    [[ -n "${HOST_UID:-}" ]] || return 1
    [[ "${HOST_UID}" != "$1" ]]
}

# Minimal stderr logger shared by the extracted boot functions below.
cr_warn() { printf 'container-entrypoint: %s\n' "$*" >&2; }

# Remap the claude user to the host UID/GID, non-fatally. Wraps the decision
# (cr_should_remap) and the action so a usermod failure (e.g. HOST_UID already
# baked into the image) degrades to a warning instead of aborting the entrypoint
# under set -e. On skip the session simply runs as uid 1000.
# Unit-tested by tests/test_entrypoint_remap.sh (override usermod/groupmod).
cr_remap_user() {  # cr_remap_user <current_claude_uid>
    cr_should_remap "$1" || return 0
    groupmod -g "${HOST_GID:-$HOST_UID}" claude 2>/dev/null || true
    usermod -u "$HOST_UID" -g "${HOST_GID:-$HOST_UID}" claude 2>/dev/null \
        || cr_warn "remap to uid ${HOST_UID} failed (already in use?); continuing as uid 1000"
    return 0
}

# Deep-merge the host's env/headers sub-blocks (MCP credentials) into the
# container's mcpServers entries that already exist; host wins on conflict;
# host-only servers are ignored; command paths stay the container's. Pure jq
# transform, emits merged JSON on stdout. Unit-tested by test_entrypoint_lib.sh.
cr_graft_mcp_creds() {  # cr_graft_mcp_creds <container_json> <host_json>
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
    ' "$1" "$2"
}

# Force the seed's mcpServers skeleton into the container config (deep-merge, seed
# wins) so an older host claude.json can't leave the block missing. Pure jq,
# emits merged JSON on stdout. Unit-tested by tests/test_entrypoint_lib.sh.
cr_sync_mcp_servers() {  # cr_sync_mcp_servers <container_json> <seed_json>
    jq -s '.[0] * {mcpServers: .[1].mcpServers}' "$1" "$2"
}

# When sourced as a library (tests), define functions then stop before any
# container-only boot logic. Harmless when executed normally (var is unset).
[[ "${CLAUDE_ENTRYPOINT_LIB:-}" == 1 ]] && return 0

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
cr_remap_user "$(id -u claude)"

mkdir -p "$DEST"
[[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]] && mkdir -p "$GCLOUD_DIR"
# Only chown the writable bind-mounts we actually need to own. A blanket
# `chown -R /home/claude` would traverse ro mounts and fail with EROFS, killing
# the container under set -e (the ro inputs now arrive under /opt/claude-stage,
# outside /home/claude, but keep this scoped regardless). Best-effort: on
# file-share runtimes (Apple `container`, Docker Desktop) chowning a bind mount
# returns EPERM because the VM file share already translates ownership -- tolerate
# it (docker/podman rootful still chown successfully).
chown claude:claude /home/claude 2>/dev/null || true
chown -R claude:claude "$DEST" 2>/dev/null || true
[[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]] && { chown -R claude:claude "$GCLOUD_DIR" 2>/dev/null || true; }

# Ensure ~/.ssh exists + claude-owned, for a forwarded agent socket and the baked
# known_hosts. Best-effort chown (file-share runtimes reject chown; see above).
mkdir -p /home/claude/.ssh && chmod 700 /home/claude/.ssh
chown claude:claude /home/claude/.ssh 2>/dev/null || true

# Apple `container --ssh` creates the in-guest forwarded agent socket root:root
# 0600 (confirmed by host testing) -- AF_UNIX connect() requires WRITE permission
# on the socket file, so the non-root claude user can't reach it as-is. Re-owning
# it to claude (the only user that ever runs in this container) is more scoped
# than world-writable perms. Best-effort + root-only, before the drop below.
# Harmless no-op for docker/podman, where the bind-mounted host socket is already
# claude-reachable after the uid remap.
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
    chown claude:claude "$SSH_AUTH_SOCK" 2>/dev/null || true
fi

# Persist ~/.claude.json inside the ~/.claude directory bind mount instead of via
# a fragile single-file mount (those rot on Docker Desktop macOS across host
# sleep/wake). The launcher stores it at $DEST/claude.json (inside the mounted
# state dir); symlink ~/.claude.json to it. In-place writes -- the prefill/graft
# below and Claude Code's own updates -- follow the symlink into the mount and
# persist. (An atomic rename-replace in $HOME would clobber the symlink, but the
# current flavors write in-place; revisit for a future /login OAuth flavor.)
ln -sfn "$DEST/claude.json" "$DOTCLAUDE"
# Gateway: the Okta token-cache volume arrives root-owned; hand it to claude so
# the non-root apiKeyHelper can write its cache. Dir exists only when mounted.
[[ -d /home/claude/.local/share/litellm ]] && { chown -R claude:claude /home/claude/.local/share/litellm 2>/dev/null || true; }

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
        # --no-times/--omit-dir-times: Apple `container`'s VM file share rejects
        # utimensat on the bind mount (EPERM), which `-a` (implies -t) would hit,
        # failing the whole sync (exit 23) under set -e. Seed mtimes are irrelevant
        # (--ignore-existing keys on name, not time), so drop time preservation;
        # perms/symlinks/recursion still apply and work on the file share.
        gosu claude rsync -a --no-times --omit-dir-times "${rsync_mode[@]}" \
            --exclude=dotclaude.json \
            "$SEED"/ "$DEST"/
    else
        gosu claude cp "${cp_mode[@]}" "$SEED"/. "$DEST"/
    fi
fi

# Merge the user's settings override (staged at /opt/claude-stage/settings.override.json
# by the launcher when present) onto the seeded settings.json, in place. Re-applied
# every launch so the override's keys win.
# The base settings.json keeps its normal seeded lifecycle (preserved across
# launches via --ignore-existing; refreshed only by `reseed`), so writes made by
# /setup-vertex survive. jq `*` deep-merges objects; arrays/scalars are replaced
# by the override. Removing a key from the override does not auto-revert the base
# until the next reseed (in-place merge) -- documented behavior.
SETTINGS="$DEST/settings.json"
OVERRIDE="/opt/claude-stage/settings.override.json"
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
    cr_sync_mcp_servers "$DOTCLAUDE" "$SEED/dotclaude.json" > "$tmp" \
        && cat "$tmp" > "$DOTCLAUDE"
    rm -f "$tmp"
fi

# Graft MCP credentials from the host's ~/.claude.json (staged read-only at
# /opt/claude-stage/host-claude.json by the wrapper) into the container's
# ~/.claude.json. Only the `env` (stdio) and `headers` (http) sub-blocks of
# servers that ALREADY exist in the container config are copied over -- the
# container keeps its own `command` paths (host paths like /opt/homebrew/bin
# don't exist in the image) and any servers the host has that the container
# doesn't are ignored. Lets you keep MCP credentials in one place on the
# host instead of duplicating them in the config `env` file. Re-applied every
# launch so host edits propagate.
HOST_DOTCLAUDE_RO=/opt/claude-stage/host-claude.json
if [[ -f "$HOST_DOTCLAUDE_RO" ]] && command -v jq >/dev/null 2>&1; then
    if jq -e '.mcpServers' "$HOST_DOTCLAUDE_RO" >/dev/null 2>&1; then
        tmp="$(mktemp)"
        cr_graft_mcp_creds "$DOTCLAUDE" "$HOST_DOTCLAUDE_RO" > "$tmp" \
            && cat "$tmp" > "$DOTCLAUDE"
        rm -f "$tmp"
    fi
fi

chown claude:claude "$DOTCLAUDE" 2>/dev/null || true
# 0600, not 0644: this file holds grafted MCP credentials (env/headers secrets);
# only claude (session) and root (this entrypoint) ever need to touch it.
chmod 0600 "$DOTCLAUDE" 2>/dev/null || true

# --- memory: derived index + global tier surfacing --------------------------
# The container always runs at /workspace, so Claude's per-project dir is always
# projects/-workspace -- here backed by a per-host-repo bind mount (see launcher).
# MEMORY.md is DERIVED from each tier's *.md fact-file frontmatter: rebuild it
# every launch so a concurrent-write loss self-heals and the global index is
# fresh. The global tier (memory-global/, shared per-flavor) is surfaced by
# composing it into ~/.claude/CLAUDE.md, which Claude auto-loads as user memory.
REBUILD=/opt/claude/rebuild-memory-index.sh
PROJ_MEM="$DEST/projects/-workspace/memory"
GLOBAL_MEM="$DEST/memory-global"
if [[ -x "$REBUILD" ]]; then
    if [[ -d "$PROJ_MEM" ]]; then
        gosu claude "$REBUILD" "$PROJ_MEM" || true
    fi
    # Create the per-flavor global tier. Guarded so a stray non-directory at this
    # path degrades the memory feature instead of killing container startup.
    mkdir -p "$GLOBAL_MEM" 2>/dev/null || true
    if [[ -d "$GLOBAL_MEM" ]]; then
        chown claude:claude "$GLOBAL_MEM" 2>/dev/null || true
        gosu claude "$REBUILD" "$GLOBAL_MEM" || true
    fi
    # Never silently destroy a CLAUDE.md a user may have hand-authored before this
    # feature existed: back it up once if it isn't already our derived file.
    if [[ -f "$DEST/CLAUDE.md" && ! -e "$DEST/CLAUDE.md.pre-memory.bak" ]] \
        && ! head -1 "$DEST/CLAUDE.md" 2>/dev/null | grep -q '^# Memory (container-managed)$'; then
        cp "$DEST/CLAUDE.md" "$DEST/CLAUDE.md.pre-memory.bak" 2>/dev/null || true
        chown claude:claude "$DEST/CLAUDE.md.pre-memory.bak" 2>/dev/null || true
    fi
    # Compose the auto-loaded user-memory file: static two-tier instructions plus
    # the freshly-rebuilt global index. Written atomically (temp in $DEST + mv,
    # same-filesystem rename) and overwritten each launch (derived).
    _cmd_tmp="$(mktemp "$DEST/.CLAUDE.md.XXXXXX")"
    {
        cat <<'HDR'
# Memory (container-managed)

This container keeps two memory tiers:

- **Project memory** (`~/.claude/projects/-workspace/memory/`) — facts specific to
  THIS repo. Backed by a per-host-repo dir, so it does not leak across repos.
- **Global memory** (`~/.claude/memory-global/`) — cross-project facts that should
  follow you everywhere in this flavor (who the user is, commit style, standing
  preferences). Shared across all repos of this flavor.

Write repo-specific facts to project memory; write cross-project facts to global
memory. In BOTH tiers, `MEMORY.md` is DERIVED from the `*.md` fact files'
frontmatter and rebuilt every launch — edit the fact files, not the index.

## Global memory index
HDR
        if grep -qE '^- ' "$GLOBAL_MEM/MEMORY.md" 2>/dev/null; then
            grep -E '^- ' "$GLOBAL_MEM/MEMORY.md"
        else
            echo "_(none yet)_"
        fi
    } > "$_cmd_tmp"
    chown claude:claude "$_cmd_tmp" 2>/dev/null || true
    chmod 0644 "$_cmd_tmp" 2>/dev/null || true
    mv "$_cmd_tmp" "$DEST/CLAUDE.md" 2>/dev/null || rm -f "$_cmd_tmp"
fi
# ----------------------------------------------------------------------------

# --- statusline override ------------------------------------------------------
# The host statusline is executed on EVERY render, so it can't be a live mount
# (single-file mounts rot on Docker Desktop macOS). The launcher stages it; copy
# it over the baked default once at boot into the image path (root-owned, but
# world-readable/executable so the claude user can run it).
STAGE_STATUSLINE=/opt/claude-stage/statusline.sh
if [[ -f "$STAGE_STATUSLINE" ]]; then
    cp "$STAGE_STATUSLINE" /opt/claude/statusline.sh
    chmod 0755 /opt/claude/statusline.sh
fi

# --- git identity + gh credential helper -------------------------------------
# Write a container-owned ~/.gitconfig, INLINING the launcher-staged identity
# once at boot rather than a live `[include]`.
#
# Why inline, not [include]: the identity is a host file we must never re-read on
# a hot path. Historically it was a single-file ro bind mount, which rots on
# Docker Desktop's macOS file-share across host sleep/wake -- a stale single-file
# mount becomes unreadable-as-a-file (I/O error, not ENOENT), and git aborts a
# non-ENOENT include with `fatal: bad config line N in file ~/.gitconfig`,
# breaking EVERY git call + the git-based statusline. It now arrives in the
# per-run stage dir instead (a snapshot on a directory mount), but we still read
# it exactly once, here, so any read failure can't poison later git ops.
GITCONFIG=/home/claude/.gitconfig
IDENTITY=/opt/claude-stage/gitconfig-identity
{
    # Read the seed once. On stale-mount failure / empty / partial read, skip
    # identity (non-fatal) rather than embed garbage; validate it looks like a
    # [user] block before trusting it. The seed is already a [user] stanza.
    _identity="$(cat "$IDENTITY" 2>/dev/null || true)"
    if [[ "$_identity" == *"[user]"* ]]; then
        printf '%s\n\n' "$_identity"
    fi
    cat <<'EOF'
[safe]
    directory = *
[init]
    defaultBranch = main
EOF
} > "$GITCONFIG"
chown claude:claude "$GITCONFIG"

# Register gh as the HTTPS credential helper when a token was injected (GH_TOKEN
# is passed in by the wrapper). HTTPS-scoped only -- SSH remotes are unaffected.
if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    gosu claude env HOME=/home/claude GH_TOKEN="$GH_TOKEN" gh auth setup-git 2>/dev/null || true
fi
# -----------------------------------------------------------------------------

exec_env=( HOME=/home/claude )
# Preserve a forwarded SSH agent socket across the drop to claude (gosu env resets
# the environment). Set by the docker/podman -e SSH_AUTH_SOCK=/ssh-agent flag or by
# apple `container --ssh` in-guest. Absent when forwarding is off -> nothing added.
[[ -n "${SSH_AUTH_SOCK:-}" ]] && exec_env+=( "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" )
if [[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]]; then
    exec_env+=( "GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS" )
fi
exec gosu claude env "${exec_env[@]}" "$@"
