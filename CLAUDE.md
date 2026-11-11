# CLAUDE.md

Guidance for Claude Code when working in this repo.

User-facing docs live in `README.md` (running it); the contributor overview is
`ARCHITECTURE.md`. Keep both in step with changes described here.

## What this is

A **containerized Claude Code** distribution. It builds Claude Code into a Docker
image and runs it, isolated from the host's own `claude`, gcloud, and shell
config. Three **flavors** build from one repo:

| Flavor     | Routes through           | Auth                                    |
|------------|---------------------------|-----------------------------------------|
| `vertex`   | Vertex AI                | gcloud ADC (`CLAUDE_CODE_USE_VERTEX=1`) |
| `gateway`  | an LLM gateway (LiteLLM) | baked Okta `apiKeyHelper` + `ANTHROPIC_BASE_URL` |
| `personal` | `api.anthropic.com`      | `claude auth login --claudeai`, inside the container |

The host's regular `claude` is never touched — `personal` also talks to the
public Anthropic API, but from inside the container, under its own signed-in
account and its own state. Each flavor keeps its own state under
`~/.local/state/claude-container/<flavor>/claude/`.

## Host launcher (Go)

The host side is one Go binary, `claude-container` (darwin/linux × amd64/arm64),
with `claude-<flavor>` symlinks beside it. The old bash launcher is gone. Layout:
`cmd/claude-container` (main), `internal/app` (subcommands, `doctor`, `update`,
`migrate-*`), `internal/config` (`config.toml` + legacy conversion),
`internal/paths` (XDG paths, `PROJECT_KEY`), `internal/runtime` (docker/podman/apple
drivers + detection), `internal/flavor` (vertex/gateway/personal drivers),
`internal/launch` (run argv, stage dir, env file, git identity, exec),
`internal/selfupdate`, `internal/buildinfo`. The only third-party dependency is
`github.com/BurntSushi/toml`; keep it that way. In-container scripts
(`bin/container-entrypoint.sh`, `merge-settings.sh`, `rebuild-memory-index.sh`,
`statusline.sh`, the Okta helper) stay bash.

Host shape comes from `uname -s/-m` and `sw_vers` at runtime, never Go's `GOOS`,
so the test fakes can exercise macOS paths on Linux. The container runs through
`os/exec` (not `syscall.Exec`) so the stage dir and env file get cleaned up;
SIGINT/SIGTERM are forwarded and the child's exit code is returned; `-it` only
when stdin and stdout are both terminals. The working directory is `$PWD` when
set and valid, else `os.Getwd()` (`$PWD` is unset under `env -i`).

## Container runtime

The image runs under one of three container runtimes behind the `runtime.Runtime`
interface in `internal/runtime` (`docker.go`, `podman.go`, `apple.go`). The launcher
and `update` go through it; the `just` build recipes ask the binary for the
runtime with `--print-runtime` and call that runtime's `build` CLI directly (all
three take the same `-f/--target/-t/--no-cache/--build-arg` flags). One detection
path either way.

- **Priority: apple > docker > podman.** "Available" = installed **and** functional:
  `docker info` / `podman info` succeed; apple = eligible host (Apple Silicon,
  macOS 26+) **and** `container system status` succeeds. Platform gating: Linux
  considers {docker, podman}; macOS considers {apple, docker, podman}.
- **Override:** `CLAUDE_RUNTIME=docker|podman|apple` (errors if that runtime isn't
  available). Debug: `claude-<flavor> --print-runtime` prints `RUNTIME=<name>` then
  `available: <name>` lines (the justfile and `install.sh` parse `RUNTIME=` and map
  `apple` to the `container` binary); `--print-paths` includes a `RUNTIME=` line.
- **docker** (rootful Linux / Docker Desktop): unchanged — HOST_UID/HOST_GID remap
  in the entrypoint.
