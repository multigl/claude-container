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
mkdir -p "$HOST_CFG"

# Ensure named volume exists.
docker volume inspect "$GCLOUD_VOL" >/dev/null 2>&1 || docker volume create "$GCLOUD_VOL" >/dev/null

run_in_container() {
    local extra_flags=()
    if [[ -t 0 && -t 1 ]]; then
        extra_flags+=(-it)
    fi
    docker run --rm "${extra_flags[@]}" \
        -v "$PWD:/workspace" \
        -v "$GCLOUD_VOL:/root/.config/gcloud" \
        -v "$HOST_CFG:/root/.claude" \
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
