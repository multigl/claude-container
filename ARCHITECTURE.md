# Architecture

How claude-container is put together, for people changing it. If you only want
to run it, the [README](README.md) is the place to start. `CLAUDE.md` covers the
same ground in more depth, with the gotchas that bit us.

## Repo layout

| Path | What it holds |
|------|---------------|
| `Containerfile` | Multi-stage image: a shared `base` plus one stage per flavor |
| `cmd/claude-container/` | The host binary's `main`, symlinked as `claude-<flavor>` |
| `internal/` | The launcher's Go packages (see "The host launcher") |
| `testdata/parity/` | Golden container-`run` argv fixtures for the launcher |
| `bin/container-entrypoint.sh` | Runs inside the container at boot: uid remap, seeding, merges |
| `seed-common/`, `seed-<flavor>/` | Baseline `~/.claude` contents copied in on first launch |
| `gateway/okta_token_helper.py` | The gateway flavor's baked `apiKeyHelper` |
| `install.sh` | The installer behind the curl one-liner: downloads the release binary |
| `.github/workflows/ci.yml` | Tests, image publishing, binary releases, and the weekly refresh |
| `tests/` | Bash suites (`tests/run.sh`), including black-box tests of the built binary, plus the Okta helper's pytest suite |

## One build, three flavors

The `Containerfile` is multi-stage:

```
base ──┬─► vertex    (adds gcloud CLI + Vertex ENV)
       ├─► gateway   (adds ANTHROPIC_BASE_URL + apiKeyHelper, no gcloud)
       └─► personal  (adds nothing baked; auth happens in-container)
```

`base` holds everything the flavors share: node, claude-code, `gh`, uv and
mcp-atlassian, the plugin seed, the non-root `claude` user, and the entrypoint.
Each flavor stage adds only its own payload. The gateway image carries no
gcloud, and the personal image carries neither gcloud nor any baked endpoint.

The baked `VERTEX_PROJECT_ID` and `GATEWAY_BASE_URL` build args are placeholders.
The flavor's `config.toml` `[env]` table overrides both at runtime, which is why one published
image per flavor serves everyone.

Adding a fourth flavor means adding a flavor driver (see below), a `Containerfile`
stage, a seed directory, and a few lines in the `justfile`'s per-flavor recipes.

## The host launcher

The host side is one Go binary, `claude-container`, built for darwin and linux on
amd64 and arm64. `claude-<flavor>` are symlinks to it. Its only third-party
dependency is a TOML parser (`github.com/BurntSushi/toml`).

| Package | Role |
|---------|------|
| `cmd/claude-container` | `main`: calls `app.Run` |
| `internal/app` | Picks the flavor from `argv[0]` (`CLAUDE_FLAVOR` overrides), dispatches subcommands, and implements `doctor`, `update`, `migrate-*` |
| `internal/config` | Loads and validates `config.toml`; converts the legacy `launcher.conf`/`env`/`mounts` files |
| `internal/paths` | XDG config and state paths, `CLAUDE_*` path overrides, and `PROJECT_KEY` |
| `internal/runtime` | Runtime drivers and detection |
| `internal/flavor` | Flavor drivers |
| `internal/launch` | Builds the run argv, the stage directory, the per-run env file, and git identity; runs the container |
| `internal/selfupdate` | Release lookup, checksum verification, and atomic binary replacement |
| `internal/buildinfo` | The version and image suffix stamped in at build time |

The flavor and runtime drivers are Go interfaces, one file per implementation.
They replace the old `fl_*` and `rt_*` bash functions, and the launcher never
branches on a flavor or runtime name outside them. Shared behavior lives in
helper functions the drivers call, not in an embedded base type.

- **`flavor.Flavor`**: `CredDirs`, `CredPaths`, `RunFlags`, `AuthCommand`,
  `SeedConfig` (the `config.toml` written on first launch), `PrintPaths`,
  `Doctor`, `LegacyVolume`.
- **`runtime.Runtime`**: `Name`, `Binary`, `RunFlags` (the uid handling described
  under "Container runtimes"), `SSHFlags`, `Pull`, `ImageLabel`. Detection and
  priority live beside it in `internal/runtime`.

Host shape (OS, architecture, macOS version) is probed with `uname` and `sw_vers`
at runtime, not from Go's compile-time `GOOS`. That lets the test fakes exercise
macOS paths on a Linux CI runner.

