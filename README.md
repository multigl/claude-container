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

FLAVOR=gateway just auth        # seeds ~/.claude-gateway.env on first run
$EDITOR ~/.claude-gateway.env   # set OKTA_CLIENT_ID + ANTHROPIC_BASE_URL
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
  `~/.claude-<flavor>/`, separate from `~/.claude`, so the regular host `claude`
  is never touched and the two flavors don't collide.
- **Pre-seeded config.** On first launch the entrypoint copies the baked-in
  baseline from `/opt/claude-seed/` (common bits from `seed-common/`, plus the
  flavor's `settings.json`) into the empty `~/.claude-<flavor>/`. Seeding is
  idempotent (`rsync --ignore-existing`), so edits survive future starts. To push
  updated seed files (e.g. a new `settings.json` or plugin) into an existing config
  dir, `FLAVOR=<flavor> just reseed` overwrites just those files and keeps your
  history/projects. Re-seed from scratch: `rm -rf ~/.claude-<flavor>`.
- **MCP servers** (atlassian, context7) are defined in `seed-common/dotclaude.json`.
  Credentials can come from the flavor env file or be grafted read-only from your
  host `~/.claude.json`.

## Git & GitHub inside the container

The container uses your **host** git/GitHub setup — no second login.

- **Identity.** On first launch the wrapper seeds `~/.claude-<flavor>.gitconfig`,
  prefilled from your host `git config` (resolved in the repo dir, so folder-scoped
  `includeIf` values are honored). Edit it freely; it persists. Delete it to
  re-seed. It's mounted read-only and included by the container's generated
  `~/.gitconfig`. (Your host `~/.gitconfig` is **not** mounted directly — its
  `includeIf gitdir:` conditions and host-only paths don't apply in the container.)
- **`gh` + HTTPS push.** The wrapper resolves your GitHub token with
  `gh auth token` (works even when gh stores it in the OS keyring) and injects it
  as `GH_TOKEN`. `gh pr`/`gh api` work, and `gh` is registered as the HTTPS git
  credential helper so HTTPS `git push` works. SSH remotes are unaffected.
- **Commit signing is OFF by default** (avoids GPG/YubiKey/agent friction). To sign
  with SSH: in `~/.claude-<flavor>.gitconfig` set `signingkey` to your SSH signing
  public key and uncomment the `[gpg] format = ssh` and `[commit] gpgsign = true`
  blocks, then launch with the agent forwarded (below).
- **SSH agent forwarding (opt-in)** — for SSH signing and SSH `git push`:

  ```sh
  CLAUDE_FORWARD_SSH_AGENT=1 claude-vertex
  ```

  - **Linux:** forwards `$SSH_AUTH_SOCK` directly.
  - **macOS/Docker Desktop:** uses the synthesized `/run/host-services/ssh-auth.sock`.
    **Prerequisite:** run `launchctl setenv SSH_AUTH_SOCK "$SSH_AUTH_SOCK"` (pointing
    at your 1Password agent socket) and restart Docker Desktop, so launchd exposes
    the agent to Docker. Verify inside the container with `ssh-add -l`.

## File locations (XDG)

Wrapper files live in an XDG split under the `vida-claude-container` namespace:

    $XDG_CONFIG_HOME/vida-claude-container/<flavor>/   # you edit these; back them up
    ├── env                     # MCP creds / endpoints (chmod 600)
    ├── mounts                  # extra host dirs to expose (see below)
    ├── gitconfig               # git identity used in the container (chmod 600)
    └── settings.override.json  # optional Claude settings deltas, e.g. {"model": "..."}

    $XDG_STATE_HOME/vida-claude-container/<flavor>/    # machine-managed; disposable
    ├── claude/                 # history, projects, seeded config -> container ~/.claude
    └── claude.json             # trust flags, mcpServers, grafted MCP creds

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
    mv ~/.claude-$flavor.json     "$state/claude.json" 2>/dev/null || true

## Gateway configuration

The gateway flavor is a generic Anthropic-format client pointed at your gateway.

| Var                              | Default                              | Notes                                   |
|----------------------------------|--------------------------------------|-----------------------------------------|
| `ANTHROPIC_BASE_URL`             | `https://your-gateway.example.com`   | Claude **appends `/v1/messages`** — set the base *without* it. Bake via `--build-arg GATEWAY_BASE_URL=…` or override at runtime. |
| `ENABLE_TOOL_SEARCH`             | `true`                               | Re-enables MCP tool search, which Claude disables by default against a non-first-party base URL. |
| `ANTHROPIC_MODEL` + `ANTHROPIC_DEFAULT_*_MODEL` | placeholders (`claude-opus-4-6`, …) | Set to the `model_name` strings your gateway exposes. |
| `apiKeyHelper`                   | `/opt/claude/api-key-helper`         | Baked Okta helper (`gateway/okta_token_helper.py`, python3-only). Mints/refreshes an Okta **id_token** (JWT); token cache lives in the `claude-gateway-okta` docker volume. |
| `OKTA_ISSUER`                    | `https://vida.okta.com`              | Okta **Org** authorization server (no `/oauth2/<id>`). Set in `~/.claude-gateway.env`. |
| `OKTA_CLIENT_ID`                 | —                                    | The Okta **Native app** `client_id`; must equal LiteLLM's `JWT_AUDIENCE`. Set in `~/.claude-gateway.env`. |

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

**Env file (`~/.claude-gateway.env`).** Holds `OKTA_ISSUER`, `OKTA_CLIENT_ID`,
`ANTHROPIC_BASE_URL`, and `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`, passed into the
container via `--env-file` so the helper reads them. Vars set only in `settings.json`
do **not** reach the helper.

**Helper tests.** `just test` runs the `pytest` suite in `tests/` against
`gateway/okta_token_helper.py` (cache/refresh/rotation/device-login paths).

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
rm -rf ~/.claude-vertex ~/.claude-gateway
```

## License

MIT (or whatever Vida prefers for internal tools — update before publishing).
