#!/usr/bin/env bash
# Launch Claude Code in a container, in one of two flavors:
#   vertex  -- routes through Vertex AI       (gcloud ADC auth)
#   gateway -- routes through an LLM gateway   (apiKeyHelper auth)
#
# Flavor is chosen by the name this script is invoked as -- symlink it to
# `claude-vertex` and/or `claude-gateway` -- or forced with CLAUDE_FLAVOR=...
#
#   claude-vertex             # run `claude` in $PWD against Vertex
#   claude-gateway            # run `claude` in $PWD against the gateway
#   claude-<flavor> shell     # bash inside the container
#   claude-vertex auth        # one-time gcloud ADC login (vertex only)
#   claude-<flavor> migrate-memory        # move legacy shared memory to this repo's key
#   claude-<flavor> rebuild-memory-index  # regenerate the derived MEMORY.md indexes
#   claude-<flavor> -- <args> # pass extra args to `claude`
#
# Nothing touches host ~/.zshrc or host ~/.config/gcloud. Per-flavor state lives
# under $XDG_STATE_HOME/vida-claude-container/<flavor>/ and config under
# $XDG_CONFIG_HOME/vida-claude-container/<flavor>/, kept separate from ~/.claude
# so the host's regular Anthropic-API claude is untouched and the flavors never collide.
set -euo pipefail

case "$(basename "$0")" in
    claude-gateway) FLAVOR=gateway ;;
    *)              FLAVOR=vertex  ;;
esac
FLAVOR="${CLAUDE_FLAVOR:-$FLAVOR}"

IMAGE="${CLAUDE_IMAGE:-claude-${FLAVOR}:latest}"
# --- host-side paths (XDG split) --------------------------------------------
# Config (hand-edited, back-up-able) lives under XDG_CONFIG_HOME; state
# (machine-managed, disposable) under XDG_STATE_HOME. Per-flavor subdir in each.
NS="vida-claude-container"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${NS}/${FLAVOR}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${NS}/${FLAVOR}"

# State: the .claude dir (mounted to the container's ~/.claude) + .claude.json.
# No per-flavor override knob -- relocation follows XDG_STATE_HOME only.
HOST_CFG="${STATE_DIR}/claude"
HOST_DOTCLAUDE="${STATE_DIR}/claude.json"

# Per-project isolation. The container always runs at /workspace, so Claude
# Code's cwd-slug is always "-workspace" and every host repo would otherwise
# share one memory/history bucket. Key a host dir on the host path so each repo's
# memory + transcripts stay separate, and bind-mount it over the container's
# projects/-workspace (below). The key is a readable slug of $PWD PLUS a checksum
# of the full path: slugifying alone maps both "/" and "-" to "-", so two paths
# like a/foo-bar/baz and a/foo/bar-baz would collide -- the checksum disambiguates.
# $PWD (not realpath) so the key matches the path we bind-mount at /workspace.
_pwd_slug="$(printf '%s' "$PWD" | sed 's#/#-#g')"
_pwd_hash="$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
PROJECT_KEY="${_pwd_slug}-${_pwd_hash}"
HOST_PROJECT_DIR="${STATE_DIR}/projects/${PROJECT_KEY}"

# Config: env / mounts / gitconfig / settings override. Each keeps an escape-hatch
# override env var so it can be pointed into a dotfiles repo. (See README for the
# mounts-file format and the settings.override.json semantics.)
HOST_ENV_FILE="${CLAUDE_ENV_FILE:-${CFG_DIR}/env}"
HOST_MOUNTS_FILE="${CLAUDE_MOUNTS_FILE:-${CFG_DIR}/mounts}"
HOST_GITCONFIG="${CLAUDE_GITCONFIG:-${CFG_DIR}/gitconfig}"
HOST_SETTINGS="${CLAUDE_SETTINGS:-${CFG_DIR}/settings.override.json}"

# --print-paths: emit resolved paths and exit BEFORE any side effect (mkdir,
# seeding, volume creation, docker). Used by tests/test_launcher_paths.sh.
if [[ "${1:-}" == "--print-paths" ]]; then
    cat <<EOF
FLAVOR=$FLAVOR
CFG_DIR=$CFG_DIR
STATE_DIR=$STATE_DIR
HOST_CFG=$HOST_CFG
HOST_DOTCLAUDE=$HOST_DOTCLAUDE
PROJECT_KEY=$PROJECT_KEY
HOST_PROJECT_DIR=$HOST_PROJECT_DIR
HOST_ENV_FILE=$HOST_ENV_FILE
HOST_MOUNTS_FILE=$HOST_MOUNTS_FILE
HOST_GITCONFIG=$HOST_GITCONFIG
HOST_SETTINGS=$HOST_SETTINGS
IMAGE=$IMAGE
EOF
    exit 0
