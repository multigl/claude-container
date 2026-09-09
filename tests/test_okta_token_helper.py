"""Tests for the Okta id_token apiKeyHelper.

Mocks live only at the system boundaries the helper touches: the HTTP call
(`post_form` / `urllib.request.urlopen`), the filesystem cache (`tmp_path` +
a redirected `CACHE`), the clock (`time.sleep`/`time.time`), and stderr's
tty-ness. The helper's own functions are exercised directly, never stubbed.
"""
import base64
import io
import json
import time

import pytest

import okta_token_helper as helper


# --- helpers -----------------------------------------------------------------

def make_jwt(exp=None, **claims):
    """Build a structurally valid (unsigned) JWT string with the given claims."""
    payload = dict(claims)
    if exp is not None:
        payload["exp"] = exp

    def segment(obj):
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()

    return f"{segment({'alg': 'RS256', 'typ': 'JWT'})}.{segment(payload)}.signature"


def scripted_post_form(responses):
    """A post_form replacement that returns queued responses in order."""
    queue = list(responses)
    calls = []

    def fake(url, fields):
        calls.append({"url": url, "fields": fields})
        return queue.pop(0)

    fake.calls = calls
    return fake


class FakeStderr(io.StringIO):
    def __init__(self, tty):
        super().__init__()
        self._tty = tty

    def isatty(self):
        return self._tty


# --- fixtures ----------------------------------------------------------------

@pytest.fixture
def cache(tmp_path, monkeypatch):
    """Redirect the module cache into a temp dir; return the cache file path."""
    path = tmp_path / "litellm" / "okta.json"
    monkeypatch.setattr(helper, "CACHE", str(path))
    return path


@pytest.fixture
def configured(monkeypatch):
    """Set the required OKTA_* module config."""
    monkeypatch.setattr(helper, "ISSUER", "https://YOUR-ORG.okta.com")
    monkeypatch.setattr(helper, "CLIENT_ID", "client-123")


def force_tty(monkeypatch):
    """Make stderr report as a terminal. Must run in the test body, not a
    fixture: pytest reinstalls its capture object on sys.stderr at the
    setup->call boundary, so a fixture-set value wouldn't survive."""
    monkeypatch.setattr(helper.sys, "stderr", FakeStderr(tty=True))


# --- jwt_seconds_left --------------------------------------------------------

def test_jwt_seconds_left_future_exp():
    token = make_jwt(exp=int(time.time()) + 1000)
    assert 900 < helper.jwt_seconds_left(token) <= 1000


def test_jwt_seconds_left_no_exp_claim():
    assert helper.jwt_seconds_left(make_jwt()) is None


def test_jwt_seconds_left_malformed():
    assert helper.jwt_seconds_left("not-a-jwt") is None


# --- read_cache / write_cache ------------------------------------------------

def test_write_then_read_roundtrip(cache):
    helper.write_cache({"id_token": "a", "refresh_token": "b"})
    assert helper.read_cache() == {"id_token": "a", "refresh_token": "b"}


def test_write_cache_perms(cache):
    helper.write_cache({"id_token": "a"})
    assert (cache.stat().st_mode & 0o777) == 0o600
    assert (cache.parent.stat().st_mode & 0o777) == 0o700


def test_write_cache_leaves_no_temp_files(cache):
    helper.write_cache({"id_token": "a"})
    assert [p.name for p in cache.parent.iterdir()] == ["okta.json"]


def test_write_cache_failure_after_close_reraises_original(cache, monkeypatch):
    """A post-close chmod/replace failure must propagate the ORIGINAL error, not
    an EBADF from re-closing the already-closed descriptor in the except block."""
    boom = RuntimeError("replace failed")

    def fail(*args, **kwargs):
        raise boom

    monkeypatch.setattr(helper.os, "replace", fail)
    with pytest.raises(RuntimeError) as excinfo:
        helper.write_cache({"id_token": "a"})
    assert excinfo.value is boom