- **podman** (rootless Linux): passes `--userns=keep-id:uid=1000,gid=1000` to map
  the host user onto the image's `claude` (uid 1000), **plus `--user 0:0`**, plus an
  internal `_CLAUDE_UID_REMAP=skip` so the entrypoint skips its usermod/chown remap.
  `--user 0:0` is load-bearing: `keep-id` also sets the container's *default user*
  to the mapped uid, so without it the entrypoint starts as `claude` instead of
  root and its first `gosu claude …` dies with `error: failed switching to
  "claude": operation not permitted` (setgroups/setgid need CAP_SETGID). Container
  root is a subuid on the host, and the entrypoint still drops to `claude`
  (= the host user via keep-id) for the session, so mount writes land host-owned. On
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
  (`--no-times --omit-dir-times`). The share also rejects `chmod` on the mount
  root, which is why the seed rsync drops `-p` as well (`--no-perms`) — see
  "How config seeding works".

`claude-<flavor> doctor` has a `== runtime ==` section (resolved runtime +
availability); `just doctor` delegates to it. `just build`/`build-vertex`/
`build-gateway`/`update`/`rebuild-*` resolve the runtime from `--print-runtime`
and run that runtime's `build` CLI (`--no-cache` for `rebuild-*`) — no recipe
hardcodes a runtime binary. (Previously the four `rebuild-*` recipes hardcoded
`docker build`, silently writing to the wrong runtime's image store on
multi-runtime hosts where docker was also installed.)

### Installer (`install.sh`)

`curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash`.
Detects OS/arch, downloads the latest release binary plus `SHA256SUMS`, verifies
the checksum, and installs `~/.local/bin/claude-container`. It uses that binary's
`--print-runtime` to resolve a runtime (one detection implementation), applies a
macOS **apple gate** (on an Apple-Silicon macOS 26+ host without Apple `container`
installed it stops and tells you to install it + re-run; skip with
`--no-apple-gate` or `CLAUDE_SKIP_APPLE_GATE=1`; ineligible hosts fall through to
docker/podman), symlinks `claude-<flavor>` beside the binary, then **pulls** each
flavor's image by calling `claude-<flavor> update`. It never builds, and there is
no build fallback: a failed download or pull fails the install. There is no clone;
if the old one at `~/.local/share/claude-container/src` exists it says so and
leaves it. Flags: `--local <binary>` (install a binary built from the checkout;
used by `just install`), `--all`, `--flavor`, `--runtime`, `--no-apple-gate`,
`--bin-dir`, `--dry-run` (`--prefix` and `--ref` are gone). With no flavor flag it
installs **personal** (the default flavor). `just install` / `install-all` run
`just build-launcher` then `install.sh --local`.

### Releases, CI, and image selection

`.github/workflows/ci.yml` runs `go vet`, `gofmt -l`, `go test ./...`,
`uv run pytest -q` + `tests/run.sh` on every PR and push, and cross-compiles all
four binaries without publishing. On push to `main`, `workflow_dispatch`, and a
weekly cron (`0 3 * * 1`, Sunday evening US time), `plan` → `publish` builds all
three flavors for `linux/amd64` + `linux/arm64` and pushes
`ghcr.io/multigl/claude-container` tagged `<flavor>-latest` and
`<flavor>-<claude-version>-<sha7>`. CI resolves the claude-code version once from
npm and passes it as `CLAUDE_CODE_VERSION`, so tag, label, and installed claude
agree. The weekly run skips only when every `<flavor>-latest` carries npm's latest
version **and** a GitHub Release exists for that version's tag, so a run where
`publish` worked but `release` failed is retried. Plugin SHAs are not bumped by CI.

