# claude-vertex / claude-gateway

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside a
Docker container, routed through somewhere other than the public Anthropic API —
without disturbing the host's regular `claude`, shell config, or gcloud setup.

Two flavors build from this one repo:

| Flavor          | Routes through            | Auth                                   |
|-----------------|---------------------------|----------------------------------------|
| **`vertex`**    | Vida's **Vertex AI**      | gcloud ADC (`CLAUDE_CODE_USE_VERTEX=1`)|
| **`gateway`**   | an **LLM gateway** (LiteLLM) | `apiKeyHelper` + `ANTHROPIC_BASE_URL`  |

```sh
cd ~/vida/dbt
claude-vertex     # billed through Vida's Vertex project
claude-gateway    # routed through your LLM gateway
```

## Why a container?

- **Coexists with host `claude`.** Outside the container, normal `claude` keeps
  hitting the Anthropic API. Inside, requests route through Vertex or the gateway.
- **Zero host changes.** No edits to `~/.zshrc`, no shared gcloud config, no extra
  env vars in your shell.
- **Pinned config.** Project, region, gateway URL, and model IDs are baked into
  the image — no interactive `/login` ritual on every machine.
- **Flavors don't collide.** Each flavor keeps its own state under
  `~/.claude-vertex/` vs `~/.claude-gateway/`.

## How the two flavors share one build

The `Dockerfile` is multi-stage:

```
base ──┬─► vertex    (adds gcloud CLI + Vertex ENV)
       └─► gateway   (adds ANTHROPIC_BASE_URL + apiKeyHelper, no gcloud)
```

`base` holds everything common (node, claude-code, uv + mcp-atlassian, the
plugin seed, the `claude` user, the entrypoint). Each flavor stage adds only its
own payload, so the gateway image carries no gcloud and the vertex image keeps
its Vertex pins. Build a flavor with `docker build --target <flavor>`.

The host wrapper is a single script, `claude-launcher.sh`, symlinked to both
`claude-vertex` and `claude-gateway`; it picks its flavor from the name it was
invoked as (override with `CLAUDE_FLAVOR=...`).

## Prerequisites

