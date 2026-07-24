#!/usr/bin/env python3
"""Claude Code apiKeyHelper: mint/refresh an Okta OIDC id_token (a JWT) for LiteLLM.

Vida's Okta tenant only has the default Org authorization server, which issues ID
tokens (no custom-API access tokens). LiteLLM's enable_jwt_auth validates the id_token
against the Org JWKS, checks aud == client_id, and maps the `groups` claim to a team.
Claude Code sends this helper's stdout as the `Authorization: Bearer` value.

Flow per invocation (Claude Code calls it on startup, every TTL, and on HTTP 401):
  1. serve a still-valid cached id_token, else
  2. silently refresh via the cached refresh_token, else
  3. (interactive terminals only) run an Okta device-authorization login.
Cache read/refresh/write happens under an advisory file lock with atomic writes, so
concurrent Claude Code instances can't corrupt the cache or stampede the token endpoint
(and, if Okta refresh-token rotation is ever enabled, can't trip reuse-detection).

In the claude-gateway container this file is baked at /opt/claude/api-key-helper and
its cache directory (~/.local/share/litellm) is a wipeable bind dir ($STATE_DIR/creds/okta,
wiped by `just reset-auth`); `claude-gateway
auth` runs it once with --login-only to complete the device login. It also runs
standalone: install to ~/.local/bin/okta-token-helper (chmod 0755) and configure Claude
Code via ~/.claude/settings.json:
  { "apiKeyHelper": "~/.local/bin/okta-token-helper",
    "env": { "ANTHROPIC_BASE_URL": "https://litellm.local.sunbeam.network",
             "OKTA_ISSUER": "https://vida.okta.com",
             "OKTA_CLIENT_ID": "<native-app-client-id>",
             "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "300000" } }

First run must be interactive (a terminal) to complete the device login; afterwards
non-interactive calls are served from cache / silent refresh. Re-login:
  rm ~/.local/share/litellm/okta.json   (or: claude-gateway reset-auth)

--login-only ensures the cache is populated (logging in if needed) and exits WITHOUT
printing the token to stdout -- used by the interactive `auth` step.

Required environment:
  OKTA_ISSUER     e.g. https://vida.okta.com   (Org server, no /oauth2/<authServerId>)
  OKTA_CLIENT_ID  the Native OIDC app's client_id (must equal LiteLLM JWT_AUDIENCE)
"""
import argparse
import base64
import fcntl
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ISSUER = os.environ.get("OKTA_ISSUER", "").rstrip("/")
CLIENT_ID = os.environ.get("OKTA_CLIENT_ID", "")
SCOPE = "openid email groups offline_access"
# Refresh once the id_token is within this many seconds of expiry.
EXPIRY_SKEW = 60
CACHE = os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
    "litellm",
    "okta.json",
)
DEVICE_ENDPOINT = f"{ISSUER}/oauth2/v1/device/authorize"
TOKEN_ENDPOINT = f"{ISSUER}/oauth2/v1/token"


def log(message):
    sys.stderr.write(f"okta-token-helper: {message}\n")


def die(message, code=1):
    log(message)
    sys.exit(code)


def emit(id_token):
    # Only the raw id_token goes to stdout (no 'Bearer ' prefix; Claude Code adds it).
    sys.stdout.write(id_token)
    sys.stdout.flush()
    sys.exit(0)


def post_form(url, fields):
    data = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Okta returns the OAuth error body (e.g. authorization_pending) as JSON on 4xx.
        try:
            return json.load(error)
        except Exception:
            return {"error": f"http_{error.code}"}
    except Exception as error:
        return {"error": "request_failed", "error_description": str(error)}


def jwt_seconds_left(id_token):
    try:
        payload = id_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        exp = json.loads(base64.urlsafe_b64decode(payload)).get("exp")
        return None if exp is None else exp - time.time()
    except Exception:
        return None


def read_cache():
    try:
        with open(CACHE) as handle:
            return json.load(handle)
    except Exception:
        return {}