**Every image publish is a release.** The `release` job needs `publish` (never
runs if images failed), cross-compiles the four binaries with `CGO_ENABLED=0` and
`-ldflags -X` stamping `buildinfo.Version` and `buildinfo.ImageSuffix`, and
creates a GitHub Release `v<claude-version>-<sha7>` marked latest with
`claude-container_<os>_<arch>` assets and `SHA256SUMS`. It skips with a note if the
tag exists (idempotent re-runs). Docs-only pushes release too, same as images.
**Never prune versioned image tags**: an installed binary is pinned to
`<flavor>-<claude-version>-<sha7>`, so that tag must stay pullable. Nothing prunes
GHCR today; any future cleanup must keep every tag a release references.

The image the launcher runs: `CLAUDE_IMAGE` env (non-empty) > `config.toml`
`image` key > the binary's pinned tag
`ghcr.io/multigl/claude-container:<flavor>-<claude-version>-<sha7>`. A binary
built without `-ldflags` has version `dev` and defaults to `<flavor>-latest`.
`--print-paths` shows the result as `IMAGE=`; `--version` prints the release
version and pinned tag. On a dev machine set `image = "claude-<flavor>:latest"` to
run local `just build` output.

`claude-<flavor> update` runs, in order: (1) **self-update** — GitHub API latest
release (uses `GH_TOKEN` if set); if its tag differs from the embedded version,
download this OS/arch's asset + `SHA256SUMS`, verify, write a temp file in the
resolved binary's directory (following symlinks), chmod 0755, rename over the old
binary, and re-exec with the original `argv[0]` and `_CLAUDE_SELFUPDATED=1` (the
marker stops a mis-stamped version from looping). An unwritable directory prints
the `install.sh` command and continues; `dev` builds skip it. (2) **migrate** legacy
config (see "Single config file"). (3) **pull** the pinned image through the
runtime and warn when an override means plain launches won't use it. A failed
release check or download exits non-zero without pulling, so a half-update can't
look complete. `claude-<flavor> -- update` still reaches in-container
`claude update`. Apple `container run` auto-pulls a missing image (verified
v1.6.1), as docker/podman do, so plain launches need no pull guard.
`claude-<flavor> doctor`'s `== image ==` checks the launcher's resolved `IMAGE`
(hinting `update` for a pinned image, `just build` for an override), not the
justfile's `image` variable. Self-update uses only the standard library.

Existing installs upgrade by re-running the `install.sh` one-liner once (the old
bash `update` only pulled images and can't fetch the binary), then
`claude-<flavor> update`.

## How config seeding works

On first launch `container-entrypoint.sh` copies `/opt/claude-seed` → `~/.claude`
(the host `~/.local/state/claude-container/<flavor>/claude` bind mount) with
`rsync --ignore-existing`, so user
edits survive. `CLAUDE_RESEED=1` (via `just reseed`) instead overwrites the seeded
files (settings + plugins) while preserving history/projects.

The sync deliberately runs with `--no-perms`: `-a` implies `-p`, which chmods
the destination *root* (`~/.claude`) to the seed dir's `0755` — relaxing a dir
the launcher keeps at `0700` because it holds `.credentials.json`, and on Apple
`container` failing the whole sync (exit 23, `failed to set permissions on
"/home/claude/.claude/."`) because that share rejects chmod on the mount root.
Without `-p`, new files still land with the seed's mode masked by umask and
existing files keep theirs.

The `mcpServers` block is force-synced from the seed each launch, then
`env`/`headers` creds are grafted from the host `~/.claude.json` (staged
read-only at `/opt/claude-stage/host-claude.json`; see "Stage directory" below).

The container's own `~/.claude.json` (trust/onboarding flags, `mcpServers`, grafted
creds) is stored at `…/<flavor>/claude/claude.json` — inside the `~/.claude` dir
mount — and the entrypoint symlinks `~/.claude.json` to it. It is **not** a
credential store in any flavor, including personal: `claude auth login
--claudeai` writes its OAuth token to a separate file,
`~/.claude/.credentials.json`, not to `claude.json`. Old installs with a
sibling `…/<flavor>/claude.json` are auto-migrated into `claude/` on next launch.

