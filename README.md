# claude-vertex

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) against
Vida's **Vertex AI** project inside a Docker container — without disturbing
the host's regular `claude` (Anthropic API), shell config, or gcloud setup.

```sh
cd ~/vida/dbt
claude-vertex          # opens Claude Code, billed through Vida's Vertex project
```

## Why a container?

- **Coexists with host `claude`.** Outside the container, normal `claude`
  keeps hitting the Anthropic API. Inside, requests route through Vertex.
- **Zero host changes.** No edits to `~/.zshrc`, no shared gcloud config,
  no extra env vars in your shell.
- **Pinned config.** Vida's Vertex project, region, and approved model IDs
  are baked into the image — no interactive `/login` ritual on every machine.

## Prerequisites

1. **Docker Desktop** (or any Docker engine) running.
2. **[`just`](https://github.com/casey/just)** — `brew install just`.
3. **A `@vida.com` Google account** with access to the Vertex project
   `vertex-test-495715`. (See the Confluence page
   [Claude Code on Vertex-AI](https://vidahealth.atlassian.net/wiki/spaces/IT/pages/4534337542)
   if you don't have access yet.)
4. **`~/.local/bin` on `PATH`** (or set `BIN_DIR=/usr/local/bin` when installing).

No host `gcloud` install required — the container ships its own.

## Quickstart

```sh
git clone <this-repo> claude-vertex && cd claude-vertex

just build      # build the image (~5 min first time)
just auth       # one-time gcloud login (paste URL into browser, paste code back)
just install    # symlink `claude-vertex` onto PATH
```

Then from any project:

```sh
cd ~/vida/dbt
claude-vertex
```

That's it.

## Commands

| Command                  | What it does                                                |
|--------------------------|-------------------------------------------------------------|
| `claude-vertex`          | Run `claude` against current directory                      |
| `claude-vertex shell`    | Drop into `bash` inside the container                       |
| `claude-vertex -- <args>`| Pass flags through to `claude` (e.g. `claude-vertex -- --help`) |
| `just build`             | Build image                                                 |
| `just rebuild`           | Rebuild without cache                                       |
| `just auth`              | One-time gcloud ADC login (creds saved to docker volume)    |
| `just reset-auth`        | Wipe credentials volume; forces re-auth                     |
| `just doctor`            | Self-check: docker, image, auth volume, host clock          |
| `just install`           | Symlink wrapper to `~/.local/bin/claude-vertex`             |
| `just uninstall`         | Remove the symlink                                          |
| `just clean`             | Remove the image                                            |
| `just`                   | List recipes (default)                                      |

## Verifying you're on Vertex

After launching `claude-vertex`, run `/status` inside Claude. You should see:

```
API provider:  Google Vertex AI
GCP project:   vertex-test-495715
Default region: us-east5
Model:         Default (claude-sonnet-4-6[1m])
```

If `API provider` says `Anthropic API`, you're not on Vertex — see Troubleshooting.

Stronger proof: open Google Cloud Console → Logging → query

```
resource.type="aiplatform.googleapis.com/Endpoint"
protoPayload.authenticationInfo.principalEmail="<you>@vida.com"
```

Requests appearing here = traffic genuinely routed through Vida's GCP project.

## How it works

```
┌──────────────────────────────────────────────────────────────┐
│ HOST (your Mac)                                              │
│                                                              │
│  $ claude          ───────► api.anthropic.com (unchanged)    │
│                                                              │
│  $ claude-vertex                                             │
│        │                                                     │
│        ▼                                                     │
│  ┌────────────────────────────────────────────────────┐      │
│  │ container: claude-vertex:latest                    │      │
│  │   • claude-code (npm)                              │      │
│  │   • gcloud CLI                                     │      │
│  │   • env: CLAUDE_CODE_USE_VERTEX=1                  │      │
│  │          ANTHROPIC_VERTEX_PROJECT_ID=vertex-test-… │      │
│  │          CLOUD_ML_REGION=us-east5                  │      │
│  │          ANTHROPIC_DEFAULT_*_MODEL=…               │      │
│  │                                                    │      │
│  │   mounts:                                          │      │
│  │     $PWD                  → /workspace             │      │
│  │     vol claude-vertex-gcloud → /root/.config/gcloud│      │
│  │     ~/.claude-vertex      → /root/.claude          │      │
│  │                                                    │      │
│  │   ───────► us-east5-aiplatform.googleapis.com      │      │
│  └────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────┘
```

Key points:

- Vertex env vars are **baked into the image** (see `Dockerfile`), so each
  machine doesn't need to redo the interactive `/login` setup.
- Auth (ADC) is stored in a **docker named volume** (`claude-vertex-gcloud`),
  not under host `~/.config/gcloud`. Container-only.
- Claude's per-user state (`~/.claude/settings.json`, `shell-snapshots`, etc.)
  lives in host `~/.claude-vertex/` — kept separate from host `~/.claude` so
  the regular host `claude` is never touched.
- **Pre-seeded config.** On first launch the entrypoint copies a baked-in
  baseline from `/opt/claude-seed/` into the empty `~/.claude-vertex/`:
  - `settings.json` with `permissions.defaultMode = bypassPermissions` and
    `skipAutoPermissionPrompt = true`, so the container runs without
    per-tool prompts.
  - The [`superpowers`](https://github.com/obra/superpowers) plugin
    pre-installed and enabled.
  Seeding is idempotent (`rsync --ignore-existing`), so any edits you make
  in `~/.claude-vertex/` survive future container starts. To re-seed from
  scratch: `rm -rf ~/.claude-vertex && claude-vertex`.

## Configuration

The defaults match Vida's Confluence guide:

| Var                              | Default                          |
|----------------------------------|----------------------------------|
| `CLAUDE_CODE_USE_VERTEX`         | `1`                              |
| `ANTHROPIC_VERTEX_PROJECT_ID`    | `vertex-test-495715`             |
| `CLOUD_ML_REGION`                | `us-east5`                       |
| `ANTHROPIC_MODEL`                | `claude-opus-4-6`                |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `claude-sonnet-4-6[1m]`          |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`   | `claude-opus-4-6`                |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL`  | `claude-haiku-4-5@20251001`      |

Override per-invocation:

```sh
ANTHROPIC_VERTEX_PROJECT_ID=other-project claude-vertex
```

(Wrapper passes through any env you export to the container.)

Override permanently: edit `Dockerfile`, `just rebuild`.

## Troubleshooting

**`/status` still says "Anthropic API"** — host `~/.claude/settings.json`
may have a stale login. The container uses `~/.claude-vertex`, but the
mount may be picking up old settings. Try `rm -rf ~/.claude-vertex && claude-vertex`.

**`just auth` fails with browser/URL issues** — try
`just reset-auth && just auth` to wipe and retry. If your gcloud account
requires MFA in ways that block `--no-launch-browser`, fall back to mounting
host gcloud creds (see "Alternative: host gcloud auth" below).

**`just doctor` reports problems** — follow its hints. It catches the common
"image not built", "auth volume empty", "host clock skewed" issues that make
Vertex calls fail mysteriously.

**Permission errors writing to mounted dir** — the container runs as `root`.
On Linux hosts, files it creates will be root-owned on disk. macOS Docker
Desktop maps UIDs, so this rarely matters there.

### Alternative: host gcloud auth

If `just auth` is awkward, you can instead reuse host gcloud creds. Edit
`claude-vertex.sh` and replace:

```sh
-v "$GCLOUD_VOL:/root/.config/gcloud"
```

with:

```sh
-v "$HOME/.config/gcloud:/root/.config/gcloud"
```

then run `gcloud auth application-default login` on the host.

## Uninstall

```sh
just uninstall      # remove `claude-vertex` symlink
just clean          # remove the image
just reset-auth     # wipe gcloud creds volume
rm -rf ~/.claude-vertex
```

## License

MIT (or whatever Vida prefers for internal tools — update before publishing).
