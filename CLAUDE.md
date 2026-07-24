# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

A **containerized Claude Code** distribution. It builds Claude Code into a Docker
image and runs it against a non-Anthropic-API backend, isolated from the host's
own `claude`, gcloud, and shell config. Two **flavors** build from one repo:

| Flavor    | Routes through          | Auth                                    |
|-----------|-------------------------|-----------------------------------------|
| `vertex`  | Vertex AI               | gcloud ADC (`CLAUDE_CODE_USE_VERTEX=1`) |
| `gateway` | an LLM gateway (LiteLLM)| baked Okta `apiKeyHelper` + `ANTHROPIC_BASE_URL` |

The host's regular `claude` (public Anthropic API) is never touched; each flavor
keeps its own state under `~/.local/state/vida-claude-container/<flavor>/claude/`.

## Architecture

Multi-stage `Containerfile`:

```
base ─┬─► vertex    (adds google-cloud-cli + Vertex ENV)
      └─► gateway   (adds ANTHROPIC_BASE_URL + Okta apiKeyHelper, no gcloud)
```

`base` holds everything shared (node, claude-code, uv + mcp-atlassian, the plugin
seed, the non-root `claude` user, the entrypoint). Build a flavor with
`docker build --target <flavor>`. The host wrapper `bin/claude-launcher.sh` is
symlinked to `claude-vertex` / `claude-gateway` and picks its flavor from the name
it was invoked as (override with `CLAUDE_FLAVOR=...`).

## Container runtime

The image runs under one of three container runtimes, chosen by a dispatcher —
`bin/container-runtime.sh` — that sources one driver from
`bin/runtimes/{docker,podman,apple}.sh`. Both `bin/claude-launcher.sh` and the
`just` build recipes route container ops through it (`container-runtime.sh
--resolve` / `build …`), so there is one detection path.

- **Priority: apple > docker > podman.** "Available" = installed **and** functional:
  `docker info` / `podman info` succeed; apple = eligible host (Apple Silicon,
  macOS 26+) **and** `container system status` succeeds. Platform gating: Linux
  considers {docker, podman}; macOS considers {apple, docker, podman}.
- **Override:** `CLAUDE_RUNTIME=docker|podman|apple` (errors if that runtime isn't
  available). Debug: `claude-<flavor> --print-runtime` prints the resolved runtime +
  per-runtime availability; `--print-paths` now includes a `RUNTIME=` line.
- **docker** (rootful Linux / Docker Desktop): unchanged — HOST_UID/HOST_GID remap
  in the entrypoint.
- **podman** (rootless Linux): passes `--userns=keep-id:uid=1000,gid=1000` to map
  the host user onto the image's `claude` (uid 1000), plus an internal
  `_CLAUDE_UID_REMAP=skip` so the entrypoint skips its usermod/chown remap. On
  SELinux-enforcing hosts it adds `--security-opt label=disable` (chosen over
  per-mount `:z` relabeling, which would relabel shared host dirs like `~/.claude`).
  `_CLAUDE_UID_REMAP` is internal — per-run `-e` only, never in the env file.
- **apple `container`** (macOS 26+ on Apple Silicon only; v1.1.0, stable): its VM
  bind-mount file share **passes host UIDs through** (unlike Docker Desktop's
  uid-agnostic gRPC-FUSE), so apple uses the **same `HOST_UID` remap path as
  docker** — no userns flag, no `_CLAUDE_UID_REMAP=skip`. The usermod remap is
  load-bearing here: with `claude` remapped to the host uid, in-container ownership
  matches what the share presents and the seed rsync never attempts chown/chgrp;
  skipping it (claude left at 1000) makes rsync try to fix the mismatch and abort
  (EPERM). Separately, the share **rejects the `chown`/`utimensat` syscalls on the
  mount regardless of uid**, so the entrypoint's explicit mount chowns are
  best-effort (`… 2>/dev/null || true`) and the seed rsync drops time preservation
  (`--no-times --omit-dir-times`).

