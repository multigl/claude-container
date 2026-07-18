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

Multi-stage `Dockerfile`:

```
base ─┬─► vertex    (adds google-cloud-cli + Vertex ENV)
      └─► gateway   (adds ANTHROPIC_BASE_URL + Okta apiKeyHelper, no gcloud)
```

`base` holds everything shared (node, claude-code, uv + mcp-atlassian, the plugin
seed, the non-root `claude` user, the entrypoint). Build a flavor with
`docker build --target <flavor>`. The host wrapper `claude-launcher.sh` is
symlinked to `claude-vertex` / `claude-gateway` and picks its flavor from the name
it was invoked as (override with `CLAUDE_FLAVOR=...`).

## Key files

- `Dockerfile` — multi-stage build (`base`, `vertex`, `gateway`).
- `claude-launcher.sh` — host wrapper; assembles the `docker run` (mounts, env,
  auth volumes) and dispatches subcommands (`auth`, `shell`, `reseed`, `--`).
- `docker-entrypoint.sh` — runs as root to chown bind mounts + remap `claude` to
  the host UID/GID, seeds `~/.claude`, grafts MCP config/creds, then drops to
  `claude` via `gosu`.
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
grafted read-only from the host `~/.claude.json` (mounted at `.host-claude.json`).

Host-side wrapper files live in an XDG split (namespace `vida-claude-container`):
config the user hand-edits under `$XDG_CONFIG_HOME/vida-claude-container/<flavor>/`
(`env`, `mounts`, `gitconfig`, `settings.override.json`), and machine-managed state
under `$XDG_STATE_HOME/vida-claude-container/<flavor>/` (`claude/` → the container's
`~/.claude`, and `claude.json`). Defaults fall back to `~/.config` and
`~/.local/state` when the XDG vars are unset. Only config files have escape-hatch
env-var overrides (`CLAUDE_ENV_FILE`, `CLAUDE_MOUNTS_FILE`, `CLAUDE_GITCONFIG`,
`CLAUDE_SETTINGS`); state paths follow `XDG_STATE_HOME` only.

## Conventions & gotchas

- **Non-root.** Runs as `claude` (uid 1000) — Claude Code refuses
  `bypassPermissions` as root. The entrypoint remaps this user to the host's
  UID/GID so writes into mounts land with host ownership.
- **Ephemeral (`docker run --rm`).** Nothing written to the container filesystem
  survives. Persistent state must live in the
  `~/.local/state/vida-claude-container/<flavor>/claude` bind mount, the host
  `claude.json`/config `env` files, or a named docker volume (gcloud ADC, Okta cache).
- **claude-code is version-pinned; auto-update is OFF** (`DISABLE_AUTOUPDATER=1` in
  the `Dockerfile` base). In-container self-update can't work — global npm install
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
- **Git identity is seeded, not inherited.** The launcher writes
  `~/.config/vida-claude-container/<flavor>/gitconfig` (prefilled from host
  `git config`), mounts it ro at
  `~/.gitconfig-identity`, and the entrypoint generates a writable `~/.gitconfig`
  that includes it. The host `~/.gitconfig` is not mounted directly.
- **`gh` auth is a resolved token, not a mount.** The launcher injects
  `GH_TOKEN=$(gh auth token)` from the host (keyring-safe). The entrypoint runs
  `gh auth setup-git` for HTTPS push.
- **Commit signing is off by default.** Enable SSH signing in
  `~/.config/vida-claude-container/<flavor>/gitconfig` and forward the agent with the shell var
  `CLAUDE_FORWARD_SSH_AGENT=1` (macOS needs `launchctl setenv SSH_AUTH_SOCK …`
  before Docker Desktop starts).
- **Hadolint.** `GOOGLE_APPLICATION_CREDENTIALS` is exported at runtime by the
  entrypoint, not baked as `ENV`, to avoid the `SecretsUsedInArgOrEnv` warning on
  the `*_CREDENTIALS` name pattern.
- **Plugins.** `superpowers` and `caveman` are pre-seeded and enabled; both are
  pinned to specific SHAs in the `Dockerfile` base stage.
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