The in-container scripts (`container-entrypoint.sh`, `merge-settings.sh`,
`rebuild-memory-index.sh`, the statusline and the Okta helper) stay bash. The
launcher and entrypoint share a contract (stage directory, mounts, internal env
vars) that the binary and image are released together to keep in step.

## What happens at launch

```
┌──────────────────────────────────────────────────────────────┐
│ HOST                                                         │
│                                                              │
│  $ claude          ───────► api.anthropic.com (unchanged)    │
│                                                              │
│  $ claude-vertex   ──► container vertex-latest               │
│        env: CLAUDE_CODE_USE_VERTEX=1 + Vertex pins           │
│        creds: gcloud ADC in $STATE_DIR/creds/gcloud         │
│        ───────► us-east5-aiplatform.googleapis.com           │
│                                                              │
│  $ claude-gateway  ──► container gateway-latest              │
│        env: ANTHROPIC_BASE_URL=<gateway>                     │
│        auth: baked apiKeyHelper mints an Okta id_token;      │
│              refresh_token in $STATE_DIR/creds/okta         │
│        ───────► <gateway>/v1/messages                        │
│                                                              │
│  $ claude-personal ──► container personal-latest             │
│        env: (nothing baked)                                  │
│        auth: claude auth login --claudeai;                   │
│              creds in $STATE_CLAUDE_DIR/.credentials.json    │
│        ───────► api.anthropic.com                            │
└──────────────────────────────────────────────────────────────┘
```

The launcher does this, in order:

1. Picks the flavor from its own name (`claude-vertex`, `claude-gateway`, anything
   else is `personal`), and lets `CLAUDE_FLAVOR` override it.
2. Resolves the runtime and the image (see below).
3. Creates the per-flavor config and state directories, `chmod 700`s the state
   `claude/` directory, and seeds `config.toml` if it doesn't exist yet. If the
   old `launcher.conf`, `env` or `mounts` files exist and `config.toml` doesn't,
   it exits with code 2 and points at `update`.
4. Builds a per-run stage directory by copying host files into a temp dir:
   `settings.override.json`, your host `~/.claude.json`, your host statusline
   script, and your git identity. It mounts that one directory read-only at
   `/opt/claude-stage`. Single-file bind mounts go stale on Docker Desktop for
   macOS across sleep and wake, so the launcher never uses them.
5. Writes the `[env]` table to a per-run `0600` env file next to the stage
   directory (`.stage.XXXXXX.env`, outside the mounted directory) and passes it
   with `--env-file`. Using `-e KEY=VALUE` would put secrets in the process list.
   `GH_TOKEN`, from the host's `gh auth token`, is on neither argv nor disk: the
   argv carries a bare `-e GH_TOKEN` and the value sits in the runtime's own
   environment, which docker, podman and Apple `container` all read a bare
   `-e KEY` from.
6. Runs the container with `--rm`, through `os/exec` so cleanup runs after it
   exits: `$PWD` at `/workspace`, the state `claude/` directory at `~/.claude`,
   the per-repo project directory over `~/.claude/projects/-workspace`, plus any
   `[[mounts]]` entries. SIGINT, SIGTERM, SIGHUP and SIGQUIT are caught from
   before the stage is built and forwarded once the runtime starts (one that
   arrives earlier aborts the launch), and the child's exit code is the
   launcher's. The stage directory and env file are removed on exit,
   and leftovers older than a day are swept at the next launch.

Inside, `container-entrypoint.sh` remaps the `claude` user to your host uid/gid,
then:

- **Seeds `~/.claude` on first launch.** It copies `/opt/claude-seed` with
  `rsync --ignore-existing`, so your edits survive. `reseed` sets
  `CLAUDE_RESEED=1` and overwrites the seeded files (settings and plugins)
  while keeping history and projects.
- **Merges `settings.override.json`** onto `settings.json` with jq `*`
  (`bin/merge-settings.sh`).
- **Syncs MCP servers.** It force-syncs the `mcpServers` block from the seed
  every launch, then grafts `env` and `headers` credentials from your host
  `~/.claude.json`.
- **Inlines your git identity** into a container-owned `~/.gitconfig`.
- **Rebuilds the memory indexes.**

It then drops to the `claude` user with `gosu`. Claude Code refuses
`bypassPermissions` as root.

## Container runtimes

`internal/runtime` picks one runtime and returns its driver (docker, podman, or
apple). The launcher and `update`'s pull go through it. The `just` build recipes
ask the binary for the runtime with `--print-runtime` and call that runtime's
`build` CLI directly.