`just doctor` has a `== runtime ==` section (resolved runtime + availability).
`just build`/`build-vertex`/`build-gateway`/`update`/`rebuild-*` all route through
the dispatcher (`container-runtime.sh build ... --no-cache` for the `rebuild-*`
variants) — no recipe hardcodes a runtime binary. (Previously the four `rebuild-*`
recipes hardcoded `docker build`, silently writing to the wrong runtime's image
store on multi-runtime hosts where a lower-priority runtime like docker was also
installed; fixed by threading `NO_CACHE` through the dispatcher the same way
`CLAUDE_CODE_VERSION` already was.)

### Installer (`install.sh`)

`curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash`.
Detects OS/arch, resolves a runtime, applies a macOS **apple gate** (on an
Apple-Silicon macOS 26+ host without Apple `container` installed it stops and tells
you to install it + re-run; skip with `--no-apple-gate` or
`CLAUDE_SKIP_APPLE_GATE=1`; ineligible hosts fall through to docker/podman), clones
the repo, builds the image(s) via the dispatcher, and symlinks `claude-<flavor>`
into `~/.local/bin`. Flags: `--local` (skip clone; used by `just install`), `--all`,
`--flavor`, `--runtime`, `--no-apple-gate`, `--prefix`, `--bin-dir`, `--ref`,
`--dry-run`. `just install` = `install.sh --local --flavor <flavor>`;
`just install-all` = `install.sh --local --all`.

## Key files

- `Containerfile` — multi-stage build (`base`, `vertex`, `gateway`).
- `bin/container-runtime.sh` — runtime dispatcher; detects a runtime (apple >
  docker > podman) + sources one driver from `bin/runtimes/`. See "Container runtime".
- `bin/runtimes/{docker,podman,apple}.sh` — per-runtime drivers (run/build flags).
- `install.sh` — `curl … | bash` installer (also backs `just install`); see below.
- `bin/claude-launcher.sh` — host wrapper; resolves the runtime, assembles the
  `<runtime> run` (mounts, env, cred bind dirs) and dispatches subcommands (`auth`,
  `shell`, `reseed`, `migrate-creds`, `--`).
- `bin/docker-entrypoint.sh` — runs as root to chown bind mounts + remap `claude` to
  the host UID/GID, seeds `~/.claude`, grafts MCP config/creds, then drops to
  `claude` via `gosu`.
- `bin/statusline.sh` — default statusline (baked at `/opt/claude/statusline.sh`;
  a host `~/.claude/statusline-command.sh` overrides it via the per-run stage dir,
  copied over the default at boot — see "Stage directory").
- `justfile` — build / install / auth / run / doctor / **update** recipes.
- `seed-common/` — flavor-neutral seed payload (incl. `dotclaude.json` with the
  atlassian + context7 `mcpServers`); overlaid per flavor by `seed-{vertex,gateway}/`.
- `seed-{vertex,gateway}/settings.json` — flavor `settings.json` (plugins, theme,
  statusline; gateway also sets `apiKeyHelper`).
- `gateway/okta_token_helper.py` — the gateway `apiKeyHelper` (Okta OIDC id_token);
  tested by `tests/test_okta_token_helper.py`.

## Common workflows

`just` recipes default to `FLAVOR=vertex`; prefix `FLAVOR=gateway` to target the
gateway flavor.

- `just build` / `build-vertex` / `build-gateway` / `build-all` — build image(s).
- `just rebuild[-*]` — no-cache rebuild.
- `just update` — **rebuild pinned to the latest published claude-code** (see below).
- `just install-all` — symlink `claude-vertex` + `claude-gateway` onto PATH.
- `just auth` — one-time login (vertex: gcloud ADC; `FLAVOR=gateway just auth`:
  Okta device login).
- `just run` / `shell` / `reseed` / `doctor` — run claude / bash / re-seed config /
  self-check.
