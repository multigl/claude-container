# claude-vertex / claude-gateway / claude-personal

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside a
container, isolated from the host's regular `claude`, shell config, and gcloud
setup.

It comes in three flavors:

| Flavor          | Routes through            | Auth                                   |
|-----------------|---------------------------|----------------------------------------|
| **`vertex`**    | Vertex AI                 | gcloud ADC, logged in inside the container |
| **`gateway`**   | an LLM gateway (LiteLLM)  | Okta device login via a baked `apiKeyHelper` |
| **`personal`**  | `api.anthropic.com`       | `claude auth login --claudeai` inside the container |

```sh
cd ~/src/some-repo
claude-vertex     # billed through your Vertex project
claude-gateway    # routed through your LLM gateway
claude-personal   # your own Anthropic account, signed in inside the container
```

## Why a container?

- **Your regular `claude` is untouched.** It keeps its own login and state.
  Each flavor has separate state under `~/.local/state/claude-container/<flavor>/`,
  so flavors don't collide with it or with each other.
- **No host changes.** Nothing edits `~/.zshrc`, your gcloud config, or your
  shell environment.
- **Endpoints come pre-wired.** `vertex` and `gateway` know their provider and
  model pins out of the box. You supply a project ID or gateway URL once.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash
```

That installs the **personal** flavor. Add `--all` for all three, or
`--flavor vertex|gateway|personal` for one. Other flags: `--runtime
docker|podman|apple`, `--bin-dir`, `--dry-run`.

The installer downloads one prebuilt binary, `claude-container`, from the latest
GitHub Release, checks its SHA-256, and puts it in `~/.local/bin`. It symlinks
`claude-<flavor>` beside it and pulls the matching image from
`ghcr.io/multigl/claude-container`. Nothing gets built on your machine. That
matters behind network filters like Zscaler, where a container build can't reach
apt or npm but a registry pull works.

You need:

1. **A container runtime:** docker, podman, or Apple's `container`.
2. **`~/.local/bin` on your `PATH`**, or pass `--bin-dir`.

Each binary is pinned to the image it was released with, so the two never drift
apart. The wrapper picks a runtime in this order: Apple `container`, then docker, then
podman. "Available" means installed and working.

| OS    | docker | podman | Apple `container` |
|-------|--------|--------|-------------------|
| Linux | yes    | yes    | no                |
| macOS | yes    | yes    | Apple Silicon, macOS 26+ |

On a Mac that could run Apple `container` but doesn't have it, the installer
stops and asks you to install it. Pass `--no-apple-gate` to use docker or podman
instead. Force a runtime any time with `CLAUDE_RUNTIME=docker|podman|apple`.

### Upgrading an existing install

Earlier installs were a git clone of bash scripts, with config split across
`launcher.conf`, `env` and `mounts`. The old `update` can't fetch the binary, so
re-run the install one-liner once:

```sh
curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash
```

It finds every `claude-<flavor>` command that still points into the old clone
and relinks and updates each one, so `claude-vertex` and `claude-gateway` come
along without extra flags. To pass flags through the pipe, use `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash -s -- --all
curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash -s -- --flavor vertex
```

The installer runs `claude-<flavor> update` for each flavor, which converts the
old files into `config.toml`. `update` leaves `launcher.conf`, `env` and
`mounts` where they are. Check `config.toml`, then delete them. Until
`config.toml` exists, launching refuses and tells you to run `update`.

Once the re-install has finished, delete the old clone at
`~/.local/share/claude-container/src`.

## First run

Each flavor needs a one-time login. Vertex and gateway also need one setting
before they can serve a request.

### Personal

```sh
claude-personal auth            # prints a URL; approve it in your browser
cd ~/src/some-repo
claude-personal
```

Nothing to configure first. See [the personal reference](#personal-1) for where
the token lives.

### Vertex

```sh
claude-vertex auth                                # gcloud login: open the URL, paste the code back
$EDITOR ~/.config/claude-container/vertex/config.toml   # uncomment and set ANTHROPIC_VERTEX_PROJECT_ID under [env]
cd ~/src/some-repo
claude-vertex
```

The project ID is required. Until you set it, every request fails and the
container prints a banner at launch saying so.

### Gateway

```sh
claude-gateway auth                               # first run seeds config.toml
$EDITOR ~/.config/claude-container/gateway/config.toml   # under [env]: ANTHROPIC_BASE_URL, OKTA_ISSUER, OKTA_CLIENT_ID
claude-gateway auth                               # Okta device login; approve the URL in your browser
cd ~/src/some-repo
claude-gateway
```

## Everyday use

The wrapper reads its flavor from the name you call it by.

| Command | What it does |
|---------|--------------|
| `claude-<flavor>` | Run `claude` in the current directory |
| `claude-<flavor> -- <args>` | Pass flags through to `claude` |
| `claude-<flavor> shell` | Open `bash` inside the container |
| `claude-<flavor> update` | Update the binary to the latest release, then pull its image |
| `claude-<flavor> doctor` | Check the runtime, image, credentials, `PATH`, and memory |
| `claude-<flavor> auth` | Log in (one-time, or after `reset-auth`) |
| `claude-<flavor> reset-auth` | Delete the flavor's stored credential |
| `claude-<flavor> reseed` | Overwrite seeded settings and plugins with the image's copies; keeps history |
| `claude-<flavor> --version` | Show the release version and the image it is pinned to |
| `claude-<flavor> --print-paths` | Show every resolved path, the image, and the runtime |
| `claude-<flavor> --print-runtime` | Show the chosen runtime and which ones are available |

New releases land on every merge to `main` that changes more than docs, and a weekly job publishes one when a
new claude-code ships. Each release is a binary plus the images it runs. Run
`claude-<flavor> update` to pick it up.
(`claude-<flavor> -- update` still reaches Claude Code's own `update` command,
which is disabled in the image.)

Your current directory is mounted at `/workspace`. Memory and `/resume` history
are kept per host directory, so each repo gets its own.

## Configuration

Each flavor reads one file, `~/.config/claude-container/<flavor>/config.toml`
(`$XDG_CONFIG_HOME` if set). The first run seeds it with the flavor's defaults,
commented. It can hold credentials, so the wrapper keeps it at `0600`. Point
`CLAUDE_CONFIG` at a different path to use a file from your dotfiles. That file
must exist, and the wrapper never seeds into it.

```toml
# Run a different image than the one this binary is pinned to,
# e.g. one you built locally with `just build`.
image = "claude-personal:latest"

