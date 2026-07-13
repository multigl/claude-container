# Claude Code in a container, two flavors from one build:
#   docker build --target vertex  -t claude-vertex:latest  .   # routes via Vertex AI
#   docker build --target gateway -t claude-gateway:latest .   # routes via an LLM gateway
# The shared `base` stage is built once and cached; each flavor adds only its
# own payload (vertex gets gcloud; gateway gets the gateway ENV + apiKeyHelper).
FROM node:20-bookworm-slim AS base

ENV DEBIAN_FRONTEND=noninteractive

# Base packages shared by both flavors. google-cloud-cli is NOT here -- it is
# Vertex-only and lives in the vertex stage.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        python3 \
        less \
        ripgrep \
        rsync \
        gosu \
        jq \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# uv + mcp-atlassian. uv tool install drops the executable in
# UV_TOOL_BIN_DIR; pointed at /usr/local/bin so the seed config can
# reference a stable path. uv handles fetching its own managed Python.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && UV_TOOL_BIN_DIR=/usr/local/bin UV_TOOL_DIR=/opt/uv-tools \
        uv tool install mcp-atlassian

# Seed payload: baseline settings + pre-installed superpowers plugin.
# Lives under /opt/claude-seed; copied into ~/.claude (the bind-mount from
# host ~/.claude-<flavor>) on first container start by the entrypoint.
# seed-common/ is flavor-neutral; each flavor stage overlays its settings.json.
ARG SUPERPOWERS_SHA=f2cbfbefebbfef77321e4c9abc9e949826bea9d7
ARG SUPERPOWERS_VERSION=5.1.0
ARG CAVEMAN_SHA=ef6050c5e1848b6880ff47c32ade1a608a64f85e
# Cache dir name matches the short SHA used by `claude plugin` on the host.
ARG CAVEMAN_VERSION=ef6050c5e184

COPY seed-common/ /opt/claude-seed/

RUN mkdir -p /opt/claude-seed/plugins/cache/claude-plugins-official \
                 /opt/claude-seed/plugins/cache/caveman \
    && git clone https://github.com/obra/superpowers.git \
        /opt/claude-seed/plugins/cache/claude-plugins-official/superpowers/${SUPERPOWERS_VERSION} \
    && git -C /opt/claude-seed/plugins/cache/claude-plugins-official/superpowers/${SUPERPOWERS_VERSION} \
        checkout --detach ${SUPERPOWERS_SHA} \
    && git clone https://github.com/JuliusBrussee/caveman.git \
        /opt/claude-seed/plugins/cache/caveman/caveman/${CAVEMAN_VERSION} \
    && git -C /opt/claude-seed/plugins/cache/caveman/caveman/${CAVEMAN_VERSION} \
        checkout --detach ${CAVEMAN_SHA}

# Non-root user. Claude Code refuses bypassPermissions mode as root.
# Entrypoint stays as root long enough to chown bind-mounted volumes,
# then drops to this user via gosu.
RUN userdel -r node 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash claude \
    && chown -R claude:claude /opt/claude-seed

# Default statusline at a flavor-neutral path. Wrapper script mounts a host
# override onto this same path if ~/.claude/statusline-command.sh exists.
COPY statusline.sh /opt/claude/statusline.sh
RUN chmod +x /opt/claude/statusline.sh

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["claude"]

# ---------- vertex flavor ----------
# Routes through Vida's Vertex AI project (see Confluence: "Claude Code on
# Vertex-AI"). gcloud ADC auth; env baked so claude-code boots straight into
# Vertex mode with no interactive /login.
FROM base AS vertex

RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV CLAUDE_CODE_USE_VERTEX=1 \
    ANTHROPIC_VERTEX_PROJECT_ID=vertex-test-495715 \
    CLOUD_ML_REGION=us 
# GOOGLE_APPLICATION_CREDENTIALS is exported by the entrypoint at runtime
# rather than baked into the image (avoids the Hadolint
# SecretsUsedInArgOrEnv warning on the *_CREDENTIALS name pattern).

COPY --chown=claude:claude seed-vertex/ /opt/claude-seed/

# ---------- gateway flavor ----------
# Routes through an Anthropic-API-compatible LLM gateway (e.g. LiteLLM) via
# ANTHROPIC_BASE_URL. Auth is the baked apiKeyHelper at /opt/claude/api-key-helper
# (an Okta device-login + id_token refresh helper, added below). No gcloud, no
# Vertex -- CLAUDE_CODE_USE_VERTEX is deliberately left unset so requests use the
# generic Anthropic format.
FROM base AS gateway

# Placeholder gateway URL. Override at build time with
#   --build-arg GATEWAY_BASE_URL=https://gateway.internal
# or at runtime via the wrapper's --env-file. Claude appends /v1/messages,
# so set the base WITHOUT that suffix.
ARG GATEWAY_BASE_URL=https://your-gateway.example.com
ENV ANTHROPIC_BASE_URL=${GATEWAY_BASE_URL} \
    ENABLE_TOOL_SEARCH=true \
    ANTHROPIC_MODEL=claude-opus-4-8 \
    ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6 \
    ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8 \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5
# Model IDs are placeholders -- set them to the model_name strings your gateway
# exposes. ENABLE_TOOL_SEARCH=true re-enables MCP tool search, which Claude
# disables by default against a non-first-party ANTHROPIC_BASE_URL.

COPY --chown=claude:claude seed-gateway/ /opt/claude-seed/

# Baked apiKeyHelper: mints/refreshes an Okta OIDC id_token (a JWT) that LiteLLM
# validates. Its token cache lives in the claude-gateway-okta docker volume
# mounted at ~/.local/share/litellm; `claude-gateway auth` runs it once
# (--login-only) to complete the interactive device login. python3 (from base)
# is the only dependency. settings.json points apiKeyHelper at this path.
COPY gateway/okta_token_helper.py /opt/claude/api-key-helper
RUN chmod 0755 /opt/claude/api-key-helper
