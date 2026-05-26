#!/usr/bin/env bash
# Launch Claude Code (Vertex AI build) against the current directory.
#
# Usage:
#   claude-vertex            # run `claude` in $PWD
#   claude-vertex shell      # bash inside container
#   claude-vertex auth       # one-time: gcloud ADC login, persisted to docker volume
#   claude-vertex -- <args>  # pass extra args to `claude`
#
# Nothing touches host ~/.zshrc or host ~/.config/gcloud.
# Auth lives in a named docker volume; settings live in a host dir kept
# separate from ~/.claude so the host's regular Anthropic-API claude is untouched.
set -euo pipefail

IMAGE="${CLAUDE_VERTEX_IMAGE:-claude-vertex:latest}"
GCLOUD_VOL="${CLAUDE_VERTEX_GCLOUD_VOL:-claude-vertex-gcloud}"
HOST_CFG="${CLAUDE_VERTEX_HOME:-$HOME/.claude-vertex}"
HOST_DOTCLAUDE="${HOST_CFG}.json"
HOST_ENV_FILE="${CLAUDE_VERTEX_ENV_FILE:-$HOME/.claude-vertex.env}"
mkdir -p "$HOST_CFG"
# Ensure file exists so Docker bind-mounts it as a file, not a directory.
[[ -f "$HOST_DOTCLAUDE" ]] || : > "$HOST_DOTCLAUDE"
# Seed an empty env file with placeholders for MCP tokens. User edits in
# host editor; values are passed to container via --env-file.
if [[ ! -f "$HOST_ENV_FILE" ]]; then
    cat > "$HOST_ENV_FILE" <<'EOF'
# Tokens for MCP servers used by claude-vertex.
# Atlassian: https://id.atlassian.com/manage-profile/security/api-tokens
# Context7:  https://context7.com (account -> API key)
JIRA_API_TOKEN=
CONFLUENCE_API_TOKEN=
CONTEXT7_API_KEY=
EOF
    chmod 600 "$HOST_ENV_FILE"
fi

# Ensure named volume exists.
docker volume inspect "$GCLOUD_VOL" >/dev/null 2>&1 || docker volume create "$GCLOUD_VOL" >/dev/null

run_in_container() {
    local extra_flags=()
    if [[ -t 0 && -t 1 ]]; then
        extra_flags+=(-it)
    fi
    # Optional: override the baked-in statusline with the host's, if present.
    local host_statusline="$HOME/.claude/statusline-command.sh"
    if [[ -f "$host_statusline" ]]; then
        extra_flags+=(-v "$host_statusline:/opt/claude-vertex/statusline.sh:ro")
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
    docker run --rm "${extra_flags[@]}" \
        --env-file "$HOST_ENV_FILE" \
        -v "$PWD:/workspace" \
        -v "$GCLOUD_VOL:/home/claude/.config/gcloud" \
        -v "$HOST_CFG:/home/claude/.claude" \
        -v "$HOST_DOTCLAUDE:/home/claude/.claude.json" \
        -w /workspace \
        "$IMAGE" "$@"
}

case "${1:-}" in
    auth)
        # Container-only gcloud Application Default Credentials login.
        # --no-launch-browser prints a URL; paste it in your host browser,
        # then paste the verification code back. Creds persist in the volume.
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