# Forward your host SSH agent (for SSH push and SSH commit signing).
forward_ssh = true

# DNS servers for the container.
dns = ["1.1.1.1", "8.8.8.8"]

# Environment for the container: endpoints, model pins, MCP credentials.
[env]
ANTHROPIC_MODEL = "claude-opus-5[1m]"
CONTEXT7_API_KEY = ""

# Extra host directories, at /mnt/approved/<basename>. Read-only by default.
[[mounts]]
path = "~/src/shared-notes"

[[mounts]]
path = "~/scratch"
rw = true
```

Every key is optional. Unknown top-level keys produce a warning that lists the
known ones, and TOML syntax errors stop the launch with a line number.

Some settings can also be set per run with an environment variable, which wins
over the file. Precedence is environment variable, then `config.toml`, then the
default.

| Setting | `config.toml` | Per-run override |
|---------|---------------|------------------|
| Image | `image` | `CLAUDE_IMAGE` |
| SSH agent forwarding | `forward_ssh` | `CLAUDE_FORWARD_SSH` |
| DNS servers | `dns` | `CLAUDE_DNS` |
| Container runtime | | `CLAUDE_RUNTIME` |
| Flavor | | `CLAUDE_FLAVOR` |
| Path to `config.toml` | | `CLAUDE_CONFIG` |
| Path to `settings.override.json` | | `CLAUDE_SETTINGS` |

**`image`.** Without it, the wrapper runs the image its binary was released
with. `update` pulls that pinned image and warns if an override means you won't
run it.

**`dns`.** Use it when lookups time out inside the container but work on the host.
We've seen this with Apple `container` behind Zscaler: the VM's default resolver
(`192.168.64.1`) times out, but DNS sent straight to a public resolver works.
Values that aren't IP addresses are ignored.

**`forward_ssh`.** Works with Apple `container` on macOS (it forwards your real
agent, including 1Password), and with docker or podman on Linux. Docker Desktop
on macOS can't forward the agent, so the wrapper warns and skips it there. See
[Git & GitHub](#git--github-inside-the-container) for signing.

**`[env]`.** Read once at container start, so edits need a fresh session. Values
must be strings, and a value can't contain a newline. The seeded file holds the
flavor's defaults and blank MCP credential lines (`CONTEXT7_API_KEY`, plus
`JIRA_*` and `CONFLUENCE_*` for vertex and gateway). The wrapper never rewrites it
after that, not even on `reseed`. MCP credentials can also come from your host
`~/.claude.json`, which the container reads at boot.

**`[[mounts]]`.** Only `$PWD` is mounted by default. A leading `~` is expanded.
A missing directory, or two entries with the same basename, is skipped with a
warning.

### settings.override.json

Claude Code settings, deep-merged onto the seeded `settings.json` at every
launch. It stays a separate JSON file rather than part of `config.toml`, because
it is Claude Code's own settings format. For example, to try another model:

Claude Code settings, deep-merged onto the seeded `settings.json` at every
launch. For example, to try another model:

```json
{ "model": "claude-sonnet-6" }
```

Arrays (such as `permissions.allow`) replace the base array instead of merging
with it. Removing a key from this file doesn't revert it until you
`claude-<flavor> reseed`.

### Where state lives

Machine-managed state goes under `~/.local/state/claude-container/<flavor>/`
(`$XDG_STATE_HOME` if set). You can delete it to start that flavor fresh.

    claude/              # the container's ~/.claude: settings, plugins, history
      claude.json        # the container's ~/.claude.json
      .credentials.json  # personal only: your OAuth token
      memory-global/     # memory shared across all repos for this flavor
    creds/gcloud/        # vertex: gcloud credentials
    creds/okta/          # gateway: Okta token cache
    projects/<key>/      # per-repo memory and /resume history

## Git & GitHub inside the container

The container uses your host git and GitHub setup, with no second login.

- **Git identity.** At each launch the wrapper reads `user.name` and `user.email`
  from your host with `git -C "$PWD" config`, so an `includeIf gitdir:` rule for
  work-vs-personal identities picks the right one for the repo you're in. Your
  host `~/.gitconfig` is never mounted.
- **`gh` and HTTPS push.** The wrapper reads `gh auth token` from your host at each launch and
  passes it in as `GH_TOKEN`, so `gh pr` and `gh api` work. `gh` is also the git credential helper, so HTTPS
  `git push` works. Use HTTPS remotes unless you forward SSH.
- **SSH push and signing.** With `forward_ssh = true` in `config.toml`, SSH remotes work. If your
  host signs commits with `gpg.format = ssh`, the container signs with the same
  key through the forwarded agent.
- **gpg or x509 signing (a YubiKey, say).** No secret key can be forwarded into
  the container, so give it a separate SSH signing key. Set
  `claude-container.signingkey-ssh` to a public key or a path to one, in the same
  `includeIf`'d file as your real signing key, so it follows the same identity:

  ```ini
  # ~/.gitconfig-work
  [user]
      signingkey = <your gpg key id>
  [claude-container]
      signingkey-ssh = ~/.ssh/container_signing.pub
  ```

  The private half must be in your host's SSH agent, and `forward_ssh` must be
  on.

## Flavor reference

### Vertex

The model and region pins live in the seeded `[env]` table of `config.toml`, so you can change them
without rebuilding.

| Var | Default | Where |
|-----|---------|-------|
| `CLAUDE_CODE_USE_VERTEX` | `1` | image |
| `ANTHROPIC_VERTEX_PROJECT_ID` | placeholder, **must be set** | `[env]` |
| `CLOUD_ML_REGION` | `us` | image and `[env]` |
| `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL` | `claude-opus-5[1m]` | `[env]` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `claude-sonnet-5` | `[env]` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `claude-haiku-4-5` | `[env]` |
| `VERTEX_REGION_CLAUDE_HAIKU_4_5` | `us-east5` | `[env]` |

Every pin is a US region, for data residency. Opus 5 and Sonnet 5 need a
multi-region, so they use `us`; Haiku 4.5 uses `us-east5`. The pins matter
beyond residency. Unpinned, Vertex's background model defaults to
`claude-sonnet-4-5`, which returns 429 if your project can't call it and breaks
session titles and web-search summaries. The `[1m]` suffix turns on the 1M
context window for Opus.

If your `config.toml` predates these pins, add them by hand. The wrapper seeds the
file only when it's missing.

### Gateway

The gateway flavor is a generic Anthropic-format client pointed at your gateway.
Set these under `[env]` in `~/.config/claude-container/gateway/config.toml`:

| Var | Notes |
|-----|-------|
| `ANTHROPIC_BASE_URL` | Your gateway, **without** `/v1/messages`; Claude appends it |
| `OKTA_ISSUER` | The Okta org authorization server, e.g. `https://your-org.okta.com` (no `/oauth2/<id>`) |
| `OKTA_CLIENT_ID` | The Okta Native app's `client_id`; must equal LiteLLM's `JWT_AUDIENCE` |
| `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_*_MODEL` | The `model_name` strings your gateway exposes |

