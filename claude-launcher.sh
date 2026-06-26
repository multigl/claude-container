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
#   claude-<flavor> -- <args> # pass extra args to `claude`
#
# Nothing touches host ~/.zshrc or host ~/.config/gcloud. Per-flavor state
# lives in host ~/.claude-<flavor>/, kept separate from ~/.claude so the host's
# regular Anthropic-API claude is untouched and the two flavors never collide.
set -euo pipefail

case "$(basename "$0")" in
    claude-gateway) FLAVOR=gateway ;;
    *)              FLAVOR=vertex  ;;
esac
FLAVOR="${CLAUDE_FLAVOR:-$FLAVOR}"

IMAGE="${CLAUDE_IMAGE:-claude-${FLAVOR}:latest}"
HOST_CFG="${CLAUDE_HOME:-$HOME/.claude-${FLAVOR}}"
HOST_DOTCLAUDE="${HOST_CFG}.json"
HOST_ENV_FILE="${CLAUDE_ENV_FILE:-$HOME/.claude-${FLAVOR}.env}"

# vertex-only: named docker volume holding gcloud ADC credentials.
GCLOUD_VOL="${CLAUDE_VERTEX_GCLOUD_VOL:-claude-vertex-gcloud}"
# gateway-only: named docker volume holding the Okta id_token cache (the baked
# apiKeyHelper's refresh_token/id_token store). Wipe with `reset-auth`.
OKTA_VOL="${CLAUDE_GATEWAY_OKTA_VOL:-claude-gateway-okta}"

mkdir -p "$HOST_CFG"
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
    # Optional: host git identity + global config so commits inside the
    # container are attributed to you. Read-only; container can't edit host.
    if [[ -f "$HOME/.gitconfig" ]]; then
        extra_flags+=(-v "$HOME/.gitconfig:/home/claude/.gitconfig:ro")
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

    docker run --rm "${extra_flags[@]}" \
        --env-file "$HOST_ENV_FILE" \
        -e "HOST_UID=$(id -u)" \
        -e "HOST_GID=$(id -g)" \
        -v "$PWD:/workspace" \
        -v "$HOST_CFG:/home/claude/.claude" \
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
