# Architecture

How claude-container is put together, for people changing it. If you only want
to run it, the [README](README.md) is the place to start. `CLAUDE.md` covers the
same ground in more depth, with the gotchas that bit us.

## Repo layout

| Path | What it holds |
|------|---------------|
| `Containerfile` | Multi-stage image: a shared `base` plus one stage per flavor |
| `bin/claude-launcher.sh` | The host wrapper, symlinked as `claude-<flavor>` |
| `bin/flavors/<flavor>.sh` | Flavor drivers: everything that differs per flavor on the host side |
| `bin/container-runtime.sh` | Runtime dispatcher: picks apple, docker, or podman |
| `bin/runtimes/<runtime>.sh` | Runtime drivers: build, run, pull, and run-flag differences |
| `bin/container-entrypoint.sh` | Runs inside the container at boot: uid remap, seeding, merges |
| `seed-common/`, `seed-<flavor>/` | Baseline `~/.claude` contents copied in on first launch |
| `gateway/okta_token_helper.py` | The gateway flavor's baked `apiKeyHelper` |
| `install.sh` | The installer behind the curl one-liner |
| `.github/workflows/ci.yml` | Tests, image publishing, and the weekly refresh |
| `tests/` | Plain-bash suites (`tests/run.sh`) plus the Okta helper's pytest suite |

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
The flavor's `env` file overrides both at runtime, which is why one published
image per flavor serves everyone.

On the host, all flavor divergence lives in `bin/flavors/<flavor>.sh`. The
launcher sources the driver named by `$FLAVOR` and calls eight functions on it
(`fl_cred_dirs`, `fl_cred_paths`, `fl_run_flags`, `fl_auth`, `fl_seed_env`,
`fl_print_paths`, `fl_doctor`, `fl_legacy_volume`). The launcher never branches on
flavor name otherwise. Adding a fourth flavor means adding a driver, a
`Containerfile` stage, a seed directory, and a few lines in the `justfile`'s
per-flavor recipes.

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
   `claude/` directory, and seeds the `env` file if it doesn't exist yet.
4. Builds a per-run stage directory by copying host files into a temp dir:
   `settings.override.json`, your host `~/.claude.json`, your host statusline
   script, and your git identity. It mounts that one directory read-only at
   `/opt/claude-stage`. Single-file bind mounts go stale on Docker Desktop for
   macOS across sleep and wake, so the launcher never uses them.
5. Runs the container with `--rm`: `$PWD` at `/workspace`, the state `claude/`
   directory at `~/.claude`, the per-repo project directory over
   `~/.claude/projects/-workspace`, plus any `mounts` entries.

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

`bin/container-runtime.sh` picks one runtime and sources its driver from
`bin/runtimes/`. Everything that touches a container goes through it: the
launcher, the `just` build recipes, and `update`'s pull.

- **Priority is apple > docker > podman.** "Available" means installed and
  working: `docker info` or `podman info` succeeds. For apple, the host must be
  Apple Silicon on macOS 26+ and `container system status` must succeed.
- **Linux only considers docker and podman.**
- **`CLAUDE_RUNTIME` forces a choice.**

The three differ in how host uids reach the mounts:

| Runtime | uid handling |
|---------|-------------|
| docker | The entrypoint remaps `claude` to `HOST_UID`/`HOST_GID` |
| podman (rootless) | `--userns=keep-id:uid=1000,gid=1000` plus `--user 0:0`, and the entrypoint skips its remap |
| apple `container` | Same remap as docker. Its file share passes host uids through but rejects `chown`, `chmod` on the mount root, and `utimensat`, so the seed rsync runs with `--no-perms --no-times` |

## Published images and CI

`.github/workflows/ci.yml` has three jobs:

- **test** runs `uv run pytest -q` and `tests/run.sh` on every PR and every push
  to `main`.
- **plan** resolves the claude-code version once with `npm view`, then decides
  whether to build. Pushes to `main` and manual dispatches always build. The
  weekly cron (`0 3 * * 1`, Sunday evening US time) builds only when some
  flavor's published `org.opencontainers.image.version` label differs from npm's
  latest.
- **publish** builds all three flavors for `linux/amd64` and `linux/arm64` (arm64
  under QEMU) and pushes them to `ghcr.io/multigl/claude-container`. It runs on
  `main` only, because `-latest` is what every install pulls.

Each flavor gets two tags: `<flavor>-latest` and
`<flavor>-<claude-version>-<sha7>`. CI passes the resolved version as the
`CLAUDE_CODE_VERSION` build arg, so the tag, the label, and the installed binary
always agree. The revision label comes from build-push-action's `labels:`
input, not a `Containerfile` ARG, because a per-commit ARG would invalidate the
cache for every later layer. Third-party actions are pinned to commit SHAs.

Plugin SHAs (`SUPERPOWERS_SHA`, `CAVEMAN_SHA`) are pinned in the `Containerfile`
and CI does not bump them.

## Image selection

The launcher runs the first of these that is set:

1. `CLAUDE_IMAGE` (empty counts as unset)
2. the `image` key in `launcher.conf`
3. `ghcr.io/multigl/claude-container:<flavor>-latest`

`claude-<flavor> --print-paths` prints the result as `IMAGE=`.
`claude-<flavor> update` always pulls the published tag, whatever the override,
and warns when an override means plain launches won't use what it pulled. All
three runtimes pull a missing image on `run` by themselves, so a first launch
works without `update`.

## Memory scoping

The container always runs at `/workspace`, so Claude Code's project slug would
always be `-workspace`, and every repo would share one memory and `/resume`
bucket. The launcher prevents that by keying a host directory on the host path:
a readable slug of `$PWD` plus a `cksum` of it. The checksum keeps
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
just install-all    # symlink the wrappers and pull the published images
just test           # pytest + tests/run.sh
```

To run your local build, point each flavor at it in
`~/.config/claude-container/<flavor>/launcher.conf`:

```ini
image = claude-personal:latest
```

Without that, the wrappers run the published GHCR image.

`just` recipes default to `FLAVOR=personal`; prefix `FLAVOR=vertex` or
`FLAVOR=gateway` to target another.

| Recipe | What it does |
|--------|--------------|
| `just build` | Build the `FLAVOR` image locally, through the runtime dispatcher |
| `just build-vertex` / `build-gateway` / `build-personal` / `build-all` | Build one flavor, or all three |
| `just rebuild` / `rebuild-<flavor>` / `rebuild-all` | No-cache rebuilds |
| `just update` | Rebuild locally on the newest claude-code from npm (`CLAUDE_CODE_VERSION` pins an exact one) |
| `just install` / `install-all` | Symlink one or all wrappers and pull their published images |
| `just uninstall` | Remove the wrapper symlinks |
| `just auth` | One-time login for the flavor |
| `just reset-auth` | Delete the flavor's credential |
| `just reseed` | Overwrite seeded settings and plugins from the image |
| `just doctor` | Self-check: runtime, image, auth, wrapper on `PATH`, memory |
| `just clean` | Remove the local `claude-<flavor>:latest` image |
| `just test` | Run the full test suite |

Tests are plain bash (`tests/lib.sh` has the asserts) and stub runtime binaries
on `PATH`, so nothing builds or runs a real container.
