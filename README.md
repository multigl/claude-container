# claude-vertex / claude-gateway / claude-personal

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside a
Docker container, isolated from the host's regular `claude`, shell config, and
gcloud setup.

Three flavors build from this one repo:

| Flavor          | Routes through            | Auth                                   |
|-----------------|---------------------------|----------------------------------------|
| **`vertex`**    | Vida's **Vertex AI**      | gcloud ADC (`CLAUDE_CODE_USE_VERTEX=1`)|
| **`gateway`**   | an **LLM gateway** (LiteLLM) | `apiKeyHelper` + `ANTHROPIC_BASE_URL`  |
| **`personal`**  | `api.anthropic.com`       | `claude auth login --claudeai` inside the container |

```sh
cd ~/vida/dbt
claude-vertex     # billed through Vida's Vertex project
claude-gateway    # routed through your LLM gateway
claude-personal   # your own Anthropic account, signed in inside the container
```

## Why a container?

- **Coexists with host `claude`.** Outside the container, normal `claude` keeps
  hitting the Anthropic API under your regular login. Inside, `vertex` and
  `gateway` route elsewhere, and `personal` hits the same Anthropic API but
  under a separate, container-local account and credential.
- **Zero host changes.** No edits to `~/.zshrc`, no shared gcloud config, no extra
  env vars in your shell.
- **Pinned config.** `vertex` and `gateway` bake project, region, gateway URL,
  and model IDs into the image — no interactive `/login` ritual on every
  machine. `personal` is the exception: it signs in with
  `claude auth login --claudeai`, once, inside the container.
- **Flavors don't collide.** Each flavor keeps its own state under
  `~/.local/state/claude-container/<flavor>/`.

## How the three flavors share one build

The `Containerfile` is multi-stage:

```
base ──┬─► vertex    (adds gcloud CLI + Vertex ENV)
       ├─► gateway   (adds ANTHROPIC_BASE_URL + apiKeyHelper, no gcloud)
       └─► personal  (adds nothing baked — auth happens in-container)
```

`base` holds everything common (node, claude-code, uv + mcp-atlassian, the
plugin seed, the `claude` user, the entrypoint). Each flavor stage adds only its
own payload, so the gateway image carries no gcloud, the vertex image keeps its
Vertex pins, and the personal image carries neither. Build a flavor with
`docker build --target <flavor>`.

The host wrapper is a single script, `bin/claude-launcher.sh`, symlinked to
`claude-vertex`, `claude-gateway`, and `claude-personal`; it picks its flavor
from the name it was invoked as (override with `CLAUDE_FLAVOR=...`). All
flavor-specific behavior lives in a driver at `bin/flavors/<flavor>.sh` (see
CLAUDE.md); the wrapper and `justfile` themselves don't know one flavor from
another, and an unrecognized `CLAUDE_FLAVOR` is a hard error.

## Install

One-liner (detects OS/arch + runtime, clones, builds, symlinks
`claude-<flavor>` into `~/.local/bin`):

```sh
curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash
```

Useful flags: `--all` (all three flavors), `--flavor vertex|gateway|personal`,
`--runtime docker|podman|apple`, `--prefix` / `--bin-dir`, `--ref`, `--dry-run`.

### Container runtime

The image runs under docker, podman, or Apple's `container`. The installer and the
`claude-<flavor>` wrapper auto-detect one (priority **apple > docker > podman**,
"available" = installed **and** functional). Force one with
`CLAUDE_RUNTIME=docker|podman|apple`; inspect the choice with
`claude-<flavor> --print-runtime`.

| OS    | docker          | podman          | apple `container`  |
|-------|-----------------|-----------------|--------------------|
| Linux | ✅ if installed | ✅ if installed | —                  |
| macOS | ✅ if installed | ✅ if installed | ✅ if installed    |

Apple `container` needs Apple Silicon + macOS 26+. On such a host without it
installed, the installer **stops** and asks you to install it and re-run — skip that
gate with `--no-apple-gate` (or `CLAUDE_SKIP_APPLE_GATE=1`) to use docker/podman
instead; ineligible hosts fall through automatically.

