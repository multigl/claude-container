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
  `~/.local/state/vida-claude-container/vertex/` vs
  `~/.local/state/vida-claude-container/gateway/`.

## How the two flavors share one build

The `Containerfile` is multi-stage:

```
base ──┬─► vertex    (adds gcloud CLI + Vertex ENV)
       └─► gateway   (adds ANTHROPIC_BASE_URL + apiKeyHelper, no gcloud)
```

`base` holds everything common (node, claude-code, uv + mcp-atlassian, the
plugin seed, the `claude` user, the entrypoint). Each flavor stage adds only its
own payload, so the gateway image carries no gcloud and the vertex image keeps
its Vertex pins. Build a flavor with `docker build --target <flavor>`.

The host wrapper is a single script, `bin/claude-launcher.sh`, symlinked to both
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
   - **gateway** — your gateway's base URL, plus an Okta **Native app**
     `client_id` + `issuer`. A one-time browser device login mints the token;
     no host helper script is needed (it's baked into the image).

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
just build-gateway              # (optionally bake a default URL with
                                #  docker build --target gateway
                                #    --build-arg GATEWAY_BASE_URL=https://gateway.internal ...)

FLAVOR=gateway just auth        # seeds ~/.config/vida-claude-container/gateway/env
$EDITOR ~/.config/vida-claude-container/gateway/env   # set OKTA_CLIENT_ID + ANTHROPIC_BASE_URL
FLAVOR=gateway just auth        # Okta device login — approve the URL in your browser

cd ~/vida/dbt
claude-gateway                  # routed through the gateway
```

## Commands

The wrapper auto-detects flavor from its name. `just` recipes default to
`FLAVOR=vertex`; prefix `FLAVOR=gateway` to target the gateway flavor.

| Command                  | What it does                                                |
|--------------------------|-------------------------------------------------------------|
| `claude-vertex` / `claude-gateway` | Run `claude` against the current directory        |
| `claude-<flavor> shell`  | Drop into `bash` inside the container                       |
| `claude-<flavor> -- <args>` | Pass flags through to `claude`                           |
| `claude-<flavor> migrate-memory` | One-time: move the legacy shared memory bucket to this repo's per-project key (run from the repo that owns that history) |
| `claude-<flavor> rebuild-memory-index` | Regenerate the derived `MEMORY.md` index for this repo + the global tier (normally automatic each launch; manual repair) |
| `just build`             | Build the `FLAVOR` image (`--target`)                       |
| `just build-vertex` / `build-gateway` / `build-all` | Build a specific flavor / both |
| `just rebuild-vertex` / `rebuild-gateway` / `rebuild-all` | No-cache rebuild of a flavor / both |
| `just install` / `install-all` | Symlink one / both flavor commands                   |
| `just auth`              | One-time login — vertex: gcloud ADC; gateway: Okta device login |
| `just reset-auth`        | Wipe the flavor's credential volume; forces re-auth         |
| `just reseed`            | Overwrite the host config's seeded files (settings + plugins) from the image; preserves history |
| `just test`              | Run the gateway Okta helper `pytest` suite                  |
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
│        auth: baked apiKeyHelper mints an Okta id_token;      │
│              refresh_token cached in a docker volume        │
│        ───────► <gateway>/v1/messages                        │
└──────────────────────────────────────────────────────────────┘
```

Shared by both flavors:

- **Per-user state** (`settings.json`, `shell-snapshots`, …) lives in host
  `~/.local/state/vida-claude-container/<flavor>/claude/`, separate from
  `~/.claude`, so the regular host `claude` is never touched and the two
  flavors don't collide.
- **Pre-seeded config.** On first launch the entrypoint copies the baked-in
  baseline from `/opt/claude-seed/` (common bits from `seed-common/`, plus the
  flavor's `settings.json`) into the empty
  `~/.local/state/vida-claude-container/<flavor>/claude/`. Seeding is
  idempotent (`rsync --ignore-existing`), so edits survive future starts. To push
  updated seed files (e.g. a new `settings.json` or plugin) into an existing config
  dir, `FLAVOR=<flavor> just reseed` overwrites just those files and keeps your
  history/projects. Re-seed from scratch:
  `rm -rf ~/.local/state/vida-claude-container/<flavor>`.
- **MCP servers** (atlassian, context7) are defined in `seed-common/dotclaude.json`.
  Credentials can come from the flavor env file or be grafted read-only from your
  host `~/.claude.json`.

## Git & GitHub inside the container

The container uses your **host** git/GitHub setup — no second login.

- **Identity.** On first launch the wrapper seeds
  `~/.config/vida-claude-container/<flavor>/gitconfig`,
  prefilled from your host `git config` (resolved in the repo dir, so folder-scoped
  `includeIf` values are honored). Edit it freely; it persists. Delete it to
  re-seed. It's mounted read-only and included by the container's generated
  `~/.gitconfig`. (Your host `~/.gitconfig` is **not** mounted directly — its
  `includeIf gitdir:` conditions and host-only paths don't apply in the container.)
- **`gh` + HTTPS push.** The wrapper resolves your GitHub token with
  `gh auth token` (works even when gh stores it in the OS keyring) and injects it
  as `GH_TOKEN`. `gh pr`/`gh api` work, and `gh` is registered as the HTTPS git
  credential helper so HTTPS `git push` works. Use HTTPS remotes.
- **SSH agent forwarding / commit signing: not currently supported.** It was removed
  pending a cross-platform (docker / podman / apple-container) bring-your-own-provider
  redesign. Docker Desktop's `host-services` agent bridge does not forward the
  1Password agent (Apple `container --ssh` does), so the old socket-mount approach was
  dropped rather than shipped half-working. Push over HTTPS in the meantime; sign
  commits on the host.

## File locations (XDG)

Wrapper files live in an XDG split under the `vida-claude-container` namespace:

    $XDG_CONFIG_HOME/vida-claude-container/<flavor>/   # you edit these; back them up
    ├── env                     # MCP creds / endpoints (chmod 600)
    ├── mounts                  # extra host dirs to expose (one host path per line; see CLAUDE.md for the format)
    ├── gitconfig               # git identity used in the container (chmod 600)
    └── settings.override.json  # optional Claude settings deltas, e.g. {"model": "..."}

    $XDG_STATE_HOME/vida-claude-container/<flavor>/    # machine-managed; disposable
    ├── claude/                 # seeded config -> container ~/.claude
    │   ├── claude.json         # trust flags, mcpServers, grafted MCP creds (container ~/.claude.json, symlinked)
    │   └── memory-global/      # per-flavor global memory tier (cross-project facts)
    └── projects/<key>/         # per-repo memory + /resume history, keyed on host $PWD
                                 # (see `claude-<flavor> migrate-memory` / `rebuild-memory-index`)

(Defaults: `$XDG_CONFIG_HOME` → `~/.config`, `$XDG_STATE_HOME` → `~/.local/state`.)

### settings.override.json

Drop a small JSON file of Claude settings deltas here to tweak behavior without
editing the repo seed. It is deep-merged onto the seeded `settings.json` on every
launch. Example — test a new model in your Vertex project:

    { "model": "claude-sonnet-6@your-project-region" }

Then restart the container. Two caveats: array keys (e.g. `permissions.allow`) are
**replaced**, not merged; and **removing** a key from the override won't revert the
active value until you `just reseed` (changing a value works on the next launch).

### Migration from the old `~/.claude-<flavor>*` layout

Earlier builds stored these files directly in `$HOME`. There is no automated
migration; move them by hand once (per flavor):

    flavor=vertex   # or gateway
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/vida-claude-container/$flavor"
    state="${XDG_STATE_HOME:-$HOME/.local/state}/vida-claude-container/$flavor"
    mkdir -p "$cfg" "$state"
    mv ~/.claude-$flavor.env       "$cfg/env"        2>/dev/null || true
    mv ~/.claude-$flavor.mounts    "$cfg/mounts"     2>/dev/null || true
    mv ~/.claude-$flavor.gitconfig "$cfg/gitconfig"  2>/dev/null || true
    mv ~/.claude-$flavor          "$state/claude"    2>/dev/null || true
    mkdir -p "$state/claude"
    mv ~/.claude-$flavor.json     "$state/claude/claude.json" 2>/dev/null || true

## Gateway configuration

The gateway flavor is a generic Anthropic-format client pointed at your gateway.

| Var                              | Default                              | Notes                                   |
|----------------------------------|--------------------------------------|-----------------------------------------|
| `ANTHROPIC_BASE_URL`             | `https://your-gateway.example.com`   | Claude **appends `/v1/messages`** — set the base *without* it. Bake via `--build-arg GATEWAY_BASE_URL=…` or override at runtime. |
| `ENABLE_TOOL_SEARCH`             | `true`                               | Re-enables MCP tool search, which Claude disables by default against a non-first-party base URL. |
| `ANTHROPIC_MODEL` + `ANTHROPIC_DEFAULT_*_MODEL` | placeholders (`claude-opus-4-6`, …) | Set to the `model_name` strings your gateway exposes. |
| `apiKeyHelper`                   | `/opt/claude/api-key-helper`         | Baked Okta helper (`gateway/okta_token_helper.py`, python3-only). Mints/refreshes an Okta **id_token** (JWT); token cache lives in the `claude-gateway-okta` docker volume. |
| `OKTA_ISSUER`                    | `https://vida.okta.com`              | Okta **Org** authorization server (no `/oauth2/<id>`). Set in `~/.config/vida-claude-container/gateway/env`. |
| `OKTA_CLIENT_ID`                 | —                                    | The Okta **Native app** `client_id`; must equal LiteLLM's `JWT_AUDIENCE`. Set in `~/.config/vida-claude-container/gateway/env`. |

**Auth (one-time device login).** `FLAVOR=gateway just auth` runs the baked helper
with `--login-only`: it prints an Okta verification URL (approve it in your host
browser), then stores a `refresh_token` in the `claude-gateway-okta` volume.
Afterwards the helper serves a cached `id_token` and silently refreshes it (re-running
on HTTP 401); Claude sends the `id_token` as the bearer. Refresh tokens expire after
~7 days idle — re-login with `FLAVOR=gateway just reset-auth` then `just auth`.

**LiteLLM side (outside this repo).** The gateway JWT-validates the Org id_token:
`JWT_ISSUER=https://vida.okta.com`, `JWT_AUDIENCE=<OKTA_CLIENT_ID>`, JWKS
`https://vida.okta.com/oauth2/v1/keys`. (Vida's Okta has only the Org server, which
issues ID tokens — not custom-API access tokens — hence the id_token-as-bearer design.)

**Env file (`~/.config/vida-claude-container/gateway/env`).** Holds `OKTA_ISSUER`, `OKTA_CLIENT_ID`,
`ANTHROPIC_BASE_URL`, and `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`, passed into the
container via `--env-file` so the helper reads them. Vars set only in `settings.json`
do **not** reach the helper.

**Helper tests.** `just test` runs the `pytest` suite in `tests/` against
`gateway/okta_token_helper.py` (cache/refresh/rotation/device-login paths).

## Vertex configuration

The image sets the provider basics; the **model + region pins live in the seeded
env file** (`~/.config/vida-claude-container/vertex/env`), passed in via
`--env-file` (which overrides image ENV).

| Var                              | Value                     | Where                 |
|----------------------------------|---------------------------|-----------------------|
| `CLAUDE_CODE_USE_VERTEX`         | `1`                       | image ENV             |
| `ANTHROPIC_VERTEX_PROJECT_ID`    | `vertex-test-495715`      | image ENV             |
| `CLOUD_ML_REGION`                | `us`                      | image ENV + env file  |
| `ANTHROPIC_MODEL`                | `claude-opus-4-8[1m]`     | seeded env file       |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`   | `claude-opus-4-8[1m]`     | seeded env file       |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `claude-sonnet-5`         | seeded env file       |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL`  | `claude-haiku-4-5`        | seeded env file       |
| `VERTEX_REGION_CLAUDE_HAIKU_4_5` | `us-east5`                | seeded env file       |

**US-only (Vida compliance).** Opus 4.8 + Sonnet 5 aren't served on single
regions like `us-east5`; they need `global`/multi-region, so they ride the `us`
multi-region. Haiku 4.5 → `us-east5` via the per-model override (also US). Never
route to a non-US region.

**Why pin.** Unpinned on Vertex, the small/fast (background) model defaults to
`claude-sonnet-4-5` — which `429`s if your project can't invoke it, and it powers
session titles + web-search summarization. Pinning the aliases removes that reach.
Pinning also restores the **1M context window**: append `[1m]` to a model ID
(Opus 4.8 here); Sonnet 5 always runs 1M, no suffix.

Override per-invocation by exporting env (the wrapper passes it through), or edit
the env file. **Existing installs:** the env file is seeded only when absent and
`reseed` does not rewrite it — hand-add the rows above to your live env file, then
kill and reopen the session (env is read once at `docker run`).

## Verifying which provider you're on

Run `/status` inside Claude:

- **vertex** → `API provider: Google Vertex AI`, `GCP project: vertex-test-495715`.
  Stronger proof: Google Cloud Console → Logging →
  `resource.type="aiplatform.googleapis.com/Endpoint"` filtered to your email.
- **gateway** → the base URL should be your gateway, **not** `api.anthropic.com` or
  Vertex. Confirm a request lands in your gateway's logs.

## Troubleshooting

**`/status` shows the wrong provider** — stale state under
`~/.local/state/vida-claude-container/<flavor>/`. Try
`rm -rf ~/.local/state/vida-claude-container/<flavor>` and relaunch.

**vertex: `just auth` fails with browser/URL issues** —
`just reset-auth && just auth`.

**gateway: "not a terminal; run okta-token-helper once to log in"** — you haven't
done the device login. Run `FLAVOR=gateway just auth` and approve the URL in your
browser. `FLAVOR=gateway just doctor` confirms the token cache exists.

**gateway: 401 / auth loops** — the refresh token is likely expired or revoked.
Re-login: `FLAVOR=gateway just reset-auth` then `FLAVOR=gateway just auth`. To
inspect, `claude-gateway shell` then run `/opt/claude/api-key-helper` by hand — it
prints the `id_token` to stdout and diagnostics to stderr.

**`just doctor` reports problems** — follow its hints (per flavor).

**Permission errors writing to a mounted dir** — the container remaps to your
host UID/GID on Linux; macOS Docker Desktop maps implicitly.

## Uninstall

```sh
just uninstall                  # remove both wrapper symlinks
FLAVOR=gateway just clean       # remove gateway image
just clean                      # remove vertex image
just reset-auth                 # wipe gcloud creds volume
rm -rf ~/.config/vida-claude-container ~/.local/state/vida-claude-container
```

## License

MIT (or whatever Vida prefers for internal tools — update before publishing).
