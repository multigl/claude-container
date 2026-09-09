#!/usr/bin/env bash
# personal flavor driver. Talks to api.anthropic.com with an Anthropic account,
# logged in from inside the container with `claude auth login --claudeai`.
#
# No cred bind dir: Claude Code writes ~/.claude/.credentials.json, which is
# already inside the $STATE_CLAUDE_DIR mount, so persistence is free. That file
# is opened O_NOFOLLOW and a symlink is refused, so never symlink it.
#
# The token is stored in plaintext -- there is no keychain in a Linux container,
# and claude-code has no credential-helper hook that could supply one. The
# launcher's chmod 700 on $STATE_CLAUDE_DIR plus claude-code's own 0600 on the
# file is the whole mitigation. See the spec for the alternative that was
# rejected (CLAUDE_CODE_OAUTH_TOKEN injection, which is inference-only scope and
# cannot self-refresh).

CRED_PERSONAL_FILE="${STATE_CLAUDE_DIR}/.credentials.json"

fl_cred_dirs()  { :; }
fl_cred_paths() { printf '%s\n' "$CRED_PERSONAL_FILE"; }
fl_run_flags()  { :; }

fl_auth() {
    echo ">> signing in to your Anthropic account inside the container"
    run_in_container claude auth login --claudeai
    echo ">> done. credential saved to $CRED_PERSONAL_FILE"
}

fl_seed_env() {
    cat <<'EOF'
# claude-personal: signs in to your Anthropic account with `claude-personal auth`
# (OAuth, completed in your host browser). No API key, no gateway, no Vertex.
# Nothing model-related is pinned here -- pick models with /model in the session.

EOF
    _env_block_mcp_context7
}

fl_print_paths() { printf 'CRED_PERSONAL_FILE=%s\n' "$CRED_PERSONAL_FILE"; }

fl_doctor() {
    if [[ -f "$CRED_PERSONAL_FILE" ]]; then
        echo "  ok: Anthropic credential present ($CRED_PERSONAL_FILE)"
    else
        echo "  MISSING: run 'FLAVOR=personal just auth'"
    fi
    # The mitigation for a plaintext token is the permissions, so check them
    # rather than assume the chmod ran.
    local dmode fmode
    dmode="$(ls -ld "$STATE_CLAUDE_DIR" 2>/dev/null | cut -c1-10)"
    if [[ -n "$dmode" && "$dmode" != "drwx------" ]]; then
        echo "  WARN: $STATE_CLAUDE_DIR is $dmode, expected drwx------"
    fi
    if [[ -f "$CRED_PERSONAL_FILE" ]]; then
        fmode="$(ls -l "$CRED_PERSONAL_FILE" 2>/dev/null | cut -c1-10)"
        if [[ "$fmode" != "-rw-------" ]]; then
            echo "  WARN: $CRED_PERSONAL_FILE is $fmode, expected -rw-------"
        fi
    fi
}

fl_legacy_volume() { :; }