## Prerequisites

1. **A container runtime** running — docker, podman, or Apple `container`
   (auto-detected; see "Install" above).
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
   - **personal** — an Anthropic account. Nothing to configure ahead of time;
     `claude-personal auth` runs the OAuth flow inside the container and you
     approve it in your host browser.

## Quickstart

```sh
git clone <this-repo> claude-vertex && cd claude-vertex
just build-all      # build all three images (shared base layer is cached)
just install-all    # symlink claude-vertex, claude-gateway, AND claude-personal onto PATH
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

FLAVOR=gateway just auth        # seeds ~/.config/claude-container/gateway/env
$EDITOR ~/.config/claude-container/gateway/env   # set OKTA_CLIENT_ID + ANTHROPIC_BASE_URL
FLAVOR=gateway just auth        # Okta device login — approve the URL in your browser

cd ~/vida/dbt
claude-gateway                  # routed through the gateway
```

### Personal

```sh
FLAVOR=personal just auth       # claude auth login --claudeai, approved in your host browser
cd ~/vida/dbt
claude-personal                 # your own Anthropic account
```

## Commands

The wrapper auto-detects flavor from its name. `just` recipes default to
`FLAVOR=vertex`; prefix `FLAVOR=gateway` to target the gateway flavor.

| Command                  | What it does                                                |
|--------------------------|-------------------------------------------------------------|
| `claude-vertex` / `claude-gateway` / `claude-personal` | Run `claude` against the current directory |
| `claude-<flavor> shell`  | Drop into `bash` inside the container                       |
| `claude-<flavor> -- <args>` | Pass flags through to `claude`                           |
| `claude-<flavor> migrate-memory` | One-time: move the legacy shared memory bucket to this repo's per-project key (run from the repo that owns that history) |
| `claude-<flavor> rebuild-memory-index` | Regenerate the derived `MEMORY.md` index for this repo + the global tier (normally automatic each launch; manual repair) |
| `claude-<flavor> migrate-creds` | One-time: copy an old named cred volume into the new `$STATE_DIR/creds/…` bind dir (docker/podman only) |
| `claude-<flavor> --print-runtime` | Print the resolved container runtime + per-runtime availability |
| `just build`             | Build the `FLAVOR` image (`--target`)                       |
| `just build-vertex` / `build-gateway` / `build-personal` / `build-all` | Build a specific flavor / all three |
| `just rebuild-vertex` / `rebuild-gateway` / `rebuild-personal` / `rebuild-all` | No-cache rebuild of a flavor / all three |
| `just install` / `install-all` | Symlink one / all three flavor commands              |
| `just auth`              | One-time login — vertex: gcloud ADC; gateway: Okta device login; personal: `claude auth login --claudeai` |
| `just reset-auth`        | Wipe the flavor's credential; forces re-auth                |
| `just reseed`            | Overwrite the host config's seeded files (settings + plugins) from the image; preserves history |
| `just test`              | Run the full test suite: the gateway Okta helper `pytest` suite, then `tests/run.sh` |
| `FLAVOR=gateway just doctor` | Self-check for the gateway flavor                       |
| `just doctor`            | Self-check (vertex): runtime, image, cred dir, ADC, PATH    |
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
│        creds: gcloud ADC in $STATE_DIR/creds/gcloud         │
│        ───────► us-east5-aiplatform.googleapis.com           │
│                                                              │
│  $ claude-gateway  ──► container claude-gateway:latest       │
│        env: ANTHROPIC_BASE_URL=<gateway>                     │
│        auth: baked apiKeyHelper mints an Okta id_token;      │
│              refresh_token in $STATE_DIR/creds/okta         │
│        ───────► <gateway>/v1/messages                        │
│                                                              │
│  $ claude-personal ──► container claude-personal:latest      │
│        env: (nothing baked)                                  │
│        auth: claude auth login --claudeai;                   │
│              creds in $STATE_CLAUDE_DIR/.credentials.json    │
│        ───────► api.anthropic.com                            │
└──────────────────────────────────────────────────────────────┘
```

Shared by all three flavors:

- **Per-user state** (`settings.json`, `shell-snapshots`, …) lives in host
  `~/.local/state/claude-container/<flavor>/claude/`, separate from
  `~/.claude`, so the regular host `claude` is never touched and the flavors
  don't collide.
- **Pre-seeded config.** On first launch the entrypoint copies the baked-in
  baseline from `/opt/claude-seed/` (common bits from `seed-common/`, plus the
  flavor's `settings.json`) into the empty
  `~/.local/state/claude-container/<flavor>/claude/`. Seeding is
  idempotent (`rsync --ignore-existing`), so edits survive future starts. To push
  updated seed files (e.g. a new `settings.json` or plugin) into an existing config
  dir, `FLAVOR=<flavor> just reseed` overwrites just those files and keeps your
  history/projects. Re-seed from scratch:
  `rm -rf ~/.local/state/claude-container/<flavor>`.
- **MCP servers** (atlassian, context7) are defined in `seed-common/dotclaude.json`.
  Credentials can come from the flavor env file or be grafted read-only from your
  host `~/.claude.json`. (Vertex seeds atlassian + context7; gateway the same;
  personal seeds context7 only.)

## Git & GitHub inside the container

The container uses your **host** git/GitHub setup — no second login.

- **Git identity is resolved fresh each launch.** The wrapper reads your **host**
  `user.name`/`user.email` (and SSH signing config) with `git -C "$PWD" config
  --get` every launch, so `includeIf gitdir:` (personal-vs-work) picks the right
  values for the current repo. The result is inlined into the container's
  `~/.gitconfig` at boot. Nothing persists between launches; your host
  `~/.gitconfig` is never mounted directly.
- **`gh` + HTTPS push.** The wrapper resolves your GitHub token with
  `gh auth token` (works even when gh stores it in the OS keyring) and injects it
  as `GH_TOKEN`. `gh pr`/`gh api` work, and `gh` is registered as the HTTPS git
  credential helper so HTTPS `git push` works. Use HTTPS remotes.
- **SSH agent forwarding + commit signing (opt-in).** Turn it on per run with
  `CLAUDE_FORWARD_SSH=1`, or persist it in
  `~/.config/claude-container/<flavor>/launcher.conf`:

  ```ini
  forward_ssh = true
  ```

  - **macOS:** requires apple `container` (uses `container run --ssh`, which
    forwards your real agent incl. 1Password). Docker Desktop is **not** supported.
  - **Linux:** works with docker (rootful) and podman (rootless); the host
    `$SSH_AUTH_SOCK` is bind-mounted in.
  - **Signing** is picked up from your host git config automatically when
    `gpg.format = ssh`. Your signing key is used via the forwarded agent; no key
    files are mounted. GitHub host keys are baked in so SSH `git push` works.
  - **gpg/x509 signing (e.g. a yubikey) needs a fallback key.** gpg secret keys
    and x509/smime can't be used in-container at all -- there's no secret key
    material to forward. If your host signs with `gpg.format` unset/openpgp/x509,
    set a separate, ssh, in-container-only signing key via a custom config value,
    `claude-container.signingkey-ssh` (a literal `ssh-...` pubkey or a path to
    one), in the **same** `includeIf gitdir:`-included file as your real
    `user.signingkey` so it travels with that personal/work identity:

    ```ini
    # ~/.gitconfig-work (already includeIf-selected by directory)
    [user]
        signingkey = <your yubikey gpg key id>
    [claude-container]
        signingkey-ssh = ~/.ssh/container_signing.pub
    ```

    The container then commits signed with that ssh key instead of skipping
    signing. Still requires `forward_ssh = true` above -- the matching private
    key must live only in your host ssh-agent, never in the container.

## File locations (XDG)

Wrapper files live in an XDG split under the `claude-container` namespace. This
was renamed from an earlier namespace; the launcher migrates a flavor's
directories to the new name the first time it runs after upgrading (config and
state moved separately, each only if the new path doesn't already exist) and
prints what it moved. `just doctor` warns if anything is still left behind
under the old name.

    $XDG_CONFIG_HOME/claude-container/<flavor>/   # you edit these; back them up
    ├── env                     # MCP creds / endpoints (chmod 600)
    ├── mounts                  # extra host dirs to expose (one host path per line; see CLAUDE.md for the format)
    ├── launcher.conf           # host-side launcher settings (e.g. forward_ssh)
    └── settings.override.json  # optional Claude settings deltas, e.g. {"model": "..."}

    $XDG_STATE_HOME/claude-container/<flavor>/    # machine-managed; disposable
    ├── claude/                 # seeded config -> container ~/.claude
    │   ├── claude.json         # trust flags, mcpServers, grafted MCP creds (container ~/.claude.json, symlinked)
    │   ├── .credentials.json   # personal only: OAuth token, written by claude-code itself (plaintext; see "Personal auth" below)
    │   └── memory-global/      # per-flavor global memory tier (cross-project facts)
    ├── creds/                  # vertex/gateway only: auth caches (bind dirs, not named volumes)
    │   ├── gcloud/             # vertex: gcloud ADC       -> container ~/.config/gcloud
    │   └── okta/               # gateway: Okta token cache -> container ~/.local/share/litellm
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
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-container/$flavor"
    state="${XDG_STATE_HOME:-$HOME/.local/state}/claude-container/$flavor"
    mkdir -p "$cfg" "$state"
    mv ~/.claude-$flavor.env       "$cfg/env"        2>/dev/null || true
    mv ~/.claude-$flavor.mounts    "$cfg/mounts"     2>/dev/null || true
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
| `apiKeyHelper`                   | `/opt/claude/api-key-helper`         | Baked Okta helper (`gateway/okta_token_helper.py`, python3-only). Mints/refreshes an Okta **id_token** (JWT); token cache lives in `$STATE_DIR/creds/okta` (bind dir → container `~/.local/share/litellm`). |
| `OKTA_ISSUER`                    | `https://vida.okta.com`              | Okta **Org** authorization server (no `/oauth2/<id>`). Set in `~/.config/claude-container/gateway/env`. |
| `OKTA_CLIENT_ID`                 | —                                    | The Okta **Native app** `client_id`; must equal LiteLLM's `JWT_AUDIENCE`. Set in `~/.config/claude-container/gateway/env`. |

