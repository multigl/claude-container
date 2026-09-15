#!/usr/bin/env bash
# Launcher DNS override: CLAUDE_DNS env / launcher.conf `dns` key -> `--dns IP`
# run flags. Same recording-runtime-stub harness as test_ssh_forwarding.sh.
cd "$(dirname "$0")"
source ./lib.sh
LAUNCHER="$(pwd)/../bin/claude-launcher.sh"

# run_dns RUNTIME HOME [ENV=VAL ...] -> echoes the recorded run argv, then stderr.
run_dns() {
    local runtime="$1" home="$2"; shift 2
    local bin rec; bin="$(mktemp -d)"; rec="$(mktemp -d)"
    local rtbin="$runtime"; [[ "$runtime" == apple ]] && rtbin="container"
    cat > "$bin/$rtbin" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in "info "*|"info"|"system status"|"system"*) exit 0 ;; esac
{ for a in "\$@"; do printf '%s\n' "\$a"; done; } > "$rec/argv"
exit 0
STUB
    chmod +x "$bin/$rtbin"
    cat > "$bin/uname" <<'STUB'
#!/usr/bin/env bash
case "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac
STUB
    chmod +x "$bin/uname"
    printf '#!/usr/bin/env bash\necho 26.0\n' > "$bin/sw_vers"; chmod +x "$bin/sw_vers"
    env -i HOME="$home" PATH="$bin:/usr/bin:/bin" CLAUDE_FLAVOR=personal \
        CLAUDE_RUNTIME="$runtime" "$@" \
        bash "$LAUNCHER" </dev/null >/dev/null 2>"$rec/err" || true
    cat "$rec/argv" 2>/dev/null
    cat "$rec/err" 2>/dev/null
    rm -rf "$bin" "$rec"
}

new_home() {
    local h; h="$(mktemp -d)"; mkdir -p "$h/.config/claude-container/personal"
    printf '%s' "$h"
}

# --- unset -> no --dns ---
h="$(new_home)"
argv="$(run_dns apple "$h")"
assert_not_contains "$argv" "--dns" "unset: no --dns flag"
assert_contains "$argv" "claude-personal:latest" "unset: launcher reached rt_run"
rm -rf "$h"

# --- env, one server ---
h="$(new_home)"
argv="$(run_dns apple "$h" CLAUDE_DNS=1.1.1.1)"
assert_contains "$argv" $'--dns\n1.1.1.1' "env single: --dns 1.1.1.1 as separate tokens"
rm -rf "$h"

# --- conf, comma + space separated list incl. IPv6 ---
h="$(new_home)"
printf '# work laptop: vmnet DNS forwarder is broken under Zscaler\ndns = 1.1.1.1, 8.8.8.8 2606:4700:4700::1111\n' \
    > "$h/.config/claude-container/personal/launcher.conf"
argv="$(run_dns docker "$h")"
assert_contains "$argv" $'--dns\n1.1.1.1' "conf list: first server"
assert_contains "$argv" $'--dns\n8.8.8.8' "conf list: second server"
assert_contains "$argv" $'--dns\n2606:4700:4700::1111' "conf list: ipv6 server"
assert_not_contains "$argv" "unrecognized key 'dns'" "conf list: dns is a known key"
rm -rf "$h"

# --- env overrides conf; empty env does not clear conf ---
h="$(new_home)"
printf 'dns = 8.8.8.8\n' > "$h/.config/claude-container/personal/launcher.conf"
argv="$(run_dns podman "$h" CLAUDE_DNS=9.9.9.9)"
assert_contains "$argv" $'--dns\n9.9.9.9' "env overrides conf: env server used"
assert_not_contains "$argv" "8.8.8.8" "env overrides conf: conf server dropped"
rm -rf "$h"

# --- non-IP token -> warned and skipped, never passed as a flag ---
h="$(new_home)"
argv="$(run_dns apple "$h" CLAUDE_DNS='1.1.1.1 --privileged')"
assert_contains "$argv" $'--dns\n1.1.1.1' "bad token: valid server still passed"
assert_not_contains "$argv" $'\n--privileged' "bad token: not passed through"
assert_contains "$argv" "not an IP address" "bad token: warns"
rm -rf "$h"

finish