def test_write_cache_failure_after_close_removes_temp(cache, monkeypatch):
    """The EBADF mask (from a double close) also skips os.unlink, leaking a temp
    file. On any write failure the cache dir must be left empty."""
    def fail(*args, **kwargs):
        raise RuntimeError("replace failed")

    monkeypatch.setattr(helper.os, "replace", fail)
    with pytest.raises(RuntimeError):
        helper.write_cache({"id_token": "a"})
    assert list(cache.parent.iterdir()) == []


def test_read_cache_missing_returns_empty(cache):
    assert helper.read_cache() == {}


# --- post_form (HTTP boundary) -----------------------------------------------

def test_post_form_success(monkeypatch):
    class Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    monkeypatch.setattr(
        helper.urllib.request, "urlopen",
        lambda req, timeout=0: Resp(json.dumps({"id_token": "x"}).encode()),
    )
    assert helper.post_form("https://x/token", {"a": "b"}) == {"id_token": "x"}


def test_post_form_http_error_returns_oauth_body(monkeypatch):
    def raise_http(req, timeout=0):
        raise helper.urllib.error.HTTPError(
            "https://x/token", 400, "Bad Request", {},
            io.BytesIO(json.dumps({"error": "authorization_pending"}).encode()),
        )

    monkeypatch.setattr(helper.urllib.request, "urlopen", raise_http)
    assert helper.post_form("https://x/token", {}) == {"error": "authorization_pending"}


def test_post_form_network_failure(monkeypatch):
    def boom(req, timeout=0):
        raise OSError("connection refused")

    monkeypatch.setattr(helper.urllib.request, "urlopen", boom)
    assert helper.post_form("https://x/token", {})["error"] == "request_failed"


# --- serve_or_refresh --------------------------------------------------------

def test_serve_valid_cached_token_skips_http(cache, configured, monkeypatch):
    token = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": token, "refresh_token": "rt",
                                 "client_id": "client-123",
                                 "issuer": "https://YOUR-ORG.okta.com"}))

    def forbidden(*a, **k):
        raise AssertionError("post_form must not be called for a valid cached token")

    monkeypatch.setattr(helper, "post_form", forbidden)
    assert helper.serve_or_refresh() == token


def test_refresh_when_expired_persists_rotated_token(cache, configured, monkeypatch):
    fresh = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    # Within the 60s skew -> treated as needing refresh.
    cache.write_text(json.dumps({"id_token": make_jwt(exp=int(time.time()) + 10),
                                 "refresh_token": "rt-old",
                                 "client_id": "client-123",
                                 "issuer": "https://YOUR-ORG.okta.com"}))
    monkeypatch.setattr(
        helper, "post_form",
        scripted_post_form([{"id_token": fresh, "refresh_token": "rt-new"}]),
    )

    assert helper.serve_or_refresh() == fresh
    assert json.loads(cache.read_text())["refresh_token"] == "rt-new"


def test_refresh_keeps_old_token_when_okta_omits_rotation(cache, configured, monkeypatch):
    fresh = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": make_jwt(exp=int(time.time()) + 10),
                                 "refresh_token": "rt-old",
                                 "client_id": "client-123",
                                 "issuer": "https://YOUR-ORG.okta.com"}))
    monkeypatch.setattr(helper, "post_form",
                        scripted_post_form([{"id_token": fresh}]))

    assert helper.serve_or_refresh() == fresh
    assert json.loads(cache.read_text())["refresh_token"] == "rt-old"


def test_refresh_failure_returns_none(cache, configured, monkeypatch):
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": make_jwt(exp=int(time.time()) + 10),
                                 "refresh_token": "rt",
                                 "client_id": "client-123",
                                 "issuer": "https://YOUR-ORG.okta.com"}))
    monkeypatch.setattr(helper, "post_form",
                        scripted_post_form([{"error": "invalid_grant"}]))
    assert helper.serve_or_refresh() is None


