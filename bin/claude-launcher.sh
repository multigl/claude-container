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
#   claude-<flavor> migrate-memory        # move legacy shared memory to this repo's key
#   claude-<flavor> migrate-creds         # copy an old named cred volume into the new bind dir
#   claude-<flavor> rebuild-memory-index  # regenerate the derived MEMORY.md indexes
#   claude-<flavor> -- <args> # pass extra args to `claude`
#
# Nothing touches host ~/.zshrc or host ~/.config/gcloud. Per-flavor state lives
# under $XDG_STATE_HOME/vida-claude-container/<flavor>/ and config under
# $XDG_CONFIG_HOME/vida-claude-container/<flavor>/, kept separate from ~/.claude
# so the host's regular Anthropic-API claude is untouched and the flavors never collide.
set -euo pipefail

case "$(basename "$0")" in
    claude-gateway) FLAVOR=gateway ;;
    *)              FLAVOR=vertex  ;;
esac
FLAVOR="${CLAUDE_FLAVOR:-$FLAVOR}"

# Resolve symlinks so SCRIPT_DIR is the real bin/ even when invoked via a
# symlink (e.g. ~/.local/bin/claude-vertex -> .../src/bin/claude-launcher.sh).
# bash-3.2-portable readlink loop -- macOS has no `readlink -f`.
_src="${BASH_SOURCE[0]}"
while [[ -h "$_src" ]]; do
    _dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"

IMAGE="${CLAUDE_IMAGE:-claude-${FLAVOR}:latest}"
# --- host-side paths (XDG split) --------------------------------------------
# Config (hand-edited, back-up-able) lives under XDG_CONFIG_HOME; state
# (machine-managed, disposable) under XDG_STATE_HOME. Per-flavor subdir in each.
NS="vida-claude-container"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${NS}/${FLAVOR}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${NS}/${FLAVOR}"

# State: the .claude dir (mounted to the container's ~/.claude) + .claude.json.
# No per-flavor override knob -- relocation follows XDG_STATE_HOME only.
# claude.json lives INSIDE the .claude dir so it rides that (robust) directory
# bind mount and the container can symlink ~/.claude.json to it -- avoiding a
# fragile single-file bind mount (those rot on Docker Desktop macOS across
# sleep/wake). Migrated from the old sibling $STATE_DIR/claude.json below.
STATE_CLAUDE_DIR="${STATE_DIR}/claude"
HOST_DOTCLAUDE="${STATE_CLAUDE_DIR}/claude.json"
HOST_DOTCLAUDE_LEGACY="${STATE_DIR}/claude.json"

# Per-project isolation. The container always runs at /workspace, so Claude
# Code's cwd-slug is always "-workspace" and every host repo would otherwise
# share one memory/history bucket. Key a host dir on the host path so each repo's
# memory + transcripts stay separate, and bind-mount it over the container's
# projects/-workspace (below). The key is a readable slug of $PWD PLUS a checksum
# of the full path: slugifying alone maps both "/" and "-" to "-", so two paths
# like a/foo-bar/baz and a/foo/bar-baz would collide -- the checksum disambiguates.
# $PWD (not realpath) so the key matches the path we bind-mount at /workspace.
_pwd_slug="$(printf '%s' "$PWD" | sed 's#/#-#g')"
_pwd_hash="$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
PROJECT_KEY="${_pwd_slug}-${_pwd_hash}"
HOST_PROJECT_DIR="${STATE_DIR}/projects/${PROJECT_KEY}"

# Credentials as host bind-mount DIRECTORIES (uniform across docker/podman/apple;
# no `volume` subcommand needed). Replaces the old named volumes.
CRED_GCLOUD_DIR="${STATE_DIR}/creds/gcloud"   # vertex: gcloud ADC
CRED_OKTA_DIR="${STATE_DIR}/creds/okta"       # gateway: Okta token cache