- `just test` — runs `uv run pytest -q` (the gateway Okta helper) **and** the
  plain-bash suites in `tests/` (`test_merge_settings.sh`, `test_launcher_paths.sh`,
  via `tests/run.sh`). No Docker required.

## How config seeding works

On first launch `docker-entrypoint.sh` copies `/opt/claude-seed` → `~/.claude`
(the host `~/.local/state/vida-claude-container/<flavor>/claude` bind mount) with
`rsync --ignore-existing`, so user
edits survive. `CLAUDE_RESEED=1` (via `just reseed`) instead overwrites the seeded
files (settings + plugins) while preserving history/projects. The `mcpServers`
block is force-synced from the seed each launch, then `env`/`headers` creds are
grafted from the host `~/.claude.json` (staged read-only at
`/opt/claude-stage/host-claude.json`; see "Stage directory" below).

The container's own `~/.claude.json` (trust/onboarding flags, `mcpServers`, grafted
creds) is stored at `…/<flavor>/claude/claude.json` — inside the `~/.claude` dir
mount — and the entrypoint symlinks `~/.claude.json` to it. It is **not** a
credential store in these flavors (vertex uses gcloud ADC, gateway the Okta
apiKeyHelper); a future `/login` OAuth flavor would change that. Old installs with
a sibling `…/<flavor>/claude.json` are auto-migrated into `claude/` on next launch.

### Stage directory (no single-file bind mounts)

Single-file bind mounts rot on Docker Desktop macOS (virtio-fs/gRPC-FUSE goes
stale across host sleep/wake), so the launcher never mounts individual files. Each
launch it assembles a per-run temp dir (`mktemp -d "$STATE_DIR/.stage.XXXXXX"`,
removed on exit) by plain host-side `cp` of whichever inputs exist —
`settings.override.json`, the host `~/.claude.json` (as `host-claude.json`), the
host `~/.claude/statusline-command.sh` (as `statusline.sh`), and the git identity
(as `gitconfig-identity`) — and mounts that dir **once** ro at `/opt/claude-stage`.
The entrypoint consumes them at boot: merges the override, grafts MCP creds,
inlines the git identity once, and copies the statusline over the baked default at
`/opt/claude/statusline.sh` (it executes on every render, so it can't stay a
mount). Host reads happen on the normal filesystem, so mount staleness can't reach
them.

The `env` file is seeded per-flavor **only when absent** (not by `reseed`), with
real values, not blanks. The **vertex** flavor seeds model + region pins
(`ANTHROPIC_MODEL=claude-opus-4-8[1m]`, `…_SONNET_MODEL=claude-sonnet-5`,
`…_HAIKU_MODEL=claude-haiku-4-5`, `CLOUD_ML_REGION=us`,
`VERTEX_REGION_CLAUDE_HAIKU_4_5=us-east5`). All US (Vida compliance): opus/sonnet
on the `us` multi-region, haiku on `us-east5`. Pinning is load-bearing — unpinned,
the Vertex small/fast model defaults to `claude-sonnet-4-5` (429s if unprovisioned;
powers background titles + web-search summarization) and the 1M window is lost
(`[1m]` suffix; Sonnet 5 is always 1M). Existing installs hand-add these to the
live env file — `reseed` won't rewrite it. Env is read once at container start, so
an edit needs a session kill+reopen.

Host-side wrapper files live in an XDG split (namespace `vida-claude-container`):
config the user hand-edits under `$XDG_CONFIG_HOME/vida-claude-container/<flavor>/`
(`env`, `mounts`, `launcher.conf`, `settings.override.json`), and machine-managed state
under `$XDG_STATE_HOME/vida-claude-container/<flavor>/` (`claude/` → the container's
`~/.claude`, which now also holds `claude/claude.json` → the container's
symlinked `~/.claude.json`). Defaults fall back to `~/.config` and
`~/.local/state` when the XDG vars are unset. Only config files have escape-hatch
env-var overrides (`CLAUDE_ENV_FILE`, `CLAUDE_MOUNTS_FILE`, `CLAUDE_SETTINGS`);
state paths follow `XDG_STATE_HOME` only.