- **Priority is apple > docker > podman.** "Available" means installed and
  working: `docker info` or `podman info` succeeds. For apple, the host must be
  Apple Silicon on macOS 26+ and `container system status` must succeed.
- **Linux only considers docker and podman.**
- **`CLAUDE_RUNTIME` forces a choice.** `claude-<flavor> --print-runtime` shows what was chosen and what's available.

The three differ in how host uids reach the mounts:

| Runtime | uid handling |
|---------|-------------|
| docker | The entrypoint remaps `claude` to `HOST_UID`/`HOST_GID` |
| podman (rootless) | `--userns=keep-id:uid=1000,gid=1000` plus `--user 0:0`, and the entrypoint skips its remap |
| apple `container` | Same remap as docker. Its file share passes host uids through but rejects `chown`, `chmod` on the mount root, and `utimensat`, so the seed rsync runs with `--no-perms --no-times` |

## Releases, pinning, and CI

`.github/workflows/ci.yml` has these jobs:

- **test** runs `go vet`, `gofmt -l`, `go test ./...`, `uv run pytest -q` and
  `tests/run.sh` on every PR and every push to `main`. It also cross-compiles all
  four binaries without publishing.
- **plan** resolves the claude-code version once with `npm view`, then decides
  whether to build. Pushes to `main` and manual dispatches always build. The
  weekly cron (`0 3 * * 1`, Sunday evening US time) skips only when every
  flavor's `-latest` image carries npm's latest version *and* a GitHub Release
  exists for that version's tag. A run that published images but failed to
  release is retried the next week.
- **publish** builds all three flavors for `linux/amd64` and `linux/arm64` (arm64
  under QEMU) and pushes them to `ghcr.io/multigl/claude-container`. It runs on
  `main` only.
- **release** needs `publish`, so it never runs if the images failed to push. It
  cross-compiles the four binaries with `CGO_ENABLED=0`, stamping the version and
  image suffix with `-ldflags -X`, then creates a GitHub Release with the
  binaries and a `SHA256SUMS` file, marked latest. It skips with a note if the
  tag already exists, so a re-run is harmless.

Every image publish is a release. The release tag is `v<claude-version>-<sha7>`.
Each flavor's image gets two tags: `<flavor>-latest` and
`<flavor>-<claude-version>-<sha7>`. CI passes the resolved version as the
`CLAUDE_CODE_VERSION` build arg, so the tag, the label, and the installed claude
agree. The revision label comes from build-push-action's `labels:` input, not a
`Containerfile` ARG, because a per-commit ARG would invalidate the cache for
every later layer. Third-party actions are pinned to commit SHAs.

Plugin SHAs (`SUPERPOWERS_SHA`, `CAVEMAN_SHA`) are pinned in the `Containerfile`
and CI does not bump them.

**Retention.** Never prune the versioned tags. An installed binary runs its
pinned tag, so that tag has to stay pullable. Nothing prunes GHCR today, and any
future cleanup must keep every tag a published release references.

## Image selection

A binary is pinned to `ghcr.io/multigl/claude-container:<flavor>-<claude-version>-<sha7>`,
the tag of the release it came from. The launcher runs the first of these that
is set:

1. `CLAUDE_IMAGE` (empty counts as unset)
2. the `image` key in `config.toml`
3. the pinned tag

A binary built without `-ldflags` reports version `dev` and defaults to
`<flavor>-latest` instead.

`claude-<flavor> --print-paths` prints the result as `IMAGE=`, and `--version`
prints the release and the pinned tag. All three runtimes pull a missing image on
`run` by themselves, so a first launch works without `update`.

`claude-<flavor> update` does three things in order:

1. **Self-update.** It asks the GitHub API for the latest release (using
   `GH_TOKEN` if set, else the host's `gh auth token`; the token goes only to
   the API host). If the tag differs from the binary's own, it downloads
   this OS and architecture's asset and `SHA256SUMS`, verifies the checksum,
   writes the new binary beside the old one, renames it into place, and
   re-executes it with `_CLAUDE_SELFUPDATED=1` so the step isn't repeated. If
   the install directory isn't writable it prints the `install.sh` command
   instead. Dev builds skip this step.
2. **Migrate** legacy config (below).
3. **Pull** the pinned image, and warn when an override means plain launches
   won't use it.

If the release check or download fails, `update` exits non-zero without pulling,
so a half-update never looks complete.

## Config

