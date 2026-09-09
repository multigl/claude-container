#!/usr/bin/env bash
# vertex flavor driver. Routes through Vertex AI; auth is gcloud Application
# Default Credentials in a host bind dir. Sourced by claude-launcher.sh after
# STATE_DIR/CFG_DIR/STATE_CLAUDE_DIR are set.

CRED_GCLOUD_DIR="${STATE_DIR}/creds/gcloud"

fl_cred_dirs()  { printf '%s\n' "$CRED_GCLOUD_DIR"; }
fl_cred_paths() { printf '%s\n' "$CRED_GCLOUD_DIR"; }

fl_run_flags() {
    printf '%s\n' '-v'
    printf '%s\n' "${CRED_GCLOUD_DIR}:/home/claude/.config/gcloud"
}

# gcloud ADC login. --no-launch-browser prints a URL to paste into the host
# browser, then reads the verification code back. Creds land in the bind dir.
fl_auth() {
    echo ">> running 'gcloud auth application-default login --no-launch-browser' inside container"
    run_in_container gcloud auth application-default login --no-launch-browser
    echo ">> done. credentials saved to $CRED_GCLOUD_DIR"
}

fl_seed_env() {
    cat <<'EOF'
# claude-vertex: model + region pins. Passed into the container via --env-file
# (overrides the image ENV). Confirm the exact model IDs are enabled in your
# project's Model Garden.
#
# ============================ REQUIRED: SET THIS =============================
# The GCP project that serves the models. The image bakes only a placeholder
# ('your-gcp-project'), so unless you built with --build-arg VERTEX_PROJECT_ID=,
# uncomment the line below and fill it in -- every request fails without it, and
# the container prints a loud banner at every launch until you do.
#
# Leave it COMMENTED (not empty) if the project is baked into the image: an
# empty value here would override the baked one with nothing.
# ANTHROPIC_VERTEX_PROJECT_ID=acme-ai-prod
# =============================================================================
#
# All US regions, for data-residency requirements: Opus 4.8 + Sonnet 5 aren't
# served on single regions like us-east5 -- they need global/multi-region, so
# they ride the "us" multi-region below. Haiku 4.5 -> us-east5 (also US). Drop
# these pins if your own residency rules differ.
#
# Pinning matters: unpinned on Vertex, the small/fast (background) model defaults
# to claude-sonnet-4-5, which 429s if your project can't invoke it (it powers
# session titles + web-search summarization). Pinning also restores the 1M
# context window -- append [1m] to a model ID; Sonnet 5 is always 1M (no suffix).
ANTHROPIC_MODEL=claude-opus-4-8[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5
CLOUD_ML_REGION=us
VERTEX_REGION_CLAUDE_HAIKU_4_5=us-east5

EOF
    _env_block_mcp_atlassian
    _env_block_mcp_context7
}

fl_print_paths() { printf 'CRED_GCLOUD_DIR=%s\n' "$CRED_GCLOUD_DIR"; }

fl_doctor() {
    if [[ -f "$CRED_GCLOUD_DIR/application_default_credentials.json" ]]; then
        echo "  ok: ADC credentials present ($CRED_GCLOUD_DIR)"
    else
        echo "  MISSING ADC: run 'FLAVOR=vertex just auth'"
    fi
    # Host-side half of the project check the entrypoint does on the effective
    # env. Only the env file is visible from here -- a project baked in with
    # --build-arg lives in the image -- so an empty value is reported as
    # "unset here", not as broken.
    local project=""
    [[ -f "$HOST_ENV_FILE" ]] &&
        project="$(sed -n 's/^[[:space:]]*ANTHROPIC_VERTEX_PROJECT_ID=//p' "$HOST_ENV_FILE" | tail -1)"
    case "$project" in
        ""|your-gcp-project|your-project|CHANGEME)
            echo "  MISSING PROJECT: set ANTHROPIC_VERTEX_PROJECT_ID in $HOST_ENV_FILE"
            echo "                   (ignore if the project was baked in with --build-arg VERTEX_PROJECT_ID=...)"
            ;;
        *) echo "  ok: vertex project $project" ;;
    esac
}

fl_legacy_volume() { printf 'claude-vertex-gcloud\n'; }
