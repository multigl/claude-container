#!/usr/bin/env bash
# Per-launch git identity + SSH signing graft. Drives the launcher with a `git`
# stub returning canned `config --get` values and a recording runtime stub that
# copies the staged gitconfig-identity out for inspection.
cd "$(dirname "$0")"
source ./lib.sh
LAUNCHER="$(pwd)/../bin/claude-launcher.sh"

# graft HOME [ENV=VAL ...] -> echoes the staged gitconfig-identity contents.
# STUB_* env vars feed the git stub: STUB_NAME STUB_EMAIL STUB_FMT STUB_KEY
# STUB_SIGN STUB_FALLBACK (claude-container.signingkey-ssh).
graft() {
    local home="$1"; shift
    local bin rec; bin="$(mktemp -d)"; rec="$(mktemp -d)"
    # git stub: last arg is the requested key; echo the matching STUB_* value.
    cat > "$bin/git" <<'STUB'
#!/usr/bin/env bash
key="${@: -1}"
case "$key" in
  user.name)       printf '%s\n' "${STUB_NAME:-}" ;;
  user.email)      printf '%s\n' "${STUB_EMAIL:-}" ;;
  gpg.format)      printf '%s\n' "${STUB_FMT:-}" ;;
  user.signingkey) printf '%s\n' "${STUB_KEY:-}" ;;
  commit.gpgsign)  printf '%s\n' "${STUB_SIGN:-}" ;;
  claude-container.signingkey-ssh) printf '%s\n' "${STUB_FALLBACK:-}" ;;
esac
exit 0
STUB
    chmod +x "$bin/git"
    # docker stub: record + copy staged identity out.
    cat > "$bin/docker" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in "info "*|"info") exit 0 ;; esac
for a in "\$@"; do
  case "\$a" in *:/opt/claude-stage:ro) cp "\${a%:/opt/claude-stage:ro}/gitconfig-identity" "$rec/identity" 2>/dev/null ;; esac
done
exit 0
STUB
    chmod +x "$bin/docker"
    env -i HOME="$home" PATH="$bin:/usr/bin:/bin" \
        CLAUDE_FLAVOR=vertex CLAUDE_RUNTIME=docker "$@" \
        bash "$LAUNCHER" </dev/null >/dev/null 2>&1 || true
    cat "$rec/identity" 2>/dev/null
    rm -rf "$bin" "$rec"
}

mkcfg() { local h; h="$(mktemp -d)"; mkdir -p "$h/.config/vida-claude-container/vertex"; printf '%s' "$h"; }

# --- name/email only, no signing key ---
h="$(mkcfg)"
id="$(graft "$h" STUB_NAME="Ada L" STUB_EMAIL="ada@x.io")"
assert_contains "$id" "name = Ada L"      "identity: name grafted"
assert_contains "$id" "email = ada@x.io"  "identity: email grafted"
assert_not_contains "$id" "signingkey"    "identity: no signingkey when none set"
rm -rf "$h"

# --- ssh signing: literal key -> full signing block, no gpg.ssh.program ---
h="$(mkcfg)"
id="$(graft "$h" STUB_NAME=A STUB_EMAIL=a@b STUB_FMT=ssh STUB_KEY="ssh-ed25519 AAAAKEY" STUB_SIGN=true)"
assert_contains "$id" "signingkey = ssh-ed25519 AAAAKEY" "ssh sign: literal key grafted"
assert_contains "$id" "format = ssh"     "ssh sign: gpg format ssh"
assert_contains "$id" "gpgsign = true"   "ssh sign: gpgsign true from host"
assert_not_contains "$id" "gpg.ssh.program" "ssh sign: never grafts gpg.ssh.program"
assert_not_contains "$id" "program"         "ssh sign: no program directive at all"
rm -rf "$h"

# --- ssh signing: literal key body contains '/' (base64) -> stays literal, not a path ---
h="$(mkcfg)"
id="$(graft "$h" STUB_NAME=A STUB_EMAIL=a@b STUB_FMT=ssh STUB_KEY="ssh-ed25519 AAAAB3Nz/aC1lZ+DI/25 user@host" STUB_SIGN=true)"
assert_contains "$id" "signingkey = ssh-ed25519 AAAAB3Nz/aC1lZ+DI/25 user@host" "slash-in-key: treated as literal, not path"
assert_contains "$id" "format = ssh" "slash-in-key: signing block emitted"
rm -rf "$h"

# --- openpgp signing -> alert + skip signing block (name/email stay) ---
h="$(mkcfg)"
id="$(graft "$h" STUB_NAME=A STUB_EMAIL=a@b STUB_FMT= STUB_KEY="ABCD1234")"
assert_contains "$id" "email = a@b"    "openpgp: identity still applied"
assert_not_contains "$id" "format = ssh" "openpgp: no ssh signing block"
assert_not_contains "$id" "signingkey"   "openpgp: signingkey skipped"
rm -rf "$h"

# --- x509 signing -> skip signing block ---
h="$(mkcfg)"
id="$(graft "$h" STUB_NAME=A STUB_EMAIL=a@b STUB_FMT=x509 STUB_KEY="cn=whoever")"
assert_not_contains "$id" "format = ssh" "x509: no ssh signing block"
rm -rf "$h"

# --- gpg signing + claude-container.signingkey-ssh fallback configured -> use fallback ---
h="$(mkcfg)"
id="$(graft "$h" STUB_NAME=A STUB_EMAIL=a@b STUB_FMT= STUB_KEY="ABCD1234" STUB_FALLBACK="ssh-ed25519 AAAAFALLBACK" STUB_SIGN=true)"
assert_contains "$id" "signingkey = ssh-ed25519 AAAAFALLBACK" "gpg+fallback: fallback ssh key grafted"
assert_contains "$id" "format = ssh"   "gpg+fallback: ssh signing block emitted"
assert_contains "$id" "gpgsign = true" "gpg+fallback: gpgsign from host commit.gpgsign"
rm -rf "$h"

# --- gpg signing + unreadable fallback path -> skip signing block, identity kept ---
h="$(mkcfg)"
id="$(graft "$h" STUB_NAME=A STUB_EMAIL=a@b STUB_FMT= STUB_KEY="ABCD1234" STUB_FALLBACK="/nope/missing.pub")"
assert_not_contains "$id" "format = ssh" "gpg+bad fallback: no ssh signing block"
assert_contains "$id" "email = a@b"     "gpg+bad fallback: identity still applied"
rm -rf "$h"

# --- ssh signing: key given as a readable file path -> literal inlined ---
h="$(mkcfg)"
keyfile="$(mktemp)"; printf 'ssh-ed25519 AAAAFROMFILE comment\n' > "$keyfile"
id="$(graft "$h" STUB_NAME=A STUB_EMAIL=a@b STUB_FMT=ssh STUB_KEY="$keyfile" STUB_SIGN=false)"
assert_contains "$id" "signingkey = ssh-ed25519 AAAAFROMFILE" "path key: literal inlined from file"
assert_contains "$id" "gpgsign = false" "path key: gpgsign false from host"
rm -f "$keyfile"; rm -rf "$h"

# --- ssh signing: key is an unreadable path -> skip signing block ---
h="$(mkcfg)"
id="$(graft "$h" STUB_NAME=A STUB_EMAIL=a@b STUB_FMT=ssh STUB_KEY="/nope/missing.pub")"
assert_not_contains "$id" "format = ssh"  "unreadable path key: no ssh signing block"
assert_contains "$id" "email = a@b"       "unreadable path key: identity still applied"
rm -rf "$h"

finish
