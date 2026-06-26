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
# gateway-only: host apiKeyHelper script, bind-mounted into the container.
HOST_KEY_HELPER="${CLAUDE_GATEWAY_KEY_HELPER:-$HOME/.local/bin/okta-token-helper}"

mkdir -p "$HOST_CFG"
# Ensure file exists so Docker bind-mounts it as a file, not a directory.
[[ -f "$HOST_DOTCLAUDE" ]] || : > "$HOST_DOTCLAUDE"

# Seed an empty env file with placeholders. User edits in host editor; values
# are passed to the container via --env-file.
if [[ ! -f "$HOST_ENV_FILE" ]]; then
    {
        if [[ "$FLAVOR" == gateway ]]; then
            cat <<'EOF'
# claude-gateway: vars your mounted key-helper (okta-token-helper) reads to
# mint a gateway token. Passed into the container via --env-file and visible to
# the helper. Set OKTA_CLIENT_ID; add any client secret / scope it needs.
OKTA_ISSUER=https://vida.okta.com
OKTA_CLIENT_ID=
CLAUDE_CODE_API_KEY_HELPER_TTL_MS=3600000
# ANTHROPIC_BASE_URL=https://override-gateway.example.com   # optional runtime override

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

# Vertex: ensure the gcloud creds volume exists.
if [[ "$FLAVOR" == vertex ]]; then
    docker volume inspect "$GCLOUD_VOL" >/dev/null 2>&1 || docker volume create "$GCLOUD_VOL" >/dev/null
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
        # gateway: bind-mount the host apiKeyHelper read-only. settings.json
        # points apiKeyHelper at /opt/claude/api-key-helper. The :ro mount
        # preserves the host file's executable bit. Guard against a missing
        # path -- Docker would otherwise create an empty directory there and
        # the helper would silently fail.
        if [[ ! -x "$HOST_KEY_HELPER" ]]; then
            echo "claude-gateway: key-helper missing or not executable:" >&2
            echo "  $HOST_KEY_HELPER" >&2
            echo "  place an executable script there, or set CLAUDE_GATEWAY_KEY_HELPER." >&2
            exit 1
        fi
        extra_flags+=(-v "$HOST_KEY_HELPER:/opt/claude/api-key-helper:ro")
    fi

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
        # Container-only gcloud Application Default Credentials login (vertex).
        # --no-launch-browser prints a URL; paste it in your host browser, then
        # paste the verification code back. Creds persist in the volume.
        if [[ "$FLAVOR" != vertex ]]; then
            echo "auth: not applicable for the '$FLAVOR' flavor." >&2
            echo "  gateway auth is the mounted key-helper: $HOST_KEY_HELPER" >&2
            exit 1
        fi
        echo ">> running 'gcloud auth application-default login --no-launch-browser' inside container"
        run_in_container gcloud auth application-default login --no-launch-browser
        echo ">> done. credentials saved to docker volume: $GCLOUD_VOL"
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