The image also sets `ENABLE_TOOL_SEARCH=true`, because Claude Code turns MCP
tool search off against a non-Anthropic base URL.

`claude-gateway auth` runs the baked helper's device login and stores a refresh
token in `creds/okta`. After that the helper hands Claude a cached Okta
`id_token` and refreshes it on its own. Refresh tokens expire after about 7 idle
days; run `reset-auth` and `auth` again when that happens.

On the LiteLLM side, validate the Okta org `id_token` as a JWT:
`JWT_ISSUER=https://your-org.okta.com`, `JWT_AUDIENCE=<OKTA_CLIENT_ID>`, JWKS at
`https://your-org.okta.com/oauth2/v1/keys`.

### Personal

`claude-personal auth` runs `claude auth login --claudeai` inside the container
and prints a URL to approve in your browser.

**The token is stored in plaintext**, at
`~/.local/state/claude-container/personal/claude/.credentials.json`. A Linux
container has no keychain, and Claude Code has no credential-helper hook that
could provide one. On a Linux host that matches a normal `claude` install. **On
macOS it's a downgrade** from the Keychain your host `claude` uses. The wrapper
keeps the state directory at `0700` on every launch, and Claude Code writes the
file `0600`. `claude-personal reset-auth` deletes it.

### Checking which provider you're on