def test_refresh_stamps_identity(cache, configured, monkeypatch):
    fresh = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": make_jwt(exp=int(time.time()) + 10),
                                 "refresh_token": "rt",
                                 "client_id": "client-123",
                                 "issuer": "https://YOUR-ORG.okta.com"}))
    monkeypatch.setattr(helper, "post_form",
                        scripted_post_form([{"id_token": fresh, "refresh_token": "rt2"}]))

    assert helper.serve_or_refresh() == fresh
    written = json.loads(cache.read_text())
    assert written["client_id"] == "client-123"
    assert written["issuer"] == "https://YOUR-ORG.okta.com"


def test_serve_empty_cache_returns_none(cache, configured):
    assert helper.serve_or_refresh() is None


def test_serve_mismatched_client_id_forces_relogin(cache, configured, monkeypatch):
    token = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": token, "refresh_token": "rt",
                                 "client_id": "OTHER",
                                 "issuer": "https://YOUR-ORG.okta.com"}))

    def forbidden(*a, **k):
        raise AssertionError("identity mismatch must not attempt a refresh")

    monkeypatch.setattr(helper, "post_form", forbidden)
    assert helper.serve_or_refresh() is None


def test_serve_mismatched_issuer_forces_relogin(cache, configured, monkeypatch):
    token = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": token, "refresh_token": "rt",
                                 "client_id": "client-123",
                                 "issuer": "https://other.okta.com"}))

    def forbidden(*a, **k):
        raise AssertionError("identity mismatch must not attempt a refresh")

    monkeypatch.setattr(helper, "post_form", forbidden)
    assert helper.serve_or_refresh() is None


def test_serve_partial_identity_missing_issuer_forces_relogin(cache, configured, monkeypatch):
    token = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    # client_id present, issuer absent -> _identity_matches' AND short-circuits to mismatch.
    cache.write_text(json.dumps({"id_token": token, "refresh_token": "rt",
                                 "client_id": "client-123"}))

    def forbidden(*a, **k):
        raise AssertionError("partial-identity cache must not attempt a refresh")

    monkeypatch.setattr(helper, "post_form", forbidden)
    assert helper.serve_or_refresh() is None


def test_serve_partial_identity_missing_client_id_forces_relogin(cache, configured, monkeypatch):
    token = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    # issuer present, client_id absent -> still a mismatch.
    cache.write_text(json.dumps({"id_token": token, "refresh_token": "rt",
                                 "issuer": "https://YOUR-ORG.okta.com"}))

    def forbidden(*a, **k):
        raise AssertionError("partial-identity cache must not attempt a refresh")

    monkeypatch.setattr(helper, "post_form", forbidden)
    assert helper.serve_or_refresh() is None


def test_serve_legacy_cache_without_identity_forces_relogin(cache, configured, monkeypatch):
    token = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": token, "refresh_token": "rt"}))

    def forbidden(*a, **k):
        raise AssertionError("legacy cache mismatch must not attempt a refresh")

    monkeypatch.setattr(helper, "post_form", forbidden)
    assert helper.serve_or_refresh() is None


def test_serve_mismatch_logs_relogin_needed(cache, configured, capsys):
    token = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": token, "client_id": "OTHER",
                                 "issuer": "https://YOUR-ORG.okta.com"}))
    assert helper.serve_or_refresh() is None
    assert "different OKTA_CLIENT_ID" in capsys.readouterr().err


def test_serve_empty_cache_emits_no_mismatch_log(cache, configured, capsys):
    assert helper.serve_or_refresh() is None
    assert "different OKTA" not in capsys.readouterr().err


# --- device_login ------------------------------------------------------------

def test_device_login_requires_tty(cache, configured, monkeypatch):
    monkeypatch.setattr(helper.sys, "stderr", FakeStderr(tty=False))
    with pytest.raises(SystemExit):
        helper.device_login()


