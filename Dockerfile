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
        rsync \
        gosu \
        jq \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# uv + mcp-atlassian. uv tool install drops the executable in
# UV_TOOL_BIN_DIR; pointed at /usr/local/bin so the seed config can
# reference a stable path. uv handles fetching its own managed Python.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && UV_TOOL_BIN_DIR=/usr/local/bin UV_TOOL_DIR=/opt/uv-tools \
        uv tool install mcp-atlassian

# Vida Vertex configuration (see Confluence: "Claude Code on Vertex-AI").
# Setting these as ENV means claude-code boots straight into Vertex mode --
# no interactive `/login` flow needed, no edits to host ~/.zshrc.
ENV CLAUDE_CODE_USE_VERTEX=1 \
    ANTHROPIC_VERTEX_PROJECT_ID=vertex-test-495715 \
    CLOUD_ML_REGION=us-east5 \
    ANTHROPIC_MODEL=claude-opus-4-6 \
    ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-6[1m]" \
    ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-6 \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5@20251001
# GOOGLE_APPLICATION_CREDENTIALS is exported by the entrypoint at runtime
# rather than baked into the image (avoids the Hadolint
# SecretsUsedInArgOrEnv warning on the *_CREDENTIALS name pattern).

# Seed payload: baseline settings + pre-installed superpowers plugin.
# Lives under /opt/claude-seed; copied into /root/.claude (the bind-mount
# from host ~/.claude-vertex) on first container start by the entrypoint.
ARG SUPERPOWERS_SHA=f2cbfbefebbfef77321e4c9abc9e949826bea9d7
ARG SUPERPOWERS_VERSION=5.1.0
ARG CAVEMAN_SHA=ef6050c5e1848b6880ff47c32ade1a608a64f85e
# Cache dir name matches the short SHA used by `claude plugin` on the host.
ARG CAVEMAN_VERSION=ef6050c5e184

COPY seed/ /opt/claude-seed/

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

# Default statusline. Wrapper script mounts a host override onto this
# same path if ~/.claude/statusline-command.sh exists on the host.
COPY statusline.sh /opt/claude-vertex/statusline.sh
RUN chmod +x /opt/claude-vertex/statusline.sh

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["claude"]