# Config: env / mounts / settings override. Each keeps an escape-hatch
# override env var so it can be pointed into a dotfiles repo. (See README for the
# mounts-file format and the settings.override.json semantics.)
HOST_ENV_FILE="${CLAUDE_ENV_FILE:-${CFG_DIR}/env}"
HOST_MOUNTS_FILE="${CLAUDE_MOUNTS_FILE:-${CFG_DIR}/mounts}"
HOST_SETTINGS="${CLAUDE_SETTINGS:-${CFG_DIR}/settings.override.json}"
# launcher.conf: host-side launcher settings (flat INI `key = value`, parsed not
# sourced). First key: forward_ssh (SSH agent forwarding toggle). No escape-hatch
# path override -- the per-run env override is CLAUDE_FORWARD_SSH.
HOST_LAUNCHER_CONF="${CFG_DIR}/launcher.conf"

# Resolve the container runtime (apple>docker>podman; CLAUDE_RUNTIME overrides).
CR_SOURCED=1 source "$SCRIPT_DIR/container-runtime.sh"
RUNTIME="$(cr_resolve)"

# --- launcher.conf parsing + SSH-forward policy ------------------------------
# Read one key from a flat INI file (strip # comments, trim, split on first =).
# bash-3.2-safe; not sourced (never executes file contents). Prints the value.
_conf_get() {  # _conf_get KEY FILE
    local key="$1" file="$2" line k v
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"; v="${line#*=}"
        k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        if [[ "$k" == "$key" ]]; then printf '%s' "$v"; return 0; fi
    done < "$file"
}

# Truthy set per spec: 1 / true / yes (case-insensitive). Everything else false.
_is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes) return 0 ;; *) return 1 ;;
    esac
}

# Should SSH be forwarded? Precedence: CLAUDE_FORWARD_SSH env > launcher.conf > off.
_ssh_forward_enabled() {
    if [[ -n "${CLAUDE_FORWARD_SSH:-}" ]]; then _is_truthy "$CLAUDE_FORWARD_SSH"; return; fi
    _is_truthy "$(_conf_get forward_ssh "$HOST_LAUNCHER_CONF")"
}

# Warn about unrecognized keys in launcher.conf. _conf_get's exact-match lookup
# silently no-ops on a typo -- most likely the env-var spelling (CLAUDE_FORWARD_SSH)
# used where the ini key (forward_ssh) belongs, since the sibling `env` file uses
# ALL_CAPS keys and it's an easy mix-up. Without this, forwarding just silently
# never turns on and there's no signal pointing at the config file as the cause.
_KNOWN_LAUNCHER_CONF_KEYS=" forward_ssh "
_conf_warn_unknown_keys() {  # _conf_warn_unknown_keys FILE
    local file="$1" line k
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"
        k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
        [[ -z "$k" ]] && continue
        if [[ "$_KNOWN_LAUNCHER_CONF_KEYS" != *" $k "* ]]; then
            echo ">> launcher.conf: unrecognized key '$k' (known keys: forward_ssh); ignored" >&2
        fi
    done < "$file"
}

# Is forwarding supported on this runtime+OS combo? apple (any mac), or Linux with
# docker/podman. NOT macOS Docker Desktop (the host-services bridge can't forward
# the 1Password agent). _cr_is_linux comes from the sourced container-runtime.sh.
_ssh_combo_supported() {
    [[ "$RUNTIME" == apple ]] && return 0
    _cr_is_linux && { [[ "$RUNTIME" == docker || "$RUNTIME" == podman ]]; }
}