fi
# ----------------------------------------------------------------------------

# vertex-only: named docker volume holding gcloud ADC credentials.
GCLOUD_VOL="${CLAUDE_VERTEX_GCLOUD_VOL:-claude-vertex-gcloud}"
# gateway-only: named docker volume holding the Okta id_token cache (the baked
# apiKeyHelper's refresh_token/id_token store). Wipe with `reset-auth`.
OKTA_VOL="${CLAUDE_GATEWAY_OKTA_VOL:-claude-gateway-okta}"

mkdir -p "$CFG_DIR" "$HOST_CFG" "$HOST_PROJECT_DIR"
# Ensure file exists so Docker bind-mounts it as a file, not a directory.
[[ -f "$HOST_DOTCLAUDE" ]] || : > "$HOST_DOTCLAUDE"

# Seed an empty env file with placeholders. User edits in host editor; values
# are passed to the container via --env-file.
if [[ ! -f "$HOST_ENV_FILE" ]]; then
    {
        if [[ "$FLAVOR" == gateway ]]; then
            cat <<'EOF'
# claude-gateway: the baked Okta apiKeyHelper reads these to mint an id_token.
# OKTA_ISSUER = Vida Org server (no /oauth2/<id>); OKTA_CLIENT_ID = the Native
# app client_id (must equal LiteLLM's JWT_AUDIENCE). Run `claude-gateway auth`
# once to complete the browser device login. Passed in via --env-file.
OKTA_ISSUER=https://vida.okta.com
OKTA_CLIENT_ID=
CLAUDE_CODE_API_KEY_HELPER_TTL_MS=300000
# ANTHROPIC_BASE_URL=https://litellm.local.sunbeam.network   # gateway endpoint override

EOF
        fi
        cat <<'EOF'
# Credentials + endpoints for MCP servers.
# Atlassian API tokens: https://id.atlassian.com/manage-profile/security/api-tokens
# Context7 API key:     https://context7.com (account -> API key)
JIRA_URL=https://vidahealth.atlassian.net
JIRA_USERNAME=
JIRA_API_TOKEN=
CONFLUENCE_URL=https://vidahealth.atlassian.net/wiki
CONFLUENCE_USERNAME=
CONFLUENCE_API_TOKEN=
CONTEXT7_API_KEY=
EOF
    } > "$HOST_ENV_FILE"
    chmod 600 "$HOST_ENV_FILE"
fi

# Seed the git identity file once, prefilled from the host's effective identity
# resolved in $PWD (so folder-scoped includeIf values are honored). Editable and
# persistent thereafter; delete it to re-seed. gpgsign is off by default (the
# signing blocks ship commented out).
if [[ ! -f "$HOST_GITCONFIG" ]]; then
    _git_name="$(git -C "$PWD" config --get user.name  2>/dev/null || true)"
    _git_email="$(git -C "$PWD" config --get user.email 2>/dev/null || true)"
    cat > "$HOST_GITCONFIG" <<EOF
# claude-${FLAVOR}: git identity used INSIDE the container. Prefilled from your
# host git config; edit freely (persists across sessions; delete to re-seed).
# To enable SSH commit signing: set signingkey to your SSH signing public key,
# uncomment the [gpg]/[commit] blocks, and launch with CLAUDE_FORWARD_SSH_AGENT=1.
[user]
    name = ${_git_name}
    email = ${_git_email}
    # signingkey = ssh-ed25519 AAAA...
# [gpg]
#     format = ssh
# [commit]
#     gpgsign = true
EOF
    chmod 600 "$HOST_GITCONFIG"
fi

# Ensure the flavor's named credential volume exists.
if [[ "$FLAVOR" == vertex ]]; then
    docker volume inspect "$GCLOUD_VOL" >/dev/null 2>&1 || docker volume create "$GCLOUD_VOL" >/dev/null
else
    docker volume inspect "$OKTA_VOL" >/dev/null 2>&1 || docker volume create "$OKTA_VOL" >/dev/null
fi