Each flavor has one file, `$XDG_CONFIG_HOME/claude-container/<flavor>/config.toml`
(`~/.config` fallback), with top-level `image`, `forward_ssh` and `dns`, an
`[env]` table, and `[[mounts]]` entries. It's created `0600` and re-tightened on
every launch. `settings.override.json` stays a separate file because it is Claude
Code settings JSON, merged in the container.

Precedence is environment variable, then `config.toml`, then the default.
`CLAUDE_CONFIG` replaces the path; a missing file there is an error and is never
seeded. `[env]` values must be single-line strings with valid variable names, and
mount and DNS entries that are missing or malformed are warned about and skipped.

The first launch seeds a per-flavor `config.toml` from the flavor driver's
`SeedConfig`.

**Migration.** Older installs had `launcher.conf`, `env` and `mounts`. The
commands that start a container or would seed config (plain launch, `--`, `shell`,
`auth`, `reseed`, `rebuild-memory-index`) refuse with exit 2 while those files
(or the targets of `CLAUDE_ENV_FILE`/`CLAUDE_MOUNTS_FILE`) exist and `config.toml`
doesn't. Only `update` converts them, and it leaves the originals for the user to
delete. `doctor` reports the state instead of refusing. A normal launch never
rewrites or deletes config.

## Memory scoping

The container always runs at `/workspace`, so Claude Code's project slug would
always be `-workspace`, and every repo would share one memory and `/resume`
bucket. The launcher prevents that by keying a host directory on the host path:
a readable slug of `$PWD` plus a POSIX `cksum` of it (ported in `internal/paths`, not Go's `hash/crc32`). The checksum keeps
`a/foo-bar/baz` and `a/foo/bar-baz` apart. It bind-mounts
`$STATE_DIR/projects/<key>/` over `~/.claude/projects/-workspace`.

A per-flavor global tier lives at `~/.claude/memory-global/`. The entrypoint
builds `~/.claude/CLAUDE.md` from a fixed two-tier instruction block plus the
global index, so cross-project facts load every session. `MEMORY.md` in both
tiers is derived: `rebuild-memory-index.sh` regenerates it from the fact files'
frontmatter on every launch.

## Developing

```sh
git clone https://github.com/multigl/claude-container && cd claude-container
just build-all      # build all three images locally; the base stage is cached
just install-all    # build the binary, install it and the wrapper links
just test           # pytest, go test, and tests/run.sh
```

A binary built from the checkout is a `dev` build, so it runs `<flavor>-latest`.
To run your local image, point each flavor at it in
`~/.config/claude-container/<flavor>/config.toml`:

```toml
image = "claude-personal:latest"
```

`just` recipes default to `FLAVOR=personal`; prefix `FLAVOR=vertex` or
`FLAVOR=gateway` to target another.

| Recipe | What it does |
|--------|--------------|
| `just build-launcher` | `go build` the host binary to `bin/claude-container` |
| `just build` | Build the `FLAVOR` image locally with the resolved runtime's `build` CLI |
| `just build-vertex` / `build-gateway` / `build-personal` / `build-all` | Build one flavor, or all three |
| `just rebuild` / `rebuild-<flavor>` / `rebuild-all` | No-cache rebuilds |
| `just update` | Rebuild locally on the newest claude-code from npm (`CLAUDE_CODE_VERSION` pins an exact one) |
| `just install` / `install-all` | Build the binary and run `install.sh --local` for one or all flavors |
| `just uninstall` | Remove the wrapper links and the binary |
| `just auth` / `reset-auth` / `reseed` / `shell` | Delegate to the binary |
| `just doctor` | Delegates to `claude-<flavor> doctor` |
| `just clean` | Remove the local `claude-<flavor>:latest` image |
| `just test` | Run the full test suite |

**Tests.** Go unit tests (`go test ./...`) cover config, migration, POSIX `cksum`,
flags, and self-update (against an `httptest.Server`). The bash suites in
`tests/` are black-box: they run the built binary under `env -i` with fake
`docker`, `podman`, `container`, `uname`, `sw_vers`, `git` and `gh` executables on
`PATH`, so nothing builds or runs a real container. `tests/run.sh` builds the
binary first; `LAUNCHER_BIN` points the suites at another one.
`tests/test_parity.sh` compares the container `run` argv for each flavor and
runtime case against the fixtures in `testdata/parity/`, which were captured from
the old bash launcher. `PARITY_UPDATE=1` regenerates them.
