# Claude Code routed through Vertex AI.
# Bakes Vida's project / region / model pins so the host shell stays untouched.
FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        python3 \
        less \
        ripgrep \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Vida Vertex configuration (see Confluence: "Claude Code on Vertex-AI").
# Setting these as ENV means claude-code boots straight into Vertex mode --
# no interactive `/login` flow needed, no edits to host ~/.zshrc.
ENV CLAUDE_CODE_USE_VERTEX=1 \
    ANTHROPIC_VERTEX_PROJECT_ID=vertex-test-495715 \
    CLOUD_ML_REGION=us-east5 \
    ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-6[1m]" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-7[1m]" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5@20251001 \
    GOOGLE_APPLICATION_CREDENTIALS=/root/.config/gcloud/application_default_credentials.json

WORKDIR /workspace

CMD ["claude"]