**Auth (one-time device login).** `FLAVOR=gateway just auth` runs the baked helper
with `--login-only`: it prints an Okta verification URL (approve it in your host
browser), then stores a `refresh_token` in `$STATE_DIR/creds/okta`.
Afterwards the helper serves a cached `id_token` and silently refreshes it (re-running
on HTTP 401); Claude sends the `id_token` as the bearer. Refresh tokens expire after
~7 days idle — re-login with `FLAVOR=gateway just reset-auth` then `just auth`.

**LiteLLM side (outside this repo).** The gateway JWT-validates the Org id_token:
`JWT_ISSUER=https://vida.okta.com`, `JWT_AUDIENCE=<OKTA_CLIENT_ID>`, JWKS
`https://vida.okta.com/oauth2/v1/keys`. (Vida's Okta has only the Org server, which
issues ID tokens — not custom-API access tokens — hence the id_token-as-bearer design.)

**Env file (`~/.config/claude-container/gateway/env`).** Holds `OKTA_ISSUER`, `OKTA_CLIENT_ID`,
`ANTHROPIC_BASE_URL`, and `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`, passed into the
container via `--env-file` so the helper reads them. Vars set only in `settings.json`
do **not** reach the helper.

**Helper tests.** `just test` runs the `pytest` suite in `tests/` against
`gateway/okta_token_helper.py` (cache/refresh/rotation/device-login paths).