### Memory scoping (per-project + global tier)

The container always runs at `/workspace`, so Claude Code's cwd-slug is always
`-workspace`. To stop every host repo from sharing one memory/history bucket, the
launcher keys a host dir on the host path — `PROJECT_KEY` is a readable slug of
`$PWD` (`/`→`-`) plus a `cksum` of the full path (the checksum disambiguates
hyphenated paths, which the slug alone would collide) — at
`$STATE_DIR/projects/<key>/`, and bind-mounts it over the container's
`projects/-workspace`. So memory **and** `/resume` transcripts isolate per host
repo; settings/plugins stay shared per-flavor.

A per-flavor **global** tier lives at `~/.claude/memory-global/` (inside the
`STATE_CLAUDE_DIR` mount). The entrypoint composes `~/.claude/CLAUDE.md` from a static
two-tier instruction block plus the global index, and Claude auto-loads that as
user memory — so cross-project facts reach context every session.

In both tiers `MEMORY.md` is **derived**: `rebuild-memory-index.sh` (baked at
`/opt/claude/`, unit-tested by `tests/test_rebuild_memory_index.sh`) regenerates
it from the `*.md` fact files' frontmatter on every launch. Edit fact files, not
the index; a concurrent index write that is lost self-heals next launch. Manual
repair: `claude-<flavor> rebuild-memory-index`.

Migration from the pre-fix shared bucket: `claude-<flavor> migrate-memory` (run
once, from the owning repo) moves `projects/-workspace` to this repo's key;
`just doctor` warns while the legacy bucket holds data. Pre-fix history was
commingled across repos and cannot be de-mixed — it lands wholesale under the
key you migrate from. Note: docker recreates `$STATE_CLAUDE_DIR/projects/-workspace`
as an **empty mountpoint stub** on every run (the per-repo bind mount nests
inside the `$STATE_CLAUDE_DIR` mount), so both the doctor check and
`migrate-memory` test the legacy dir for *content* (`ls -A`), not mere existence
— an empty stub is "no legacy bucket" and `migrate-memory` tidies it away.

## Conventions & gotchas

- **Non-root.** Runs as `claude` (uid 1000) — Claude Code refuses
  `bypassPermissions` as root. The entrypoint remaps this user to the host's
  UID/GID so writes into mounts land with host ownership.
- **Ephemeral (`<runtime> run --rm`).** Nothing written to the container filesystem
  survives. Persistent state must live in the
  `~/.local/state/vida-claude-container/<flavor>/claude` bind mount, the host
  `claude.json`/config `env` files, or the cred bind dirs (below).
- **Credentials are host bind dirs, not named volumes.** Auth caches live under
  XDG state: `$STATE_DIR/creds/gcloud` → `~/.config/gcloud` (vertex ADC) and
  `$STATE_DIR/creds/okta` → `~/.local/share/litellm` (gateway Okta cache). No more
  `docker volume` (works across all three runtimes). `just reset-auth` removes the
  cred dir. Old installs that still have the pre-fix named volume can migrate it in
  once with `claude-<flavor> migrate-creds` (copies the old volume into the new dir
  via the resolved runtime; docker/podman only).
- **claude-code is version-pinned; auto-update is OFF** (`DISABLE_AUTOUPDATER=1` in
  the `Containerfile` base). In-container self-update can't work — global npm install
  is root-owned but the process is non-root (EACCES), and `--rm` would discard it
  anyway. **Move the version forward with `just update`** (resolves the latest npm
  version and rebuilds pinned to it via the `CLAUDE_CODE_VERSION` build arg; set
  that env var to pin an exact version). `just doctor` shows the image's version.