def test_device_login_happy_path_writes_cache(cache, configured, monkeypatch):
    force_tty(monkeypatch)
    token = make_jwt(exp=int(time.time()) + 1000)
    monkeypatch.setattr(helper.time, "sleep", lambda s: None)
    monkeypatch.setattr(helper, "post_form", scripted_post_form([
        {"device_code": "dc", "user_code": "UC", "verification_uri": "https://v",
         "interval": 1, "expires_in": 600},
        {"id_token": token, "refresh_token": "rt"},
    ]))

    assert helper.device_login() == token
    assert json.loads(cache.read_text()) == {
        "id_token": token, "refresh_token": "rt",
        "client_id": "client-123", "issuer": "https://YOUR-ORG.okta.com",
    }


def test_device_login_stamps_identity(cache, configured, monkeypatch):
    force_tty(monkeypatch)
    token = make_jwt(exp=int(time.time()) + 1000)
    monkeypatch.setattr(helper.time, "sleep", lambda s: None)
    monkeypatch.setattr(helper, "post_form", scripted_post_form([
        {"device_code": "dc", "interval": 1, "expires_in": 600},
        {"id_token": token, "refresh_token": "rt"},
    ]))

    assert helper.device_login() == token
    written = json.loads(cache.read_text())
    assert written["client_id"] == "client-123"
    assert written["issuer"] == "https://YOUR-ORG.okta.com"


def test_device_login_polls_through_pending(cache, configured, monkeypatch):
    force_tty(monkeypatch)
    token = make_jwt(exp=int(time.time()) + 1000)
    monkeypatch.setattr(helper.time, "sleep", lambda s: None)
    monkeypatch.setattr(helper, "post_form", scripted_post_form([
        {"device_code": "dc", "interval": 1, "expires_in": 600},
        {"error": "authorization_pending"},
        {"id_token": token},
    ]))
    assert helper.device_login() == token


def test_device_login_backs_off_on_slow_down(cache, configured, monkeypatch):
    force_tty(monkeypatch)
    token = make_jwt(exp=int(time.time()) + 1000)
    sleeps = []
    monkeypatch.setattr(helper.time, "sleep", lambda s: sleeps.append(s))
    monkeypatch.setattr(helper, "post_form", scripted_post_form([
        {"device_code": "dc", "interval": 1, "expires_in": 600},
        {"error": "slow_down"},
        {"id_token": token},
    ]))

    assert helper.device_login() == token
    # interval started at 1, slow_down bumped it by 5 for the next poll.
    assert 6 in sleeps


def test_device_login_times_out(cache, configured, monkeypatch):
    force_tty(monkeypatch)
    monkeypatch.setattr(helper.time, "sleep", lambda s: None)
    monkeypatch.setattr(helper, "post_form", scripted_post_form([
        {"device_code": "dc", "interval": 1, "expires_in": 0},
    ]))
    with pytest.raises(SystemExit):
        helper.device_login()


# --- main --------------------------------------------------------------------

def test_main_requires_issuer(monkeypatch):
    monkeypatch.setattr(helper, "ISSUER", "")
    monkeypatch.setattr(helper, "CLIENT_ID", "client-123")
    with pytest.raises(SystemExit):
        helper.main([])


def test_main_requires_client_id(monkeypatch):
    monkeypatch.setattr(helper, "ISSUER", "https://YOUR-ORG.okta.com")
    monkeypatch.setattr(helper, "CLIENT_ID", "")
    with pytest.raises(SystemExit):
        helper.main([])


def test_main_emits_cached_token(cache, configured, capsys):
    token = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": token, "refresh_token": "rt",
                                 "client_id": "client-123",
                                 "issuer": "https://YOUR-ORG.okta.com"}))

    with pytest.raises(SystemExit) as exit_info:
        helper.main([])

    assert exit_info.value.code == 0
    assert capsys.readouterr().out == token


def test_main_login_only_prints_nothing_to_stdout(cache, configured, capsys):
    token = make_jwt(exp=int(time.time()) + 1000)
    cache.parent.mkdir(parents=True)
    cache.write_text(json.dumps({"id_token": token, "refresh_token": "rt",
                                 "client_id": "client-123",
                                 "issuer": "https://YOUR-ORG.okta.com"}))

    assert helper.main(["--login-only"]) is None
    assert capsys.readouterr().out == ""
