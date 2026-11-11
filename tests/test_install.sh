#!/usr/bin/env bash
# install.sh --dry-run planning. Fake uname/sw_vers/container on a stub-only PATH;
# asserts the printed PLAN without downloading, installing or symlinking anything.
cd "$(dirname "$0")"
source ./lib.sh
INSTALL="$(pwd)/../install.sh"
setup_host_tools

plan() {  # plan KEY=VAL ... [-- INSTALL_ARGS...]  (HAVE_APPLE, OSTYPE_STUB, ARCH_STUB, MACOS_MAJOR, CLAUDE_SKIP_APPLE_GATE, OLD_CLONE, OLD_CLONE_LINKS)
    local extra=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -- ]]; then shift; extra=("$@"); break; fi
        export "$1"; shift
    done
    local fakes home
    fakes="$(mktemp -d)"
    home="$(mktemp -d)"
    printf '#!/usr/bin/env bash\n[[ "$1" == "-m" ]] && { echo "%s"; exit 0; }\necho "%s"\n' "${ARCH_STUB:-arm64}" "${OSTYPE_STUB:-Linux}" > "$fakes/uname"
    printf '#!/usr/bin/env bash\necho "%s.0"\n' "${MACOS_MAJOR:-26}" > "$fakes/sw_vers"
    printf '#!/usr/bin/env bash\necho "NETWORK TOUCHED" >&2\nexit 1\n' > "$fakes/curl"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakes/container"
    chmod +x "$fakes"/*
    [[ "${HAVE_APPLE-}" == 1 ]] || rm -f "$fakes/container"
    [[ "${OLD_CLONE-}" == 1 ]] && mkdir -p "$home/.local/share/claude-container/src"
    # OLD_CLONE_LINKS: space-separated name=target pairs, as the bash installer
    # (or a user) left them in the bin dir; a literal $HOME is the fake home.
    local pair
    for pair in ${OLD_CLONE_LINKS-}; do
        mkdir -p "$home/.local/bin"
        local link_target="${pair#*=}"
        ln -s "${link_target//\$HOME/$home}" "$home/.local/bin/${pair%%=*}"
    done
    local bin_before
    bin_before="$(ls -lA "$home/.local/bin" 2>/dev/null)"
    env -u CLAUDE_RUNTIME HOME="$home" PATH="$fakes:$HOST_TOOLS" bash "$INSTALL" --dry-run "${extra[@]+"${extra[@]}"}" 2>&1
    echo "rc=$?"
    [[ "$(ls -lA "$home/.local/bin" 2>/dev/null)" == "$bin_before" ]] || echo "SIDE EFFECT in bin dir"
    rm -rf "$fakes" "$home"
    unset OSTYPE_STUB ARCH_STUB MACOS_MAJOR HAVE_APPLE CLAUDE_SKIP_APPLE_GATE OLD_CLONE OLD_CLONE_LINKS
}

# Linux/arm64: download, verify, install, symlink, update for the default flavor
out="$(plan OSTYPE_STUB=Linux ARCH_STUB=aarch64)"
assert_contains "$out" "PLAN download: claude-container_linux_arm64" "linux aarch64 maps to linux_arm64"
assert_contains "$out" "PLAN verify: SHA256SUMS"                     "dry-run plans checksum verify"
assert_contains "$out" "PLAN install: " "dry-run plans install"
assert_contains "$out" "/.local/bin/claude-container"                "install target is the default bin dir"
assert_contains "$out" "PLAN symlink: claude-personal -> claude-container" "dry-run plans relative symlink"
assert_contains "$out" "PLAN update: personal"                       "dry-run plans update"
assert_not_contains "$out" "NETWORK TOUCHED"                         "dry-run never calls curl"
assert_not_contains "$out" "SIDE EFFECT"                             "dry-run creates nothing"
assert_not_contains "$out" "APPLE GATE"                              "linux never apple-gates"

out="$(plan OSTYPE_STUB=Linux ARCH_STUB=x86_64 -- --bin-dir /opt/x/bin)"
assert_contains "$out" "PLAN download: claude-container_linux_amd64" "x86_64 maps to amd64"
assert_contains "$out" "PLAN install: /opt/x/bin/claude-container"   "--bin-dir is honored"

# --all lists every flavor
out="$(plan OSTYPE_STUB=Linux -- --all)"
for flavor in personal vertex gateway; do
    assert_contains "$out" "PLAN symlink: claude-$flavor -> claude-container" "--all symlinks $flavor"
    assert_contains "$out" "PLAN update: $flavor"                              "--all updates $flavor"
done

# unsupported platform
out="$(plan OSTYPE_STUB=FreeBSD)"
assert_contains "$out" "unsupported OS" "unknown OS is a clear error"
out="$(plan OSTYPE_STUB=Linux ARCH_STUB=riscv64)"
assert_contains "$out" "unsupported architecture" "unknown arch is a clear error"

# apple gate unchanged
out="$(plan OSTYPE_STUB=Darwin HAVE_APPLE=)"
assert_contains "$out" "APPLE GATE" "eligible mac w/o apple -> gate"
out="$(plan OSTYPE_STUB=Darwin HAVE_APPLE= -- --no-apple-gate)"
assert_not_contains "$out" "APPLE GATE" "--no-apple-gate proceeds"
assert_contains "$out" "PLAN download: claude-container_darwin_arm64" "mac arm64 maps to darwin_arm64"
out="$(plan OSTYPE_STUB=Darwin ARCH_STUB=x86_64 HAVE_APPLE=)"
assert_not_contains "$out" "APPLE GATE" "intel mac ineligible -> no gate"

# real gate exit code is 3
gate_home="$(mktemp -d)"; gate_fakes="$(mktemp -d)"
printf '#!/usr/bin/env bash\n[[ "$1" == "-m" ]] && { echo arm64; exit 0; }\necho Darwin\n' > "$gate_fakes/uname"
printf '#!/usr/bin/env bash\necho 26.0\n' > "$gate_fakes/sw_vers"
chmod +x "$gate_fakes"/*
rc=0; env HOME="$gate_home" PATH="$gate_fakes:$HOST_TOOLS" bash "$INSTALL" >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "apple gate exits 3"
rm -rf "$gate_home" "$gate_fakes"

# --local: no download, installs from the given path
out="$(plan OSTYPE_STUB=Linux -- --local /path/x)"
assert_not_contains "$out" "download" "--local does not download"
assert_contains "$out" "from /path/x" "--local installs from the given binary"
assert_contains "$out" "PLAN install: " "--local still plans install"

# old clone notice
out="$(plan OSTYPE_STUB=Linux OLD_CLONE=1)"
assert_contains "$out" "old clone at " "old clone is reported"
assert_contains "$out" "can be removed" "old clone is not deleted, just flagged"

# flavors linked into the old clone are relinked and updated, others left alone
old_launcher='$HOME/.local/share/claude-container/src/bin/claude-launcher.sh'
out="$(plan OSTYPE_STUB=Linux OLD_CLONE=1 "OLD_CLONE_LINKS=claude-vertex=$old_launcher claude-gateway=/elsewhere/claude claude-personal=$old_launcher")"
assert_contains "$out" "PLAN migrate: claude-vertex" "old-clone vertex link is migrated"
assert_contains "$out" "PLAN symlink: claude-vertex -> claude-container" "migrated vertex is relinked"
assert_contains "$out" "PLAN update: vertex" "migrated vertex is updated"
assert_not_contains "$out" "claude-gateway" "gateway linked elsewhere is left alone"
assert_eq "1" "$(grep -c 'PLAN symlink: claude-personal' <<<"$out")" "personal is planned once, not duplicated"
assert_not_contains "$out" "SIDE EFFECT" "migration dry-run touches nothing"

# runtime handling
out="$(plan OSTYPE_STUB=Linux)"
assert_contains "$out" "PLAN runtime: detect via claude-container --print-runtime" "dry-run defers runtime detection"
out="$(plan OSTYPE_STUB=Linux -- --runtime podman)"
assert_contains "$out" "runtime: podman" "--runtime is echoed"

# dropped flags
out="$(plan OSTYPE_STUB=Linux -- --prefix /x)"
assert_contains "$out" "unknown arg: --prefix" "--prefix is gone"

finish