run_in_container() {
    local extra_flags=()
    if [[ -t 0 && -t 1 ]]; then
        extra_flags+=(-it)
    fi
    # Optional: override the baked-in statusline with the host's, if present.
    local host_statusline="$HOME/.claude/statusline-command.sh"
    if [[ -f "$host_statusline" ]]; then
        extra_flags+=(-v "$host_statusline:/opt/claude/statusline.sh:ro")
    fi
    # Seeded git identity, mounted ro; the entrypoint's generated ~/.gitconfig
    # includes it. Replaces the old direct ~/.gitconfig mount (which dragged in
    # host-only paths + includeIf conditions that never match container paths).
    if [[ -f "$HOST_GITCONFIG" ]]; then
        extra_flags+=(-v "$HOST_GITCONFIG:/home/claude/.gitconfig-identity:ro")
    fi
    # Settings override: deep-merged onto the seeded settings.json by the
    # entrypoint. Mounted ro only when it exists -- absent means "no deltas".
    if [[ -f "$HOST_SETTINGS" ]]; then
        extra_flags+=(-v "$HOST_SETTINGS:/home/claude/.claude/settings.override.json:ro")
    fi
    # GitHub token resolved from the host (gh stores it in the OS keyring by
    # default, so ~/.config/gh alone lacks it). Injected in-memory per run; never
    # written to disk. gh + its credential helper honor GH_TOKEN.
    if command -v gh >/dev/null 2>&1; then
        _gh_token="$(gh auth token 2>/dev/null || true)"
        [[ -n "$_gh_token" ]] && extra_flags+=(-e "GH_TOKEN=$_gh_token")
    fi
    # Opt-in SSH agent forwarding: enables SSH commit signing + SSH git push using
    # the host agent (e.g. 1Password). Set CLAUDE_FORWARD_SSH_AGENT=1 in your shell.
    # macOS/Docker Desktop can't bind-mount a host socket directly -- it uses the
    # synthesized /run/host-services/ssh-auth.sock (requires the host to have run
    # `launchctl setenv SSH_AUTH_SOCK <1p-agent.sock>` before Docker Desktop start).
    if [[ -n "${CLAUDE_FORWARD_SSH_AGENT:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            extra_flags+=(--mount "type=bind,src=/run/host-services/ssh-auth.sock,target=/ssh-agent")
            extra_flags+=(-e "SSH_AUTH_SOCK=/ssh-agent")
        elif [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
            extra_flags+=(-v "$SSH_AUTH_SOCK:/ssh-agent")
            extra_flags+=(-e "SSH_AUTH_SOCK=/ssh-agent")
        else
            echo ">> CLAUDE_FORWARD_SSH_AGENT set but SSH_AUTH_SOCK is empty; skipping agent forward" >&2
        fi
    fi
    # Optional: host ssh keys + known_hosts so `git push` over SSH works.
    # Read-only; new host fingerprints can't be saved across runs.
    if [[ -d "$HOME/.ssh" ]]; then
        extra_flags+=(-v "$HOME/.ssh:/home/claude/.ssh:ro")
    fi
    # Optional: host ~/.claude.json (the Anthropic-API claude's config) mounted
    # read-only so the entrypoint can graft its `mcpServers` block into the
    # container's separate ~/.claude.json. Keeps MCP credentials in one place
    # on the host without leaking the rest of that file's state. Both flavors
    # use the same atlassian/context7 MCP servers, so this applies to both.
    if [[ -f "$HOME/.claude.json" ]]; then
        extra_flags+=(-v "$HOME/.claude.json:/home/claude/.host-claude.json:ro")
    fi

    # Flavor-specific mounts.
    if [[ "$FLAVOR" == vertex ]]; then
        extra_flags+=(-v "$GCLOUD_VOL:/home/claude/.config/gcloud")
    else
        # gateway: mount the Okta token-cache volume where the baked apiKeyHelper
        # writes (~/.local/share/litellm). Populated by `claude-gateway auth`,
        # persisted across runs, wiped by `reset-auth`.
        extra_flags+=(-v "$OKTA_VOL:/home/claude/.local/share/litellm")
    fi

    # Forward the reseed flag so the entrypoint force-overwrites the seeded
    # files (settings + plugins) instead of preserving existing ones.
    [[ -n "${CLAUDE_RESEED:-}" ]] && extra_flags+=(-e "CLAUDE_RESEED=1")

    # Optional extra bind mounts from $HOST_MOUNTS_FILE. Each approved host dir is
    # mounted at /mnt/approved/<basename> so Claude's native tools can reach it.
    # Read-only unless the line ends in ` :rw`. Missing dirs and basename
    # collisions are skipped with a warning so a stale entry never blocks launch.
    if [[ -f "$HOST_MOUNTS_FILE" ]]; then
        local seen_names=" "
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"                       # strip trailing comments
            line="${line#"${line%%[![:space:]]*}"}"  # ltrim
            line="${line%"${line##*[![:space:]]}"}"  # rtrim
            [[ -z "$line" ]] && continue
            local mode=ro path="$line"
            if [[ "$line" == *:rw ]]; then
                mode=rw
                path="${line%:rw}"
                path="${path%"${path##*[![:space:]]}"}"  # rtrim before :rw
            fi
            # Expand a leading ~ to $HOME.
            [[ "$path" == "~"* ]] && path="${HOME}${path#\~}"
            if [[ ! -d "$path" ]]; then
                echo ">> skip mount: not a directory: $path" >&2
                continue
            fi
            local name
            name="$(basename "$path")"
            if [[ "$seen_names" == *" $name "* ]]; then
                echo ">> skip mount: duplicate basename '$name' ($path)" >&2
                continue
            fi
            seen_names+="$name "
            extra_flags+=(-v "$path:/mnt/approved/$name:$mode")
        done < "$HOST_MOUNTS_FILE"
    fi

    docker run --rm "${extra_flags[@]}" \
        --env-file "$HOST_ENV_FILE" \
        -e "HOST_UID=$(id -u)" \
        -e "HOST_GID=$(id -g)" \
        -e "CLAUDE_HOST_DIR=$PWD" \
        -v "$PWD:/workspace" \
        -v "$HOST_CFG:/home/claude/.claude" \
        -v "$HOST_PROJECT_DIR:/home/claude/.claude/projects/-workspace" \
        -v "$HOST_DOTCLAUDE:/home/claude/.claude.json" \
        -w /workspace \
        "$IMAGE" "$@"
}

case "${1:-}" in
    auth)
        case "$FLAVOR" in
            vertex)
                # gcloud Application Default Credentials login. --no-launch-browser
                # prints a URL; paste it in your host browser, then paste the
                # verification code back. Creds persist in the volume.
                echo ">> running 'gcloud auth application-default login --no-launch-browser' inside container"
                run_in_container gcloud auth application-default login --no-launch-browser
                echo ">> done. credentials saved to docker volume: $GCLOUD_VOL"
                ;;
            gateway)
                # Okta device-authorization login. The baked helper prints a
                # verification URL to stderr; approve it in your host browser.
                # --login-only populates the token cache without emitting a token.
                echo ">> Okta device login inside container (approve in your browser)"
                run_in_container /opt/claude/api-key-helper --login-only
                echo ">> done. token cache saved to docker volume: $OKTA_VOL"
                ;;
            *)
                echo "auth: not applicable for the '$FLAVOR' flavor." >&2
                exit 1
                ;;
        esac
        ;;
    reseed)
        # Re-copy the image's seed payload (settings.json + plugins) over the
        # host config, OVERWRITING those files with the image's current version.
        # Other state (history, projects, shell-snapshots) is left untouched.
        CLAUDE_RESEED=1 run_in_container true
        echo ">> re-seeded $HOST_CFG from image (settings + plugins overwritten)"
        ;;
    migrate-memory)
        # One-time: move the legacy shared bucket to THIS repo's per-project key.
        # Pure host-side (no container). Run from the repo that owns that history.
        # Refuses only if the target already holds data. The pre-feature bucket
        # lives INSIDE the ~/.claude mount ($HOST_CFG/projects/-workspace), not at
        # the new sibling $STATE_DIR/projects/ location.
        _legacy="$HOST_CFG/projects/-workspace"
        if [[ ! -d "$_legacy" ]]; then
            echo ">> no legacy bucket at $_legacy; nothing to migrate"
            exit 0
        fi
        if [[ -d "$HOST_PROJECT_DIR" && -n "$(ls -A "$HOST_PROJECT_DIR" 2>/dev/null)" ]]; then
            echo ">> target exists and is non-empty: $HOST_PROJECT_DIR; refusing to overwrite" >&2
            exit 1
        fi
        # The launcher pre-creates an empty target above; remove it so mv renames
        # the legacy bucket into place instead of nesting it inside.
        rmdir "$HOST_PROJECT_DIR" 2>/dev/null || true
        mkdir -p "$(dirname "$HOST_PROJECT_DIR")"
        mv "$_legacy" "$HOST_PROJECT_DIR"
        echo ">> migrated $_legacy -> $HOST_PROJECT_DIR"
        ;;
    rebuild-memory-index)
        # The entrypoint regenerates both memory indexes (project + global tier)
        # on every launch, so a no-op container run rebuilds them without starting
        # a session. Manual repair for a derived MEMORY.md.
        run_in_container true
        echo ">> rebuilt memory indexes for $PROJECT_KEY (project + global tier)"
        ;;
    shell)
        shift
        run_in_container bash "$@"
        ;;
    --)
        shift
        run_in_container claude "$@"
        ;;
    "")
        run_in_container claude
        ;;
    *)
        run_in_container claude "$@"
        ;;
esac