1. **Docker Desktop** (or any Docker engine) running.
2. **[`just`](https://github.com/casey/just)** — `brew install just`.
3. **`~/.local/bin` on `PATH`** (or set `BIN_DIR=/usr/local/bin` when installing).
4. Flavor-specific:
   - **vertex** — a `@vida.com` Google account with access to the Vertex project
     `vertex-test-495715` (see Confluence:
     [Claude Code on Vertex-AI](https://vidahealth.atlassian.net/wiki/spaces/IT/pages/4534337542)).
     No host `gcloud` install required — the container ships its own.
   - **gateway** — an executable key-helper script at
     `~/.local/bin/litellm-key-helper` that prints a valid gateway token to
     stdout, and the gateway's base URL.

## Quickstart

```sh
git clone <this-repo> claude-vertex && cd claude-vertex
just build-all      # build both images (shared base layer is cached)
just install-all    # symlink claude-vertex AND claude-gateway onto PATH
```

### Vertex

```sh
just auth           # one-time gcloud login (paste URL into browser, paste code back)
cd ~/vida/dbt
claude-vertex
```

### Gateway

```sh
# Bake your gateway URL (or override at runtime later):
docker build --target gateway \
    --build-arg GATEWAY_BASE_URL=https://gateway.internal \
    -t claude-gateway:latest .

# Ensure your key-helper is in place and executable:
chmod +x ~/.local/bin/litellm-key-helper

cd ~/vida/dbt
claude-gateway      # first run seeds ~/.claude-gateway.env — fill it in if needed
```

## Commands

The wrapper auto-detects flavor from its name. `just` recipes default to
`FLAVOR=vertex`; prefix `FLAVOR=gateway` to target the gateway flavor.

| Command                  | What it does                                                |
|--------------------------|-------------------------------------------------------------|
| `claude-vertex` / `claude-gateway` | Run `claude` against the current directory        |
| `claude-<flavor> shell`  | Drop into `bash` inside the container                       |
| `claude-<flavor> -- <args>` | Pass flags through to `claude`                           |
| `just build`             | Build the `FLAVOR` image (`--target`)                       |
| `just build-vertex` / `build-gateway` / `build-all` | Build a specific flavor / both |
| `just install` / `install-all` | Symlink one / both flavor commands                   |
| `just auth`              | One-time gcloud ADC login (vertex only)                     |
| `just reset-auth`        | Wipe gcloud creds volume; forces re-auth                    |
| `FLAVOR=gateway just doctor` | Self-check for the gateway flavor                       |
| `just doctor`            | Self-check (vertex): docker, image, auth volume, ADC, PATH  |
| `just`                   | List recipes (default)                                      |

## How it works

```
┌──────────────────────────────────────────────────────────────┐
│ HOST (your Mac)                                              │
│                                                              │
│  $ claude          ───────► api.anthropic.com (unchanged)    │
│                                                              │
│  $ claude-vertex   ──► container claude-vertex:latest        │
│        env: CLAUDE_CODE_USE_VERTEX=1 + Vertex pins           │
│        creds: gcloud ADC in docker volume                   │
│        ───────► us-east5-aiplatform.googleapis.com           │
│                                                              │
│  $ claude-gateway  ──► container claude-gateway:latest       │
│        env: ANTHROPIC_BASE_URL=<gateway>                     │
│        auth: apiKeyHelper = mounted ~/.local/bin/            │
│              litellm-key-helper  (prints token)             │
│        ───────► <gateway>/v1/messages                        │
└──────────────────────────────────────────────────────────────┘
```

Shared by both flavors:

- **Per-user state** (`settings.json`, `shell-snapshots`, …) lives in host
  `~/.claude-<flavor>/`, separate from `~/.claude`, so the regular host `claude`
  is never touched and the two flavors don't collide.
- **Pre-seeded config.** On first launch the entrypoint copies the baked-in
  baseline from `/opt/claude-seed/` (common bits from `seed-common/`, plus the
  flavor's `settings.json`) into the empty `~/.claude-<flavor>/`. Seeding is
  idempotent (`rsync --ignore-existing`), so edits survive future starts. Re-seed
  from scratch: `rm -rf ~/.claude-<flavor>`.
- **MCP servers** (atlassian, context7) are defined in `seed-common/dotclaude.json`.
  Credentials can come from the flavor env file or be grafted read-only from your
  host `~/.claude.json`.

## Gateway configuration

The gateway flavor is a generic Anthropic-format client pointed at your gateway.

| Var                              | Default                              | Notes                                   |
|----------------------------------|--------------------------------------|-----------------------------------------|
| `ANTHROPIC_BASE_URL`             | `https://your-gateway.example.com`   | Claude **appends `/v1/messages`** — set the base *without* it. Bake via `--build-arg GATEWAY_BASE_URL=…` or override at runtime. |
| `ENABLE_TOOL_SEARCH`             | `true`                               | Re-enables MCP tool search, which Claude disables by default against a non-first-party base URL. |
| `ANTHROPIC_MODEL` + `ANTHROPIC_DEFAULT_*_MODEL` | placeholders (`claude-opus-4-6`, …) | Set to the `model_name` strings your gateway exposes. |
| `apiKeyHelper`                   | `/opt/claude/api-key-helper`         | The wrapper bind-mounts `~/.local/bin/litellm-key-helper` here (read-only). Override the host path with `CLAUDE_GATEWAY_KEY_HELPER`. |

**Auth.** `apiKeyHelper` runs the mounted script; its stdout is sent as both
`X-Api-Key` and `Authorization: Bearer`, so it works whichever header the gateway
reads. Claude caches the token (default 5 min; tune
`CLAUDE_CODE_API_KEY_HELPER_TTL_MS` in `~/.claude-gateway.env`) and re-runs the
helper on an HTTP 401.

**Env file (`~/.claude-gateway.env`).** The credential source of truth. Anything
your key-helper reads from the environment (e.g. a LiteLLM master key) goes here —
it is passed into the container via `--env-file` and is therefore visible to the
helper subprocess. Vars set only in `settings.json` do **not** reach the helper.

**Key-helper runtime deps.** The helper runs *inside* the gateway image, which has
`bash`, `curl`, `jq`, and `python3` but **not** `gcloud`. If your helper shells out
to a CLI that isn't present, add it to the `gateway` stage in the `Dockerfile`.

## Vertex configuration

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

Override per-invocation by exporting env (the wrapper passes it through), or
permanently by editing the `Dockerfile` and rebuilding.

## Verifying which provider you're on

Run `/status` inside Claude:

- **vertex** → `API provider: Google Vertex AI`, `GCP project: vertex-test-495715`.
  Stronger proof: Google Cloud Console → Logging →
  `resource.type="aiplatform.googleapis.com/Endpoint"` filtered to your email.
- **gateway** → the base URL should be your gateway, **not** `api.anthropic.com` or
  Vertex. Confirm a request lands in your gateway's logs.

## Troubleshooting

**`/status` shows the wrong provider** — stale state under
`~/.claude-<flavor>/`. Try `rm -rf ~/.claude-<flavor>` and relaunch.

**vertex: `just auth` fails with browser/URL issues** —
`just reset-auth && just auth`.

**gateway: "key-helper missing or not executable"** — the wrapper refuses to run
until `~/.local/bin/litellm-key-helper` exists and is executable (a missing path
would otherwise be silently mounted as an empty directory). `chmod +x` it, or
point `CLAUDE_GATEWAY_KEY_HELPER` elsewhere.

**gateway: 401 / auth loops** — run `claude-gateway shell` and execute
`/opt/claude/api-key-helper` by hand; it must print a valid token to stdout with
nothing else. Check that the vars it needs are set in `~/.claude-gateway.env`.

**`just doctor` reports problems** — follow its hints (per flavor).

**Permission errors writing to a mounted dir** — the container remaps to your
host UID/GID on Linux; macOS Docker Desktop maps implicitly.

## Uninstall

```sh
just uninstall                  # remove both wrapper symlinks
FLAVOR=gateway just clean       # remove gateway image
just clean                      # remove vertex image
just reset-auth                 # wipe gcloud creds volume
rm -rf ~/.claude-vertex ~/.claude-gateway
```

## License

MIT (or whatever Vida prefers for internal tools — update before publishing).