def write_cache(tokens):
    directory = os.path.dirname(CACHE)
    os.makedirs(directory, exist_ok=True)
    os.chmod(directory, 0o700)
    descriptor, temp_path = tempfile.mkstemp(dir=directory)
    try:
        os.write(descriptor, json.dumps(tokens).encode())
        os.close(descriptor)
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, CACHE)  # atomic
    except Exception:
        os.close(descriptor)
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def locked(function):
    """Run function() holding an exclusive advisory lock on the cache."""
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    lock = open(CACHE + ".lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        return function()
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def _identity_matches(cache):
    """True if the cache records the client_id/issuer it was minted under and
    both match the current environment."""
    return cache.get("client_id") == CLIENT_ID and cache.get("issuer") == ISSUER


def serve_or_refresh():
    """Return a valid id_token from cache or a silent refresh, else None."""
    cache = read_cache()
    # A cached token is only trustworthy if it was minted under the CURRENT
    # client_id/issuer. On a mismatch (or a legacy cache with no identity fields)
    # both tokens are stale -- the refresh_token is client-bound and Okta would
    # reject it -- so discard and fall through to device login. An empty cache is
    # "not logged in", not a mismatch, so it must not trip this or log.
    if (cache.get("id_token") or cache.get("refresh_token")) and not _identity_matches(cache):
        log("cached credentials were issued for a different OKTA_CLIENT_ID/OKTA_ISSUER; re-login needed")
        return None
    id_token = cache.get("id_token")
    refresh_token = cache.get("refresh_token")

    seconds_left = jwt_seconds_left(id_token) if id_token else None
    if id_token and seconds_left is not None and seconds_left > EXPIRY_SKEW:
        return id_token

    if refresh_token:
        response = post_form(
            TOKEN_ENDPOINT,
            {
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": CLIENT_ID,
                "scope": SCOPE,
            },
        )
        new_id_token = response.get("id_token")
        if new_id_token:
            write_cache(
                {
                    "id_token": new_id_token,
                    # Persist a rotated refresh_token if Okta returns one.
                    "refresh_token": response.get("refresh_token") or refresh_token,
                    # Record the identity this token was minted under (see gate).
                    "client_id": CLIENT_ID,
                    "issuer": ISSUER,
                }
            )
            return new_id_token
        log(f"refresh failed ({response.get('error', 'unknown')}); re-login needed")
    return None


def device_login():
    if not sys.stderr.isatty():
        die("no valid token and not a terminal; run 'okta-token-helper' once to log in")

    device = post_form(DEVICE_ENDPOINT, {"client_id": CLIENT_ID, "scope": SCOPE})
    if "error" in device:
        die(f"device authorization failed: {device.get('error')} {device.get('error_description', '')}")

    complete = device.get("verification_uri_complete")
    log("Authorize Claude Code — open:")
    log(f"  {complete}" if complete else f"  {device.get('verification_uri')}   code: {device.get('user_code')}")
    log("Waiting for approval...")

    interval = device.get("interval", 5)
    device_code = device["device_code"]
    deadline = time.time() + device.get("expires_in", 600)
    while time.time() < deadline:
        time.sleep(interval)
        token = post_form(
            TOKEN_ENDPOINT,
            {
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": device_code,
                "client_id": CLIENT_ID,
            },
        )
        if token.get("id_token"):
            locked(lambda: write_cache(
                {"id_token": token["id_token"], "refresh_token": token.get("refresh_token", ""),
                 "client_id": CLIENT_ID, "issuer": ISSUER}
            ))
            log("Authorized.")
            return token["id_token"]
        error = token.get("error")
        if error in ("authorization_pending", "", None):
            continue
        if error == "slow_down":
            interval += 5
            continue
        die(f"device authorization failed: {error}")
    die("device authorization timed out")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="okta-token-helper",
        description="Mint/refresh an Okta OIDC id_token for LiteLLM (Claude Code apiKeyHelper).",
    )
    parser.add_argument(
        "--login-only",
        action="store_true",
        help="Populate the token cache (logging in if needed), then exit without "
             "printing the token to stdout. Used by the interactive `auth` step.",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if not ISSUER:
        die("set OKTA_ISSUER (e.g. https://vida.okta.com)")
    if not CLIENT_ID:
        die("set OKTA_CLIENT_ID (Native app client_id == LiteLLM JWT_AUDIENCE)")

    # Cache read + refresh + write are serialized; the long device-login poll is not,
    # so concurrent helpers don't block on a logged-out user's browser approval.
    id_token = locked(serve_or_refresh)
    if not id_token:
        id_token = device_login()

    if args.login_only:
        log("logged in; id_token cached")
        return
    emit(id_token)


if __name__ == "__main__":
    main()
