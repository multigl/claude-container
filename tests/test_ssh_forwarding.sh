#!/usr/bin/env bash
# Launcher SSH-forwarding gate matrix. Drives bin/claude-launcher.sh with a
# recording runtime stub that captures the run argv, plus stubbed `uname` so the
# OS gate is deterministic regardless of the host running the tests.
cd "$(dirname "$0")"
source ./lib.sh
LAUNCHER="$(pwd)/../bin/claude-launcher.sh"

# run_ssh OS RUNTIME HOME [ENV=VAL ...] -> echoes the recorded run argv.
# Stubs: `docker`/`container` (record argv), `uname` (report OS/-m arm64),
# `sw_vers` (report macOS 26 for apple). SSH_AUTH_SOCK defaults set by caller.
run_ssh() {
    local os="$1" runtime="$2" home="$3"; shift 3
    local bin rec; bin="$(mktemp -d)"; rec="$(mktemp -d)"
    # runtime binary stub (docker or container): records argv, no-ops info/status.
    local rtbin="$runtime"; [[ "$runtime" == apple ]] && rtbin="container"
    cat > "$bin/$rtbin" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in "info "*|"info"|"system status"|"system"*) exit 0 ;; esac
{ for a in "\$@"; do printf '%s\n' "\$a"; done; } > "$rec/argv"
exit 0
STUB
    chmod +x "$bin/$rtbin"
    # uname stub: -s -> OS, -m -> arm64 (needed for apple eligibility).
    cat > "$bin/uname" <<STUB
#!/usr/bin/env bash
case "\$1" in -s) echo "$os" ;; -m) echo arm64 ;; *) echo "$os" ;; esac
STUB
    chmod +x "$bin/uname"
    printf '#!/usr/bin/env bash\necho 26.0\n' > "$bin/sw_vers"; chmod +x "$bin/sw_vers"
    env -i HOME="$home" PATH="$bin:/usr/bin:/bin" CLAUDE_FLAVOR=vertex \
        CLAUDE_RUNTIME="$runtime" "$@" \
        bash "$LAUNCHER" </dev/null >/dev/null 2>"$rec/err" || true
    cat "$rec/argv" 2>/dev/null
    cat "$rec/err" 2>/dev/null
    rm -rf "$bin" "$rec"
}

# --- toggle OFF (default) -> no ssh flags ---
h="$(mktemp -d)"; mkdir -p "$h/.config/vida-claude-container/vertex"
argv="$(run_ssh Linux docker "$h" SSH_AUTH_SOCK=/tmp/a.sock)"
assert_not_contains "$argv" "/ssh-agent" "toggle off: no socket bind"
assert_contains "$argv" "claude-vertex:latest" "toggle off: launcher reached rt_run"
rm -rf "$h"

# --- env override ON, linux+docker -> socket flags ---
h="$(mktemp -d)"; mkdir -p "$h/.config/vida-claude-container/vertex"
argv="$(run_ssh Linux docker "$h" CLAUDE_FORWARD_SSH=1 SSH_AUTH_SOCK=/tmp/a.sock)"
assert_contains "$argv" "/tmp/a.sock:/ssh-agent"   "env on linux+docker: socket bound"
assert_contains "$argv" "SSH_AUTH_SOCK=/ssh-agent" "env on linux+docker: container SSH_AUTH_SOCK set"
rm -rf "$h"

# --- enabled + supported but no agent socket -> warn + skip (no socket flags) ---
h="$(mktemp -d)"; mkdir -p "$h/.config/vida-claude-container/vertex"
argv="$(run_ssh Linux docker "$h" CLAUDE_FORWARD_SSH=1)"
assert_not_contains "$argv" "/ssh-agent"                        "no-agent: no socket bind"
assert_contains "$argv" "SSH_AUTH_SOCK is unset"               "no-agent: warns it was skipped"
assert_contains "$argv" "claude-vertex:latest"                 "no-agent: launcher reached rt_run"
rm -rf "$h"

# --- env override ON, linux+podman -> socket flags ---
h="$(mktemp -d)"; mkdir -p "$h/.config/vida-claude-container/vertex"
argv="$(run_ssh Linux podman "$h" CLAUDE_FORWARD_SSH=1 SSH_AUTH_SOCK=/tmp/a.sock)"
assert_contains "$argv" "/tmp/a.sock:/ssh-agent" "linux+podman: socket bound"
assert_contains "$argv" "claude-vertex:latest"   "linux+podman: launcher reached rt_run"
rm -rf "$h"

# --- launcher.conf forward_ssh=true, linux+docker -> socket flags ---
h="$(mktemp -d)"; cfg="$h/.config/vida-claude-container/vertex"; mkdir -p "$cfg"
printf '# comment\nforward_ssh = true\n' > "$cfg/launcher.conf"
argv="$(run_ssh Linux docker "$h" SSH_AUTH_SOCK=/tmp/a.sock)"
assert_contains "$argv" "/tmp/a.sock:/ssh-agent" "conf forward_ssh=true: socket bound"
rm -rf "$h"

# --- env=0 overrides conf=true -> off ---
h="$(mktemp -d)"; cfg="$h/.config/vida-claude-container/vertex"; mkdir -p "$cfg"
printf 'forward_ssh = true\n' > "$cfg/launcher.conf"
argv="$(run_ssh Linux docker "$h" CLAUDE_FORWARD_SSH=0 SSH_AUTH_SOCK=/tmp/a.sock)"
assert_not_contains "$argv" "/ssh-agent" "env=0 overrides conf=true"
assert_contains "$argv" "claude-vertex:latest" "env=0 overrides conf=true: launcher reached rt_run"
rm -rf "$h"

# --- Darwin + docker (unsupported) -> warn + skip (no socket flags) ---
h="$(mktemp -d)"; mkdir -p "$h/.config/vida-claude-container/vertex"
argv="$(run_ssh Darwin docker "$h" CLAUDE_FORWARD_SSH=1 SSH_AUTH_SOCK=/tmp/a.sock)"
assert_not_contains "$argv" "/ssh-agent" "darwin+docker: unsupported, no socket bind"
assert_contains "$argv" "claude-vertex:latest" "darwin+docker: launcher reached rt_run"
assert_contains "$argv" "SSH forwarding unsupported" "darwin+docker: warns on skip"
rm -rf "$h"

# --- apple -> --ssh flag present ---
h="$(mktemp -d)"; mkdir -p "$h/.config/vida-claude-container/vertex"
argv="$(run_ssh Darwin apple "$h" CLAUDE_FORWARD_SSH=1 SSH_AUTH_SOCK=/tmp/a.sock)"
assert_contains "$argv" "--ssh" "apple: --ssh forwarded"
rm -rf "$h"

finish
