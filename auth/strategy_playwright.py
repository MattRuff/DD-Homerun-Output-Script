"""Playwright strategy: drive a real browser, let Homerun mint a fresh JWT.

Why: Homerun only refreshes its short-lived JWT when the SPA actively loads,
which `rookiepy` cannot do. Playwright opens the page in a (headless) Chromium,
waits for the refresh-token exchange, and dumps the resulting cookies.

Two phases:
 - :func:`bootstrap` : one-time, headed login. You log in manually; we save
   ``storage_state.json`` so future headless runs reuse the session.
 - :func:`fetch_cookies` : daily, headless. Loads the storage state, navigates,
   waits, returns a cookie header string.

If ``storage_state.json`` is missing or its refresh token has expired, this
strategy raises :class:`AuthError` and the harness falls through.
"""

from __future__ import annotations

import os
from pathlib import Path

from . import AuthError
from .jwt_utils import cookie_has_fresh_jwt, dict_to_cookies

DEFAULT_STATE_PATH = Path.home() / ".homerun" / "storage_state.json"
DEFAULT_URL = "https://datadog.cloud.homerunpresales.com/"


def _import_playwright():
    try:
        from playwright.sync_api import sync_playwright  # type: ignore
    except ImportError as e:
        raise AuthError(
            "playwright not installed. Run `pip install playwright && "
            "python -m playwright install chromium`."
        ) from e
    return sync_playwright


def _cookies_from_context(context) -> str:
    seen: dict[str, str] = {}
    for c in context.cookies():
        name = c.get("name")
        value = c.get("value")
        if name is None or value is None:
            continue
        seen[name] = value
    return dict_to_cookies(seen)


def fetch_cookies(
    state_path: str | os.PathLike[str] = DEFAULT_STATE_PATH,
    *,
    url: str = DEFAULT_URL,
    headless: bool = True,
    wait_seconds: float = 12.0,
    min_ttl_seconds: int = 1800,
) -> str:
    """Headless fetch of fresh cookies using a persisted storage state."""
    state = Path(state_path)
    if not state.exists():
        raise AuthError(
            f"storage state not found at {state}. "
            f"Run `python -m auth bootstrap-playwright` first."
        )

    sync_playwright = _import_playwright()
    with sync_playwright() as p:
        try:
            browser = p.chromium.launch(headless=headless)
        except Exception as e:
            raise AuthError(
                f"could not launch chromium: {e}. "
                f"Did you run `python -m playwright install chromium`?"
            ) from e
        try:
            context = browser.new_context(storage_state=str(state))
            page = context.new_page()
            page.goto(url, wait_until="domcontentloaded", timeout=60_000)
            try:
                page.wait_for_load_state("networkidle", timeout=int(wait_seconds * 1000))
            except Exception:
                pass
            page.wait_for_timeout(int(wait_seconds * 1000))
            cookie_str = _cookies_from_context(context)
            context.storage_state(path=str(state))
        finally:
            browser.close()

    if not cookie_str:
        raise AuthError("playwright returned no cookies")
    if not cookie_has_fresh_jwt(cookie_str, min_ttl_seconds):
        raise AuthError(
            "playwright produced cookies but jwttoken is missing or stale "
            f"(need >= {min_ttl_seconds}s TTL). Refresh token likely expired; "
            f"re-run bootstrap-playwright."
        )
    return cookie_str


def bootstrap(
    state_path: str | os.PathLike[str] = DEFAULT_STATE_PATH,
    *,
    url: str = DEFAULT_URL,
) -> Path:
    """One-time interactive login. Opens a real Chromium for you to log in.

    Press Enter in the terminal once you're at the Homerun home screen and
    have verified the page loaded fully (so refresh-token exchange ran).
    """
    sync_playwright = _import_playwright()
    state = Path(state_path)
    state.parent.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        context = browser.new_context()
        page = context.new_page()
        page.goto(url, wait_until="domcontentloaded", timeout=60_000)
        print(
            f"\nA Chromium window has opened at {url}.\n"
            "Log in to Homerun, wait for the home screen to fully load, "
            "then press Enter here to save your session."
        )
        try:
            input()
        except EOFError:
            pass
        context.storage_state(path=str(state))
        browser.close()

    return state