The `~/.claude.json` symlink is safe against Claude Code's own writes: its
atomic file writer has an `allowSymlink` path that reads the link's target and
writes the real file there (it logs "Writing through symlink"), and where
symlinks aren't allowed it throws rather than replacing the link with a plain
file — confirmed by reading the pinned claude-code binary. The file that must
never be symlinked is `.credentials.json`: Claude Code opens it `O_NOFOLLOW`,
so a symlink there is refused outright rather than followed.

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

`config.toml` is seeded per-flavor **only when absent** (not by `reseed`), from the
flavor driver's `SeedConfig`, with real values, not blanks. The **vertex** flavor seeds model + region pins
(`ANTHROPIC_MODEL=claude-opus-5[1m]`, `…_SONNET_MODEL=claude-sonnet-5`,
`…_HAIKU_MODEL=claude-haiku-4-5`, `CLOUD_ML_REGION=us`,
`VERTEX_REGION_CLAUDE_HAIKU_4_5=us-east5`). All US, for data residency: opus/sonnet
on the `us` multi-region, haiku on `us-east5`. Pinning is load-bearing — unpinned,
the Vertex small/fast model defaults to `claude-sonnet-4-5` (429s if unprovisioned;
powers background titles + web-search summarization) and the 1M window is lost
(`[1m]` suffix; Sonnet 5 is always 1M). Existing installs hand-add these to the
live `config.toml` `[env]` — `reseed` won't rewrite it. Env is read once at container
start, so an edit needs a session kill+reopen.

### Single config file (`config.toml`)

Host-side wrapper files live in an XDG split (namespace `claude-container`):
config the user hand-edits under `$XDG_CONFIG_HOME/claude-container/<flavor>/`
(`config.toml`, `settings.override.json`), and machine-managed state
under `$XDG_STATE_HOME/claude-container/<flavor>/` (`claude/` → the container's
`~/.claude`, which now also holds `claude/claude.json` → the container's
symlinked `~/.claude.json`). Defaults fall back to `~/.config` and
`~/.local/state` when the XDG vars are unset. Only config files have escape-hatch
env-var overrides (`CLAUDE_CONFIG`, `CLAUDE_SETTINGS`); state paths follow
`XDG_STATE_HOME` only.

`config.toml` replaced the old `launcher.conf` (INI), `env` (docker env-file) and
`mounts` files: top-level `image`, `forward_ssh`, `dns`; an `[env]` table of
strings; `[[mounts]]` entries (`path`, `rw`). Mode 0600, re-tightened every launch.
Precedence: env var > `config.toml` > default (`CLAUDE_IMAGE`, `CLAUDE_FORWARD_SSH`,
`CLAUDE_DNS`, `CLAUDE_RUNTIME`, `CLAUDE_FLAVOR`, `CLAUDE_RESEED`, `CLAUDE_SETTINGS`,
`CLAUDE_CONFIG`). A `CLAUDE_CONFIG` naming a missing file is an error and is never
seeded into (it's usually a dotfiles repo). Unknown top-level keys warn (naming the
known keys); TOML syntax errors are fatal with a line number. `[env]` values must be
strings with no newline and keys must match `[A-Za-z_][A-Za-z0-9_]*` — `--env-file`
is line-based, so otherwise one TOML string could inject extra variables.
`settings.override.json` stays separate: it is Claude Code settings JSON merged in
the container, and TOML would buy nothing.

The launcher writes `[env]` (plus `GH_TOKEN`) to a per-run `0600` env file
`$STATE_DIR/.stage.XXXXXX.env` — **outside** the mounted stage dir — and passes it
with `--env-file`; it deliberately avoids `-e KEY=VALUE`, which would expose
secrets in the process list. It is removed after the run, and the older-than-a-day
stage sweep catches it after a crash. (`_CLAUDE_UID_REMAP=skip` and similar
internal vars are still per-run `-e` flags, never in config.)