- **Extra host files beyond `$PWD`.** The launcher bind-mounts `$PWD → /workspace`
  only. To expose more host dirs, list them (one path per line) in
  `~/.config/vida-claude-container/<flavor>/mounts`; each is mounted at
  `/mnt/approved/<basename>`,
  **read-only** by default (append ` :rw` to a line to allow edits). They are then
  reachable by Claude's native Read/Write/Grep/Bash — no MCP needed, since the
  bind mount is itself the access boundary.
- **Git identity is resolved fresh each launch, not seeded.** The launcher runs
  `git -C "$PWD" config --get` on the **host** for `user.name`/`user.email` (and
  the SSH signing config, below) every launch — so folder-scoped `includeIf`
  (personal-vs-work) selects the right values for the repo you're actually in —
  and writes the result into the per-run stage dir as `gitconfig-identity`. The
  entrypoint inlines it once at boot into a container-owned `~/.gitconfig` (reads
  it once, not a live `[include]`; see "Stage directory"). Nothing is persisted:
  the container always runs at `/workspace`, so a persisted identity would freeze
  to the first repo. There is no `gitconfig` config file and no `CLAUDE_GITCONFIG`
  override anymore. Inlining (vs `[include]`) is still deliberate: a live include
  of an unreadable file makes git abort with `bad config line N`, breaking every
  git call and the git-based statusline.
- **`gh` auth is a resolved token, not a mount.** The launcher injects
  `GH_TOKEN=$(gh auth token)` from the host (keyring-safe). The entrypoint runs
  `gh auth setup-git` for HTTPS push.
- **SSH agent forwarding + SSH commit signing (opt-in).** Enable per run with
  `CLAUDE_FORWARD_SSH=1`, or persist `forward_ssh = true` in
  `~/.config/vida-claude-container/<flavor>/launcher.conf` (flat INI; env
  overrides the file). Supported on **macOS + apple `container`** (uses
  `container run --ssh`), **Linux + docker rootful**, and **Linux + podman
  rootless** (both bind-mount `$SSH_AUTH_SOCK`). **macOS + Docker Desktop is
  unsupported** — its `host-services` bridge can't forward the 1Password agent —
  and the launcher warns + skips there. SSH signing config is grafted from the
  host git config only when `gpg.format = ssh` (openpgp/x509 → alerted + skipped);
  `gpg.ssh.program` is deliberately never grafted so the container's own
  `ssh-keygen` signs via the forwarded agent. GitHub host keys are baked into the
  image so SSH push works.
- **Hadolint.** `GOOGLE_APPLICATION_CREDENTIALS` is exported at runtime by the
  entrypoint, not baked as `ENV`, to avoid the `SecretsUsedInArgOrEnv` warning on
  the `*_CREDENTIALS` name pattern.
- **Plugins.** `superpowers` and `caveman` are pre-seeded and enabled; both are
  pinned to specific SHAs in the `Containerfile` base stage.
- **Memory is per-project, index is derived.** Each host repo gets its own
  `projects/<key>/memory` + transcripts (keyed on `$PWD` slug + a `cksum` suffix);
  a per-flavor global tier lives at `~/.claude/memory-global/` and is surfaced via
  the composed `~/.claude/CLAUDE.md`. `MEMORY.md` is regenerated from fact-file
  frontmatter every launch — never hand-maintain it. See "Memory scoping" above.
- **Settings override.** `settings.override.json` (in the config dir) is deep-merged
  onto the seeded `settings.json` every launch, so you can tweak e.g. `{"model":
  "..."}` and restart without editing the repo seed or running `just reseed`. The
  base `settings.json` keeps its normal seeded lifecycle (preserved across launches;
  refreshed by `just reseed`), which preserves `/setup-vertex`'s writes. Caveats: jq
  `*` **replaces arrays wholesale** (an override `permissions.allow` replaces the
  base's), and because the merge is in place, **removing** a key from the override
  doesn't auto-revert the active value until the next `just reseed` (changing a value
  works on the next launch). The merge lives in `bin/merge-settings.sh` (baked at
  `/opt/claude/merge-settings.sh`), unit-tested by `tests/test_merge_settings.sh`.
