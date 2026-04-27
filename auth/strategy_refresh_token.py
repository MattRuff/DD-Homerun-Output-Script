"""Refresh-token strategy: pure-HTTP JWT renewal, no browser needed.

Homerun's SPA mints fresh ``jwttoken`` cookies by calling a server endpoint
with the long-lived ``jrtoken``. We try the same call from Python.

Endpoint discovery
------------------
The exact path is observed at runtime; we accept it via the
``HOMERUN_REFRESH_PATH`` env var, falling back to a list of likely candidates.
Use :func:`discover_refresh_endpoint` (or sniff with Playwright while opening
the SPA) to pin it down once.

State
-----
Cookies are persisted under ``~/.homerun/cookies.txt`` so each refresh updates
the stored ``jrtoken`` (some IdPs rotate it on every refresh).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import requests

from . import AuthError
from .jwt_utils import (
    cookie_has_fresh_jwt,
    cookies_to_dict,
    dict_to_cookies,
)

DEFAULT_COOKIES_PATH = Path.home() / ".homerun" / "cookies.txt"
BASE_URL = os.environ.get(
    "HOMERUN_BASE_URL",
    "https://datadog.cloud.homerunpresales.com/api/v1",
)
ORIGIN = BASE_URL.rsplit("/api/", 1)[0]

CANDIDATE_PATHS = [
    os.environ.get("HOMERUN_REFRESH_PATH", "").strip() or None,
    "jwt/refresh",
    "authenticate/refresh",
    "authenticate/jwt-refresh",
    "authenticate/token/refresh",
    "authenticate/refresh-token",
    "auth/refresh",
]


def _headers(cookie_str: str, csrf: str | None = None) -> dict[str, str]:
    h = {
        "accept": "application/json",
        "content-type": "application/json",
        "origin": ORIGIN,
        "referer": ORIGIN + "/",
        "user-agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/131.0.0.0 Safari/537.36"
        ),
        "Cookie": cookie_str,
    }
    if csrf:
        h["x-xsrf-token"] = csrf
    return h


def _get_csrf(cookie_str: str) -> str | None:
    try:
        r = requests.get(
            f"{BASE_URL}/authenticate/csrf",
            headers=_headers(cookie_str),
            timeout=20,
        )
        if r.ok:
            return r.json().get("xsrf_token")
    except (requests.RequestException, ValueError):
        return None
    return None


def _try_refresh(cookie_str: str, path: str, csrf: str | None) -> dict | None:
    url = f"{BASE_URL}/{path.lstrip('/')}"
    try:
        r = requests.post(url, headers=_headers(cookie_str, csrf), timeout=20)
    except requests.RequestException:
        return None
    if r.status_code in (404, 405):
        return None
    if not r.ok:
        return None

    new_cookies: dict[str, str] = {}
    for name, value in r.cookies.items():
        new_cookies[name] = value

    body_token: str | None = None
    try:
        body = r.json()
        if isinstance(body, dict):
            for key in ("jwttoken", "jwt", "access_token", "token"):
                v = body.get(key)
                if isinstance(v, str) and v.count(".") == 2:
                    body_token = v
                    break
    except ValueError:
        pass
    if body_token and "jwttoken" not in new_cookies:
        new_cookies["jwttoken"] = body_token

    if "jwttoken" not in new_cookies:
        return None

    return new_cookies


def _read_cookies_file(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip() or None
    except FileNotFoundError:
        return None
    except OSError:
        return None


def _write_cookies_file(path: Path, cookie_str: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(cookie_str, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def fetch_cookies(
    *,
    cookies_path: str | os.PathLike[str] = DEFAULT_COOKIES_PATH,
    seed_cookie_str: str | None = None,
    min_ttl_seconds: int = 600,
    auto_seed_from_rookiepy: bool = True,
) -> str:
    """Refresh JWT via HTTP and return the updated cookie header string.

    Seed precedence (first wins):
      1. ``seed_cookie_str`` argument (caller-supplied cookies).
      2. ``cookies_path`` on disk (previously persisted cookies).
      3. Live Chrome cookies via rookiepy, when ``auto_seed_from_rookiepy``.

    The third option lets the harness "self-bootstrap" — Chrome is the only
    place a valid ``jrtoken`` is guaranteed to exist on a freshly logged-in
    Mac, so we read it once, refresh the JWT via HTTP, and persist the result.
    """
    cookies_path = Path(cookies_path)
    seed = seed_cookie_str or _read_cookies_file(cookies_path)
    if not seed and auto_seed_from_rookiepy:
        try:
            from .strategy_rookiepy import fetch_cookies as _rookie_fetch

            seed = _rookie_fetch()
        except Exception as e:  # noqa: BLE001 - we surface as AuthError below
            raise AuthError(
                f"no seed cookies (cookies_path={cookies_path}); "
                f"rookiepy fallback also failed: {e}"
            ) from e
    if not seed:
        raise AuthError(
            f"no seed cookies (looked at {cookies_path}). "
            f"Save a cookies.txt with at least jrtoken or run the playwright "
            f"strategy once to mint one."
        )

    seed_jar = cookies_to_dict(seed)
    if "jrtoken" not in seed_jar:
        raise AuthError("seed cookies have no jrtoken — refresh impossible")

    def _persist(cookie_str: str) -> None:
        try:
            _write_cookies_file(cookies_path, cookie_str)
        except OSError:
            pass

    if cookie_has_fresh_jwt(seed, min_ttl_seconds):
        _persist(seed)
        return seed

    csrf = _get_csrf(seed)

    last_err: list[str] = []
    for path in [p for p in CANDIDATE_PATHS if p]:
        new = _try_refresh(seed, path, csrf)
        if new is None:
            last_err.append(f"{path}: no fresh jwttoken in response")
            continue
        merged = {**seed_jar, **new}
        cookie_str = dict_to_cookies(merged)
        if cookie_has_fresh_jwt(cookie_str, min_ttl_seconds):
            _persist(cookie_str)
            return cookie_str
        last_err.append(f"{path}: returned token but TTL < {min_ttl_seconds}s")

    raise AuthError(
        "no refresh endpoint accepted our jrtoken. Tried:\n  - "
        + "\n  - ".join(last_err)
        + "\nSet HOMERUN_REFRESH_PATH=<path> if you've sniffed it."
    )


def discover_refresh_endpoint(
    storage_state_path: str | os.PathLike[str] | None = None,
    url: str | None = None,
) -> str | None:
    """Use Playwright to watch network calls and report the refresh endpoint.

    Run this once with a logged-in storage_state. It opens the SPA, watches
    for any POST whose response sets a new ``jwttoken`` cookie, and prints the
    URL so you can set ``HOMERUN_REFRESH_PATH``.
    """
    try:
        from playwright.sync_api import sync_playwright  # type: ignore
    except ImportError as e:
        raise AuthError(
            "playwright not installed; run `pip install playwright && "
            "python -m playwright install chromium`."
        ) from e

    page_url = url or (ORIGIN + "/")
    state = (
        str(storage_state_path)
        if storage_state_path
        else str(Path.home() / ".homerun" / "storage_state.json")
    )

    found: list[str] = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            storage_state=state if Path(state).exists() else None
        )

        def _on_response(response):
            try:
                set_cookie = response.headers.get("set-cookie", "") or ""
            except Exception:
                set_cookie = ""
            if "jwttoken=" in set_cookie:
                found.append(response.url)

        context.on("response", _on_response)
        page = context.new_page()
        page.goto(page_url, wait_until="domcontentloaded", timeout=60_000)
        try:
            page.wait_for_load_state("networkidle", timeout=20_000)
        except Exception:
            pass
        page.wait_for_timeout(5000)
        browser.close()

    if not found:
        return None
    print("Refresh endpoint candidates (POSTed and set jwttoken):", file=sys.stderr)
    for u in found:
        print(f"  {u}", file=sys.stderr)
    return found[0]