**Legacy files.** `launcher.conf`, `env`, `mounts` (or the targets of
`CLAUDE_ENV_FILE`/`CLAUDE_MOUNTS_FILE` while set — this protects dotfiles users
who'd otherwise seed a fresh config and run without their secrets). If any exist
and `config.toml` doesn't: plain launch, `--`, `shell`, `auth`, `reseed` and
`rebuild-memory-index` exit 2 telling you to run `claude-<flavor> update`;
`doctor` reports it; `update`, `--print-*`, `--version`, `reset-auth`,
`migrate-memory`, `migrate-creds` are unaffected. `update` writes `config.toml`
(to `CLAUDE_CONFIG` if set) only when it's absent, leaves the old files for the
user to delete, and reports what it migrated. Both present: `config.toml` wins and
every launch warns the old files are ignored. A normal launch never rewrites or
deletes config. Conversion: `forward_ssh` truthy set `1/true/yes` (case-insens.);
`dns` comma/space → array; `env` lines verbatim (no quote stripping), comments kept
as TOML comments; a bare `KEY` line can't be expressed and is reported and
dropped; `mounts` ` :rw` → `rw = true`.

Only `--print-runtime`, `--print-paths` and `--version` are side-effect-free. Every
other invocation — including `doctor` and `reset-auth` — runs the full init
sequence first: `mkdir -p` on the config/state dirs, `chmod 700` on the state
`claude` dir, the legacy `claude.json` relocation, and `config.toml` seeding. So
`doctor`'s `== auth ==` section and `reset-auth` can create or relocate parts of a
flavor's state tree, not just touch credentials. (`doctor`'s `== memory ==` reads
the same paths `--print-paths` reports.)

### Memory scoping (per-project + global tier)

The container always runs at `/workspace`, so Claude Code's cwd-slug is always
`-workspace`. To stop every host repo from sharing one memory/history bucket, the
launcher keys a host dir on the host path — `PROJECT_KEY` is a readable slug of
`$PWD` (`/`→`-`) plus a `cksum` of the full path (the checksum disambiguates
hyphenated paths, which the slug alone would collide). The checksum is **POSIX
`cksum`** (different bit order, length appended), not Go's `hash/crc32` IEEE, and
must stay byte-compatible with the old bash output (tested against real `cksum`) or
every existing project's memory dir is orphaned; use `$PWD`, not the resolved path — at
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

- **Flavor drivers.** All flavor divergence lives in `internal/flavor/<flavor>.go`
  behind the `flavor.Flavor` interface — mirroring how `internal/runtime` splits
  runtime divergence into `docker.go`/`podman.go`/`apple.go`. It is the counterpart
  of the old `fl_*` bash functions: `CredDirs` (directories to create and
  bind-mount), `CredPaths` (what `reset-auth` deletes), `RunFlags` (extra `-v`/`-e`
  flags), `AuthCommand` (the one-time login), `SeedConfig` (the `config.toml`
  written on first launch), `PrintPaths` (flavor-specific `--print-paths` output),
  `Doctor` (the `== auth ==` block of `doctor`), and `LegacyVolume` (the old named
  cred volume `migrate-creds` copies from, or empty). Shared pieces (the
  Atlassian/Context7 env blocks) are helpers the drivers call, not an embedded base
  type — prefer composition. The launcher never branches on flavor name outside
  `flavor.New`, and the `justfile`'s single-flavor recipes (`build`, `auth`,
  `shell`, `doctor`, `reset-auth`, `reseed`, …) work the same way, driven by
  `$FLAVOR`. Only the `justfile`'s per-flavor convenience recipes (`build-vertex`,
  `build-personal`, `build-all`, `install-all`, `uninstall`, …) still name each
  flavor explicitly, so adding a fourth flavor means adding a driver (and
  registering it in `flavor.New`/`Known`), a `Containerfile` stage, a seed dir, and
  a few lines to those. An unknown `CLAUDE_FLAVOR` is a hard error at launch, not a
  silent fallback. The **default flavor is `personal`** — it is what the launcher
  picks for any invocation name other than `claude-vertex`/`claude-gateway`, what
  `justfile`'s `flavor` variable defaults to, and what `install.sh` installs with no
  `--flavor`/`--all`.