# Resolve a signingkey-shaped value (literal ssh pubkey OR path to one) to a
# literal single-line ssh public key on stdout. Detects literals by algorithm
# prefix FIRST -- key bodies are base64 (contain '/'), so a path heuristic alone
# would misclassify a literal key as a file path. LABEL is used only in the
# warning message so callers (user.signingkey vs the container fallback key)
# get an actionable error. Returns 1 (message already printed) on any failure.
_resolve_ssh_pubkey_literal() {  # _resolve_ssh_pubkey_literal KEY LABEL
    local key="$1" label="$2" literal="$1" p
    case "$key" in
        ssh-*|ecdsa-*|sk-*|key::*) : ;;                 # literal pubkey; use verbatim
        /*|"~"*|./*|*/*)                                # looks like a path; inline the file
            p="$key"; [[ "$p" == "~"* ]] && p="${HOME}${p#\~}"
            if [[ -r "$p" ]]; then
                literal="$(cat "$p" 2>/dev/null || true)"
            else
                echo ">> $label '$key' is not a readable file; skipping signingkey graft." >&2
                return 1
            fi ;;
        *) : ;;                                         # unknown shape; validated below
    esac
    # Final literal must be a single-line ssh public key (guards multiline files,
    # accidental private-key paths, and garbage values -- which would emit an
    # invalid ~/.gitconfig or copy a secret into the stage dir).
    if [[ -z "$literal" || "$literal" == *$'\n'* ]] || \
       { [[ "$literal" != ssh-* && "$literal" != ecdsa-* && "$literal" != sk-* && "$literal" != key::* ]]; }; then
        echo ">> resolved $label is not a single-line ssh public key; skipping signingkey graft." >&2
        return 1
    fi
    printf '%s' "$literal"
}

# Resolve git identity + SSH signing FRESH from the host $PWD (honoring includeIf
# so personal-vs-work picks the right email/key) and emit a [user]/[gpg]/[commit]
# block to stdout. Written into the per-run stage dir each launch, never persisted
# -- the container always runs at /workspace, so a persisted identity would freeze
# to the first repo. Only SSH signing is supported in-container.
#
# Host signing key format decides the path:
#   - gpg.format=ssh         -> use user.signingkey verbatim (already works here).
#   - gpg.format unset/other -> a real gpg/x509 identity (e.g. a yubikey), which
#     can't be used in-container (no secret key, no smime). Fall back to
#     `claude-container.signingkey-ssh` if the user configured one -- a SEPARATE
#     ssh keypair dedicated to in-container signing. It is looked up via the SAME
#     `git -C "$PWD" config --get`, so it rides whatever `includeIf gitdir:` block
#     already selected the host identity: put it in the same personal/work
#     included file as the real signingkey and it travels with that identity.
#     Requires CLAUDE_FORWARD_SSH=1 (the private half must live in the host's
#     forwarded ssh-agent, never in the container). See README.md "Git & GitHub
#     inside the container".
_stage_git_identity() {
    local name email fmt key sign fallback literal=""
    name="$(git -C "$PWD" config --get user.name      2>/dev/null || true)"
    email="$(git -C "$PWD" config --get user.email     2>/dev/null || true)"
    fmt="$(git -C "$PWD" config --get gpg.format       2>/dev/null || true)"
    key="$(git -C "$PWD" config --get user.signingkey  2>/dev/null || true)"
    sign="$(git -C "$PWD" config --get --type=bool commit.gpgsign 2>/dev/null || true)"

    printf '[user]\n'
    [[ -n "$name" ]]  && printf '    name = %s\n'  "$name"
    [[ -n "$email" ]] && printf '    email = %s\n' "$email"

    if [[ -z "$key" ]]; then
        return 0   # no signing key host-side -> identity only.
    elif [[ "$fmt" == "ssh" ]]; then
        literal="$(_resolve_ssh_pubkey_literal "$key" "user.signingkey")" || return 0
    else
        fallback="$(git -C "$PWD" config --get claude-container.signingkey-ssh 2>/dev/null || true)"
        if [[ -z "$fallback" ]]; then
            echo ">> host git uses ${fmt:-openpgp} signing; only ssh signing works in-container, and no claude-container.signingkey-ssh fallback is configured. Skipping signingkey graft (name/email still applied)." >&2
            return 0
        fi
        echo ">> host git uses ${fmt:-openpgp} signing; using claude-container.signingkey-ssh fallback for in-container commit signing." >&2
        literal="$(_resolve_ssh_pubkey_literal "$fallback" "claude-container.signingkey-ssh")" || return 0
    fi

    # NEVER graft gpg.ssh.program: the host's 1Password op-ssh-sign path does not
    # exist in the container. Omitting it makes git use the container's own
    # `ssh-keygen -Y sign`, which signs via the forwarded agent.
    local gpgsign=false
    [[ "$sign" == true ]] && gpgsign=true
    printf '    signingkey = %s\n' "$literal"
    printf '[gpg]\n    format = ssh\n'
    printf '[commit]\n    gpgsign = %s\n' "$gpgsign"
}

