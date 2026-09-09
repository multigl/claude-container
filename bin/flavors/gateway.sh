#!/usr/bin/env bash
# gateway flavor driver. Routes through an Anthropic-API-compatible LLM gateway;
# auth is the baked Okta apiKeyHelper, whose token cache lives in a host bind dir.

CRED_OKTA_DIR="${STATE_DIR}/creds/okta"

fl_cred_dirs()  { printf '%s\n' "$CRED_OKTA_DIR"; }
fl_cred_paths() { printf '%s\n' "$CRED_OKTA_DIR"; }

fl_run_flags() {
    printf '%s\n' '-v'
    printf '%s\n' "${CRED_OKTA_DIR}:/home/claude/.local/share/litellm"
}

# Okta device-authorization login. The baked helper prints a verification URL to
# stderr; approve it in the host browser. --login-only fills the token cache
# without emitting a token.
fl_auth() {
    echo ">> Okta device login inside container (approve in your browser)"
    run_in_container /opt/claude/api-key-helper --login-only
    echo ">> done. token cache saved to $CRED_OKTA_DIR"
}

fl_seed_env() {
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
    _env_block_mcp_atlassian
    _env_block_mcp_context7
}

fl_print_paths() { printf 'CRED_OKTA_DIR=%s\n' "$CRED_OKTA_DIR"; }

fl_doctor() {
    if [[ -n "$(ls -A "$CRED_OKTA_DIR" 2>/dev/null)" ]]; then
        echo "  ok: Okta token cache present ($CRED_OKTA_DIR)"
    else
        echo "  MISSING: run 'FLAVOR=gateway just auth'"
    fi
    if [[ -f "$HOST_ENV_FILE" ]] && grep -Eq '^OKTA_CLIENT_ID=.+' "$HOST_ENV_FILE"; then
        echo "  ok: OKTA_CLIENT_ID set in $HOST_ENV_FILE"
    else
        echo "  MISSING: set OKTA_CLIENT_ID in $HOST_ENV_FILE"
    fi
}

fl_legacy_volume() { printf 'claude-gateway-okta\n'; }