Run `/status` inside Claude:

- **vertex** shows `API provider: Google Vertex AI` and your GCP project.
- **gateway** shows your gateway as the base URL, not `api.anthropic.com`.
- **personal** shows no Vertex project and no gateway, signed in as the account
  you approved.

## Troubleshooting

`claude-<flavor> doctor` checks the runtime, image, credentials, `PATH`, memory,
and any leftover pre-`config.toml` files for that flavor.

**`update` fails with "pull failed" or a release error.** You're offline, or the
registry or GitHub is unreachable. Check `claude-<flavor> --print-runtime`, then retry.

**`/status` shows the wrong provider.** Stale state. Delete
`~/.local/state/claude-container/<flavor>` and relaunch.

**Vertex login fails with a browser or URL error.** Run `claude-vertex reset-auth`,
then `claude-vertex auth`.

**gateway: "not a terminal; run okta-token-helper once to log in".** You haven't
done the device login yet. Run `claude-gateway auth`.

**gateway: 401s or login loops.** The refresh token expired or was revoked. Run
`claude-gateway reset-auth`, then `claude-gateway auth`. To debug, open
`claude-gateway shell` and run `/opt/claude/api-key-helper`. It prints the token
on stdout and diagnostics on stderr.

**personal: logged out, or a `.credentials.json` permissions warning.** Run
`claude-personal reset-auth`, then `claude-personal auth`.

**DNS lookups time out inside the container.** Set `dns` in `config.toml`.

**Permission errors writing to a mounted directory.** The container maps its user
to your host uid. If files still land with the wrong owner, run
`claude-<flavor> --print-runtime` and include its output in a bug report.

## Migrating

### From local builds

The wrapper runs the image its binary is pinned to. To keep running a local
build, add this to that flavor's `config.toml`:

```toml
image = "claude-personal:latest"
```

### From the old `~/.claude-<flavor>*` layout

Early versions kept these files in `$HOME`. Move them once per flavor:

```sh
flavor=vertex   # or gateway
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-container/$flavor"
state="${XDG_STATE_HOME:-$HOME/.local/state}/claude-container/$flavor"
mkdir -p "$cfg" "$state"
mv ~/.claude-$flavor.env    "$cfg/env"      2>/dev/null || true
mv ~/.claude-$flavor.mounts "$cfg/mounts"   2>/dev/null || true
mv ~/.claude-$flavor        "$state/claude" 2>/dev/null || true
mkdir -p "$state/claude"
mv ~/.claude-$flavor.json   "$state/claude/claude.json" 2>/dev/null || true
```

Then run `claude-<flavor> update` to turn `env` and `mounts` into `config.toml`.

### From a shared memory bucket or named credential volumes

Older versions shared one memory and `/resume` bucket across every repo, and kept
credentials in named docker volumes. Two one-time commands move them:

- `claude-<flavor> migrate-memory`, run from the repo that owns that history,
  moves the shared bucket to that repo.
- `claude-<flavor> migrate-creds` copies an old credential volume into the new
  directory (docker and podman only).

## Uninstall

```sh
rm -f ~/.local/bin/claude-vertex ~/.local/bin/claude-gateway ~/.local/bin/claude-personal ~/.local/bin/claude-container
rm -rf ~/.config/claude-container ~/.local/state/claude-container   # config, state, credentials
```

Then remove the images with your runtime, for example
`docker image rm ghcr.io/multigl/claude-container:<tag>` (`claude-<flavor> --version` shows the tag).

## Developing

Building images locally, the `just` recipes, CI, and how the pieces fit
together are in [ARCHITECTURE.md](ARCHITECTURE.md).

## License

MIT