# --print-runtime: report the resolved runtime + availability, then exit (no side effects).
if [[ "${1:-}" == "--print-runtime" ]]; then
    printf 'RUNTIME=%s\n' "$RUNTIME"
    for rt in apple docker podman; do
        if cr_available "$rt"; then printf 'available: %s\n' "$rt"; fi
    done
    exit 0
fi

# --print-paths: emit resolved paths and exit BEFORE any mutating side effect
# (mkdir, seeding, container run). Note cr_resolve already ran a read-only
# `docker info`/`podman info` probe above. Used by tests/test_launcher_paths.sh.
if [[ "${1:-}" == "--print-paths" ]]; then
    cat <<EOF
FLAVOR=$FLAVOR
CFG_DIR=$CFG_DIR
STATE_DIR=$STATE_DIR
STATE_CLAUDE_DIR=$STATE_CLAUDE_DIR
HOST_DOTCLAUDE=$HOST_DOTCLAUDE
PROJECT_KEY=$PROJECT_KEY
HOST_PROJECT_DIR=$HOST_PROJECT_DIR
CRED_GCLOUD_DIR=$CRED_GCLOUD_DIR
CRED_OKTA_DIR=$CRED_OKTA_DIR
HOST_ENV_FILE=$HOST_ENV_FILE
HOST_MOUNTS_FILE=$HOST_MOUNTS_FILE
HOST_SETTINGS=$HOST_SETTINGS
HOST_LAUNCHER_CONF=$HOST_LAUNCHER_CONF
IMAGE=$IMAGE
RUNTIME=$RUNTIME
EOF
    exit 0
fi
# ----------------------------------------------------------------------------

mkdir -p "$CFG_DIR" "$STATE_CLAUDE_DIR" "$HOST_PROJECT_DIR"
# One-time migration: the old sibling $STATE_DIR/claude.json moves inside the
# .claude dir mount (see HOST_DOTCLAUDE above). Only when the new path is absent,
# so a real file is never clobbered.
if [[ -f "$HOST_DOTCLAUDE_LEGACY" && ! -e "$HOST_DOTCLAUDE" ]]; then
    mv "$HOST_DOTCLAUDE_LEGACY" "$HOST_DOTCLAUDE"
fi
# Ensure it exists so the entrypoint's symlink target + prefill have a file.
[[ -e "$HOST_DOTCLAUDE" ]] || : > "$HOST_DOTCLAUDE"

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
        elif [[ "$FLAVOR" == vertex ]]; then
            cat <<'EOF'
# claude-vertex: model + region pins. Passed into the container via --env-file
# (overrides the image ENV). Confirm the exact model IDs are enabled in your
# project's Model Garden.
#
# ALL US per Vida compliance: Opus 4.8 + Sonnet 5 aren't served on single
# regions like us-east5 -- they need global/multi-region, so they ride the "us"
# multi-region below. Haiku 4.5 -> us-east5 (also US). Never route non-US.
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
fi
# Re-tighten every launch, not just on creation: a pre-existing env file left
# world/group-readable (a bad umask, a restore from a 644 backup) would otherwise
# keep leaking the MCP tokens it holds. Guarded so a missing file is a no-op.
[[ -f "$HOST_ENV_FILE" ]] && chmod 600 "$HOST_ENV_FILE"

# Ensure the flavor's credential directory exists (bind-mounted; see run_in_container).
if [[ "$FLAVOR" == vertex ]]; then
    mkdir -p "$CRED_GCLOUD_DIR"
else
    mkdir -p "$CRED_OKTA_DIR"
fi