## Vertex configuration

The image sets the provider basics; the **model + region pins live in the seeded
env file** (`~/.config/claude-container/vertex/env`), passed in via
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
kill and reopen the session (env is read once at container start).

## Personal auth

The personal flavor signs Claude Code in to a real Anthropic account, from
inside the container, instead of routing through Vertex or a gateway.

**Auth (one-time OAuth login).** `FLAVOR=personal just auth` (or
`claude-personal auth`) runs `claude auth login --claudeai` inside the
container. It prints a URL — approve it in your host browser. There's nothing
to configure beforehand: no project ID, no gateway URL, no Okta app.

**The credential is plaintext.** Claude Code writes the token to
`~/.local/state/claude-container/personal/claude/.credentials.json` on the
host, unencrypted. That's not a choice this repo made — a Linux container has
no keychain to store it in, and Claude Code doesn't expose a credential-helper
hook that could supply one. On a Linux host this is no different from a normal
`claude` install, which also keeps its token in a plaintext
`~/.claude/.credentials.json`. **On macOS it's a downgrade**: the host's
regular `claude` keeps its token in the Keychain, and this one doesn't.

The mitigation is filesystem permissions, not encryption: the launcher
`chmod 700`s the state directory on every launch, and Claude Code itself
writes the credential file `0600`. `FLAVOR=personal just doctor` checks both
and warns if either has drifted. `FLAVOR=personal just reset-auth` deletes the
credential file outright.