- **Vertex needs a project, loudly.** The image bakes only the placeholder
  `ANTHROPIC_VERTEX_PROJECT_ID=your-gcp-project`, so a fresh vertex install
  fails every request. Two complaints, deliberately hard to miss:
  `cr_vertex_project_ok`/`cr_vertex_project_banner` in
  `bin/container-entrypoint.sh` print a full-width stderr banner at every launch
  while the *effective* value is empty or a placeholder (checked there because
  only the container sees image ENV and `[env]` merged), and `Doctor` in
  `internal/flavor/vertex.go` reports `MISSING PROJECT` from the host-visible
  `config.toml`. Both are warnings, never fatal — `shell` and `auth` have to work on a
  not-yet-configured container. The seeded `config.toml` leaves the line **commented**
  on purpose: `--env-file` passes an empty `ANTHROPIC_VERTEX_PROJECT_ID=` through
  and it would override a value baked with `--build-arg VERTEX_PROJECT_ID=`.
- **Non-root.** Runs as `claude` (uid 1000) — Claude Code refuses
  `bypassPermissions` as root. The entrypoint remaps this user to the host's
  UID/GID so writes into mounts land with host ownership.
- **Ephemeral (`<runtime> run --rm`).** Nothing written to the container filesystem
  survives. Persistent state must live in the
  `~/.local/state/claude-container/<flavor>/claude` bind mount, the host
  `claude.json`/`config.toml` files, or the cred bind dirs (below).
- **Credentials are host bind dirs, not named volumes.** Auth caches live under
  XDG state: `$STATE_DIR/creds/gcloud` → `~/.config/gcloud` (vertex ADC) and
  `$STATE_DIR/creds/okta` → `~/.local/share/litellm` (gateway Okta cache). No more
  `docker volume` (works across all three runtimes). `just reset-auth` (or `claude-<flavor> reset-auth`) removes the
  cred dir. Old installs that still have the pre-fix named volume can migrate it in
  once with `claude-<flavor> migrate-creds` (copies the old volume into the new dir
  via the resolved runtime; docker/podman only).
- **claude-code is version-pinned; auto-update is OFF** (`DISABLE_AUTOUPDATER=1` in
  the `Containerfile` base). In-container self-update can't work — global npm install
  is root-owned but the process is non-root (EACCES), and `--rm` would discard it
  anyway. Installed machines move forward with **`claude-<flavor> update`** (new
  binary + its pinned CI-published image; see "Releases, CI, and image selection"). On a
  dev machine, **`just update`** resolves the latest npm version and rebuilds
  locally pinned to it via the `CLAUDE_CODE_VERSION` build arg (set that env var
  to pin an exact version).
- **Extra host files beyond `$PWD`.** The launcher bind-mounts `$PWD → /workspace`
  only. To expose more host dirs, add `[[mounts]]` entries (`path`, optional
  `rw = true`) to `~/.config/claude-container/<flavor>/config.toml`; each is mounted
  at `/mnt/approved/<basename>`, **read-only** by default. A leading `~` is
  expanded; a missing directory or duplicate basename is skipped with a warning and
  never blocks a launch. They are then reachable by Claude's native
  Read/Write/Grep/Bash — no MCP needed, since the bind mount is itself the access
  boundary.
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
- **`gh` auth is a resolved token, not a mount.** The launcher resolves
  `gh auth token` on the host each launch (keyring-safe) and writes `GH_TOKEN` into
  the per-run 0600 env file (see "Single config file"), **not** `-e GH_TOKEN=...`,
  which exposed it in the process list. The file is removed after the run. The
  entrypoint runs `gh auth setup-git` for HTTPS push.
