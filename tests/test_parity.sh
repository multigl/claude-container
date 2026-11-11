#!/usr/bin/env bash
# Parity suite: the launcher's container argv per scenario, normalized and
# compared with testdata/parity/<case>.args (one token per line). Run with
# PARITY_UPDATE=1 to (re)write the fixtures instead of comparing.
cd "$(dirname "$0")"
source ./lib.sh
FIXTURE_DIR="$(cd .. && pwd)/testdata/parity"

# normalize_argv STAGE PROJECT_KEY HOME PWD UID GID IMAGE < raw argv
normalize_argv() {
    local stage="$1" project_key="$2" home="$3" workdir="$4" uid="$5" gid="$6" image="$7"
    local line previous=""
    while IFS= read -r line; do
        if [[ "$previous" == "--env-file" ]]; then
            line="@ENVFILE@"
        fi
        previous="$line"
        line="${line//$stage/@STAGE@}"
        line="${line//$project_key/@PROJECT_KEY@}"
        line="${line//$home/@HOME@}"
        line="${line//$workdir/@PWD@}"
        line="${line//HOST_UID=$uid/HOST_UID=@UID@}"
        line="${line//HOST_GID=$gid/HOST_GID=@GID@}"
        line="${line//$image/@IMAGE@}"
        printf '%s\n' "$line"
    done
}

# run_case NAME FLAVOR RUNTIME [ENV=VAL ...] -- [LAUNCHER_ARGS...]
# Optional hooks: CASE_SETUP (function, called with HOME) and CASE_FAKES
# (function, called with the fake bin dir) run before the launch.
run_case() {
    local name="$1" flavor="$2" runtime="$3"; shift 3
    local -a env_pairs=() launcher_args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do env_pairs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    launcher_args=("$@")

    local root bin home workdir out runtime_binary os
    root="$(cd -P "$(mktemp -d)" && pwd)"
    bin="$root/bin"; home="$root/home"; workdir="$root/work"; out="$root/argv"
    mkdir -p "$bin" "$home/.config" "$home/.local/state" "$workdir"
    : > "$out"

    runtime_binary="$runtime"; [[ "$runtime" == apple ]] && runtime_binary="container"
    os=Linux; [[ "$runtime" == apple ]] && os=Darwin
    cat > "$bin/$runtime_binary" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in "info "*|"info"|"system status"|"system"*) exit 0 ;; esac
{ printf '%s\n' "\$(basename "\$0")"; for a in "\$@"; do printf '%s\n' "\$a"; done; } >> "$out"
exit 0
STUB
    cat > "$bin/uname" <<STUB
#!/usr/bin/env bash
case "\$1" in -m) echo arm64 ;; *) echo $os ;; esac
STUB
    printf '#!/usr/bin/env bash\necho 26.0\n' > "$bin/sw_vers"
    # Defaults so a real getenforce/gh on /usr/bin can't leak in; cases override.
    printf '#!/usr/bin/env bash\necho Disabled\n' > "$bin/getenforce"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/gh"
    chmod +x "$bin"/*
    [[ -n "${CASE_FAKES:-}" ]] && "$CASE_FAKES" "$bin"
    [[ -n "${CASE_SETUP:-}" ]] && "$CASE_SETUP" "$home"

    ln -s "$LAUNCHER" "$root/claude-$flavor"
    (
        cd "$workdir" || exit 1
        env -i HOME="$home" PATH="$bin:/usr/bin:/bin" \
            XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
            CLAUDE_RUNTIME="$runtime" "${env_pairs[@]}" \
            "$root/claude-$flavor" "${launcher_args[@]}" </dev/null >/dev/null 2>"$root/err"
    ) || true

    local project_key
    project_key="$(printf '%s' "$workdir" | sed 's#/#-#g')-$(printf '%s' "$workdir" | cksum | cut -d' ' -f1)"
    local stage_pattern="$home/.local/state/claude-container/$flavor/.stage."
    # Stage dir name has a random suffix; collapse it to the bare directory first.
    sed -E "s#${stage_pattern//./\\.}[A-Za-z0-9]+#${stage_pattern}STAGE#" "$out" \
        | normalize_argv "${stage_pattern}STAGE" "$project_key" "$home" "$workdir" \
            "$(id -u)" "$(id -g)" "ghcr.io/multigl/claude-container:$flavor-latest" \
        > "$root/normalized"

    if [[ -n "${PARITY_UPDATE:-}" ]]; then
        mkdir -p "$FIXTURE_DIR"
        cp "$root/normalized" "$FIXTURE_DIR/$name.args"
        printf '  wrote: %s.args\n' "$name"
    else
        assert_eq "$(cat "$FIXTURE_DIR/$name.args" 2>/dev/null)" "$(cat "$root/normalized")" "$name argv"
    fi
    rm -rf "$root"
}

fake_gh() { printf '#!/usr/bin/env bash\necho tok123\n' > "$1/gh"; chmod +x "$1/gh"; }
fake_getenforce() { printf '#!/usr/bin/env bash\necho Enforcing\n' > "$1/getenforce"; chmod +x "$1/getenforce"; }
setup_mounts() {
    local home="$1" config_dir="$1/.config/claude-container/personal"
    mkdir -p "$home/extra-ro" "$home/extra-rw" "$config_dir"
    printf '%s\n%s :rw\n' "$home/extra-ro" "$home/extra-rw" > "$config_dir/mounts"
}

for flavor in personal vertex gateway; do
    for runtime in docker podman apple; do
        run_case "$flavor-$runtime" "$flavor" "$runtime"
    done
done

for runtime in docker podman apple; do
    run_case "personal-$runtime-ssh" personal "$runtime" \
        CLAUDE_FORWARD_SSH=1 SSH_AUTH_SOCK=/tmp/agent.sock
done

run_case personal-docker-dns personal docker CLAUDE_DNS=1.1.1.1,8.8.8.8
CASE_FAKES=fake_gh run_case personal-docker-ghtoken personal docker
run_case personal-docker-reseed personal docker CLAUDE_RESEED=1
CASE_SETUP=setup_mounts run_case personal-docker-mounts personal docker
CASE_FAKES=fake_getenforce run_case personal-podman-selinux personal podman
run_case personal-docker-shell personal docker -- shell -c true
run_case vertex-docker-auth vertex docker -- auth

finish