run_in_container() {
    # Enforce a usable runtime + load its driver (rt_* functions) before any real
    # container operation. Only container ops reach here, so pure host-side
    # subcommands (migrate-memory, migrate-creds, --print-*) never require a runtime.
    if [[ "$RUNTIME" == none ]]; then
        echo "!! no usable container runtime found." >&2
        if [[ -n "${CLAUDE_RUNTIME:-}" ]]; then
            echo "   CLAUDE_RUNTIME=$CLAUDE_RUNTIME is not installed/functional on this host." >&2
        else
            echo "   install docker or podman (or Apple 'container' on macOS 26+ Apple Silicon)." >&2
        fi
        exit 1
    fi
    cr_load_driver "$RUNTIME"

    local extra_flags=()
    if [[ -t 0 && -t 1 ]]; then
        extra_flags+=(-it)
    fi
    # Per-run stage directory. Replaces what used to be four fragile single-file
    # bind mounts (settings override, host MCP creds, statusline, git identity).
    # Single-file mounts rot on Docker Desktop macOS across host sleep/wake; a
    # directory mount does not. We read each host source with a normal filesystem
    # read (no mount), snapshot the ones that exist into a fresh temp dir, and
    # mount THAT once ro at /opt/claude-stage; the entrypoint consumes them at
    # boot. mktemp per run avoids races between concurrent launches; the EXIT trap
    # removes it however the script ends -- normal exit, `set -e` abort, or a
    # Ctrl-C'd `docker run` (RETURN would miss the last two). run_in_container is
    # called at most once per invocation, so a single EXIT trap is sufficient.
    # Only files that exist are staged. STAGE is intentionally NOT `local`: the
    # EXIT trap runs in the script's global scope, where a function-local would be
    # out of scope (expanding to '' -> rm -rf '' -> no cleanup).
    # Sweep stage dirs orphaned by a prior crash: the EXIT trap below only removes
    # THIS run's dir, so a SIGKILL/OOM/host-crash strands earlier ones (each a
    # snapshot of host ~/.claude.json + git identity) under STATE_DIR forever. The
    # older-than-a-day threshold (-mtime +0) spares the fresh stage dir of any
    # concurrently-running sibling launch.
    find "$STATE_DIR" -maxdepth 1 -type d -name '.stage.*' -mtime +0 \
        -exec rm -rf {} + 2>/dev/null || true
    STAGE="$(mktemp -d "${STATE_DIR}/.stage.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    if [[ -f "$HOST_SETTINGS" ]]; then
        cp "$HOST_SETTINGS" "$STAGE/settings.override.json"
    fi
    if [[ -f "$HOME/.claude.json" ]]; then
        cp "$HOME/.claude.json" "$STAGE/host-claude.json"
    fi
    if [[ -f "$HOME/.claude/statusline-command.sh" ]]; then
        cp "$HOME/.claude/statusline-command.sh" "$STAGE/statusline.sh"
    fi
    # Git identity + SSH signing, resolved fresh from the host $PWD every launch
    # (honors includeIf). Always written so the entrypoint has a file to inline.
    _stage_git_identity > "$STAGE/gitconfig-identity"
    extra_flags+=(-v "$STAGE:/opt/claude-stage:ro")
    # GitHub token resolved from the host (gh stores it in the OS keyring by
    # default, so ~/.config/gh alone lacks it). Injected in-memory per run; never
    # written to disk. gh + its credential helper honor GH_TOKEN.
    if command -v gh >/dev/null 2>&1; then
        _gh_token="$(gh auth token 2>/dev/null || true)"
        [[ -n "$_gh_token" ]] && extra_flags+=(-e "GH_TOKEN=$_gh_token")
    fi
    # NOTE: SSH agent forwarding / host key mounting is intentionally NOT wired
    # here. It is being redesigned as a cross-platform (docker/podman/apple)
    # bring-your-own-provider feature. Until then, push over HTTPS (GH_TOKEN above).
    # (Host ~/.claude.json is staged as host-claude.json above so the entrypoint
    # can graft its mcpServers env/headers into the container's ~/.claude.json.)

    # Flavor-specific mounts.
    if [[ "$FLAVOR" == vertex ]]; then
        extra_flags+=(-v "$CRED_GCLOUD_DIR:/home/claude/.config/gcloud")
    else
        extra_flags+=(-v "$CRED_OKTA_DIR:/home/claude/.local/share/litellm")
    fi

    # Forward the reseed flag so the entrypoint force-overwrites the seeded
    # files (settings + plugins) instead of preserving existing ones.
    [[ -n "${CLAUDE_RESEED:-}" ]] && extra_flags+=(-e "CLAUDE_RESEED=1")

    # Optional extra bind mounts from $HOST_MOUNTS_FILE. Each approved host dir is
    # mounted at /mnt/approved/<basename> so Claude's native tools can reach it.
    # Read-only unless the line ends in ` :rw`. Missing dirs and basename
    # collisions are skipped with a warning so a stale entry never blocks launch.
    if [[ -f "$HOST_MOUNTS_FILE" ]]; then
        local seen_names=" "
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"                       # strip trailing comments
            line="${line#"${line%%[![:space:]]*}"}"  # ltrim
            line="${line%"${line##*[![:space:]]}"}"  # rtrim
            [[ -z "$line" ]] && continue
            local mode=ro path="$line"
            if [[ "$line" == *:rw ]]; then
                mode=rw
                path="${line%:rw}"
                path="${path%"${path##*[![:space:]]}"}"  # rtrim before :rw
            fi
            # Expand a leading ~ to $HOME.
            [[ "$path" == "~"* ]] && path="${HOME}${path#\~}"
            if [[ ! -d "$path" ]]; then
                echo ">> skip mount: not a directory: $path" >&2
                continue
            fi
            local name
            name="$(basename "$path")"
            if [[ "$seen_names" == *" $name "* ]]; then
                echo ">> skip mount: duplicate basename '$name' ($path)" >&2
                continue
            fi
            seen_names+="$name "
            extra_flags+=(-v "$path:/mnt/approved/$name:$mode")
        done < "$HOST_MOUNTS_FILE"
    fi

    # Driver-contributed run flags (userns / remap-skip), one token per line.
    local rt_flags=()
    while IFS= read -r _f; do [[ -n "$_f" ]] && rt_flags+=("$_f"); done < <(rt_run_flags)

    # SSH agent forwarding (opt-in). Toggle via CLAUDE_FORWARD_SSH env or the
    # launcher.conf `forward_ssh` key; only wired on supported combos. Driver
    # decides the flags (rt_ssh_flags); driver already loaded above (cr_load_driver).
    _conf_warn_unknown_keys "$HOST_LAUNCHER_CONF"
    local ssh_flags=()
    if _ssh_forward_enabled; then
        if _ssh_combo_supported; then
            while IFS= read -r _f; do [[ -n "$_f" ]] && ssh_flags+=("$_f"); done < <(rt_ssh_flags)
            if [[ ${#ssh_flags[@]} -eq 0 ]]; then
                echo ">> SSH forwarding enabled but SSH_AUTH_SOCK is unset (no agent running?); skipping." >&2
            fi
        else
            echo ">> SSH forwarding unsupported on $RUNTIME for this host; use apple \`container\` or push over HTTPS. Skipping." >&2
        fi
    fi

    rt_run --rm "${extra_flags[@]}" "${rt_flags[@]+"${rt_flags[@]}"}" \
        "${ssh_flags[@]+"${ssh_flags[@]}"}" \
        --env-file "$HOST_ENV_FILE" \
        -e "HOST_UID=$(id -u)" \
        -e "HOST_GID=$(id -g)" \
        -e "CLAUDE_HOST_DIR=$PWD" \
        -v "$PWD:/workspace" \
        -v "$STATE_CLAUDE_DIR:/home/claude/.claude" \
        -v "$HOST_PROJECT_DIR:/home/claude/.claude/projects/-workspace" \
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
                echo ">> done. credentials saved to $CRED_GCLOUD_DIR"
                ;;
            gateway)
                # Okta device-authorization login. The baked helper prints a
                # verification URL to stderr; approve it in your host browser.
                # --login-only populates the token cache without emitting a token.
                echo ">> Okta device login inside container (approve in your browser)"
                run_in_container /opt/claude/api-key-helper --login-only
                echo ">> done. token cache saved to $CRED_OKTA_DIR"
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
        echo ">> re-seeded $STATE_CLAUDE_DIR from image (settings + plugins overwritten)"
        ;;
    migrate-memory)
        # One-time: move the legacy shared bucket to THIS repo's per-project key.
        # Pure host-side (no container). Run from the repo that owns that history.
        # Refuses only if the target already holds data. The pre-feature bucket
        # lives INSIDE the ~/.claude mount ($STATE_CLAUDE_DIR/projects/-workspace), not at
        # the new sibling $STATE_DIR/projects/ location.
        #
        # NOTE: docker recreates $_legacy as an EMPTY mountpoint stub on every run,
        # because the per-repo bind mount nests at ~/.claude/projects/-workspace
        # (inside the $STATE_CLAUDE_DIR mount). So "-d" alone is not "has legacy
        # data" -- an empty stub is nothing to migrate. Treat empty as absent and
        # tidy the stub, else migrate would hit the target-non-empty refusal below.
        _legacy="$STATE_CLAUDE_DIR/projects/-workspace"
        if [[ ! -d "$_legacy" || -z "$(ls -A "$_legacy" 2>/dev/null)" ]]; then
            rmdir "$_legacy" 2>/dev/null || true
            echo ">> no legacy bucket at $_legacy; nothing to migrate"
            exit 0
        fi
        if [[ -d "$HOST_PROJECT_DIR" && -n "$(ls -A "$HOST_PROJECT_DIR" 2>/dev/null)" ]]; then
            echo ">> target exists and is non-empty: $HOST_PROJECT_DIR; refusing to overwrite" >&2
            exit 1
        fi
        # The launcher pre-creates an empty target above; remove it so mv renames
        # the legacy bucket into place instead of nesting it inside.
        rmdir "$HOST_PROJECT_DIR" 2>/dev/null || true
        mkdir -p "$(dirname "$HOST_PROJECT_DIR")"
        mv "$_legacy" "$HOST_PROJECT_DIR"
        echo ">> migrated $_legacy -> $HOST_PROJECT_DIR"
        ;;
    migrate-creds)
        # One-time: copy an old named docker/podman volume's contents into the new
        # bind dir. Requires the runtime CLI; apple never used volumes. No-op if
        # the volume is absent or the target already has data.
        _vol=""; _dir=""
        if [[ "$FLAVOR" == vertex ]]; then _vol="claude-vertex-gcloud"; _dir="$CRED_GCLOUD_DIR"; else _vol="claude-gateway-okta"; _dir="$CRED_OKTA_DIR"; fi
        mkdir -p "$_dir"
        if [[ -n "$(ls -A "$_dir" 2>/dev/null)" ]]; then
            echo ">> $_dir already populated; nothing to migrate"; exit 0
        fi
        _rtbin="$("$SCRIPT_DIR/container-runtime.sh" --resolve 2>/dev/null)"
        case "$_rtbin" in
            docker|podman) : ;;
            *) echo ">> migrate-creds needs docker or podman (got: $_rtbin)"; exit 1 ;;
        esac
        if ! "$_rtbin" volume inspect "$_vol" >/dev/null 2>&1; then
            echo ">> no volume $_vol; nothing to migrate"; exit 0
        fi
        "$_rtbin" run --rm -v "$_vol:/from:ro" -v "$_dir:/to" alpine \
            sh -c 'cp -a /from/. /to/ 2>/dev/null || true'
        echo ">> migrated volume $_vol -> $_dir"
        ;;
    rebuild-memory-index)
        # The entrypoint regenerates both memory indexes (project + global tier)
        # on every launch, so a no-op container run rebuilds them without starting
        # a session. Manual repair for a derived MEMORY.md.
        run_in_container true
        echo ">> rebuilt memory indexes for $PROJECT_KEY (project + global tier)"
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