## Verifying which provider you're on

Run `/status` inside Claude:

- **vertex** → `API provider: Google Vertex AI`, `GCP project: vertex-test-495715`.
  Stronger proof: Google Cloud Console → Logging →
  `resource.type="aiplatform.googleapis.com/Endpoint"` filtered to your email.
- **gateway** → the base URL should be your gateway, **not** `api.anthropic.com` or
  Vertex. Confirm a request lands in your gateway's logs.
- **personal** → no Vertex project, no gateway base URL; the signed-in account
  is whichever one you completed `claude auth login --claudeai` with.

## Troubleshooting

**`/status` shows the wrong provider** — stale state under
`~/.local/state/claude-container/<flavor>/`. Try
`rm -rf ~/.local/state/claude-container/<flavor>` and relaunch.

**vertex: `just auth` fails with browser/URL issues** —
`just reset-auth && just auth`.

**gateway: "not a terminal; run okta-token-helper once to log in"** — you haven't
done the device login. Run `FLAVOR=gateway just auth` and approve the URL in your
browser. `FLAVOR=gateway just doctor` confirms the token cache exists.

**gateway: 401 / auth loops** — the refresh token is likely expired or revoked.
Re-login: `FLAVOR=gateway just reset-auth` then `FLAVOR=gateway just auth`. To
inspect, `claude-gateway shell` then run `/opt/claude/api-key-helper` by hand — it
prints the `id_token` to stdout and diagnostics to stderr.

**personal: logged out, or `.credentials.json` permissions warning** —
`FLAVOR=personal just reset-auth` then `FLAVOR=personal just auth`.
`FLAVOR=personal just doctor` reports whether the credential is present and
whether its permissions (or the state directory's) have drifted from `0600`/`0700`.

**`just doctor` reports problems** — follow its hints (per flavor).

**Permission errors writing to a mounted dir** — under docker on Linux the
container remaps to your host UID/GID; podman uses `--userns=keep-id`; macOS
(Docker Desktop / Apple `container`) maps implicitly via its VM file share.

## Uninstall

```sh
just uninstall                  # remove all three wrapper symlinks
FLAVOR=gateway just clean       # remove gateway image
FLAVOR=personal just clean      # remove personal image
just clean                      # remove vertex image
just reset-auth                 # wipe the flavor's credential
rm -rf ~/.config/claude-container ~/.local/state/claude-container
```

## License

MIT (or whatever Vida prefers for internal tools — update before publishing).