- **SSH agent forwarding + SSH commit signing (opt-in).** Enable per run with
  `CLAUDE_FORWARD_SSH=1`, or persist `forward_ssh = true` in
  `~/.config/claude-container/<flavor>/config.toml` (env overrides the file). Supported on **macOS + apple `container`** (uses
  `container run --ssh`), **Linux + docker rootful**, and **Linux + podman
  rootless** (both bind-mount `$SSH_AUTH_SOCK`). **macOS + Docker Desktop is
  unsupported** — its `host-services` bridge can't forward the 1Password agent —
  and the launcher warns + skips there. SSH signing config is grafted from the
  host git config when `gpg.format = ssh`. When the host instead signs with
  gpg/x509 (e.g. a yubikey — no secret key material to forward into a
  container), the git-identity staging in `internal/launch/gitidentity.go` falls back to a
  custom `claude-container.signingkey-ssh` config value (literal `ssh-...`
  pubkey or a path) if the user set one — read via the same `git -C "$PWD"
  config --get`, so it rides whatever `includeIf gitdir:` block already
  selected the host identity (put it in the same personal/work included file as
  the real `user.signingkey`). Still requires `forward_ssh` — only the pubkey
  ever reaches the container; the private half must live in the host's
  forwarded agent. `gpg.ssh.program` is deliberately never grafted so the
  container's own `ssh-keygen` signs via the forwarded agent. GitHub host keys
  are baked into the image so SSH push works.
- **DNS override.** `CLAUDE_DNS` env (comma/space list) or the `config.toml` `dns`
  array (env wins) becomes one `--dns IP` run flag per server, on every runtime
  (`internal/launch/flags.go`, tested by `flags_test.go` and
  `tests/test_dns_flags.sh`).
  Non-IP tokens are warned about and dropped, so a value can't smuggle in a run
  flag. Motivating case: apple `container` on a Zscaler-managed Mac, where the
  vmnet gateway resolver (`192.168.64.1`) times out
  (`getaddrinfo ETIMEDOUT platform.claude.com`) but direct DNS and TCP/TLS work
  fine. No TLS interception was seen there, so no extra CA was needed.
- **Hadolint.** `GOOGLE_APPLICATION_CREDENTIALS` is exported at runtime by the
  entrypoint, not baked as `ENV`, to avoid the `SecretsUsedInArgOrEnv` warning on
  the `*_CREDENTIALS` name pattern.
- **Plugins.** `superpowers` and `caveman` are pre-seeded and enabled; both are
  pinned to specific SHAs in the `Containerfile` base stage.
- **Memory is per-project, index is derived.** Each host repo gets its own
  `projects/<key>/memory` + transcripts (keyed on `$PWD` slug + a POSIX `cksum` suffix);
  a per-flavor global tier lives at `~/.claude/memory-global/` and is surfaced via
  the composed `~/.claude/CLAUDE.md`. `MEMORY.md` is regenerated from fact-file
  frontmatter every launch — never hand-maintain it. See "Memory scoping" above.
- **Tests.** `just test` = `uv run pytest -q` + `go test ./...` + `tests/run.sh`.
  Go unit tests are table-driven (`t.Run`); mock only at system boundaries (fake
  host CLIs on `PATH`, `httptest.Server` for GitHub, temp `HOME`/XDG dirs). The bash
  suites in `tests/` are black-box tests of the built binary under `env -i` with
  fake `docker`/`podman`/`container`/`uname`/`sw_vers`/`git`/`gh`; `tests/run.sh`
  builds it first and `LAUNCHER_BIN` overrides. `tests/test_parity.sh` diffs the
  container `run` argv against `testdata/parity/` fixtures captured from the old
  bash launcher (only stage-dir/env-file temp paths normalized); `PARITY_UPDATE=1`
  regenerates them from whichever binary is under test, so an intended argv change
  means updating the fixtures deliberately.
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
