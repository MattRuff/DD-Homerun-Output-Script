"""AppleScript strategy: ask Chrome to refresh Homerun, then read fresh cookies.

This mimics what you do manually: open Homerun in Chrome, hard-refresh, wait
for the SPA to mint a new JWT, then grab cookies via rookiepy.

Requirements:
 - macOS (uses /usr/bin/osascript)
 - Google Chrome installed and signed in to Homerun
 - The user session must be unlocked (Chrome windows must be reachable)
 - Full Disk Access for the calling process (so rookiepy can read the DB)
 - "Automation" permission for the calling process to control Chrome

Limitations:
 - Will steal focus briefly (Chrome activates).
 - If Chrome is not running, we launch it; if Chrome is locked behind a login
   screen, this will fail and the harness should fall through.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import time

from . import AuthError
from .jwt_utils import cookie_has_fresh_jwt
from .strategy_rookiepy import fetch_cookies as rookiepy_fetch

DEFAULT_URL = "https://datadog.cloud.homerunpresales.com/"
APPLESCRIPT_TEMPLATE = r"""
on run argv
    set targetURL to item 1 of argv
    if application "Google Chrome" is not running then
        tell application "Google Chrome" to activate
        delay 2
    end if
    tell application "Google Chrome"
        activate
        set foundTab to missing value
        repeat with w in windows
            repeat with t in tabs of w
                if URL of t starts with "https://datadog.cloud.homerunpresales.com" then
                    set foundTab to t
                    set index of w to 1
                    exit repeat
                end if
            end repeat
            if foundTab is not missing value then exit repeat
        end repeat
        if foundTab is missing value then
            tell window 1 to make new tab with properties {URL:targetURL}
            delay 4
        else
            set URL of foundTab to targetURL
            delay 1
            tell foundTab to reload
        end if
    end tell
end run
"""


def _run_applescript(url: str) -> None:
    if sys.platform != "darwin":
        raise AuthError("applescript strategy only works on macOS")
    if not shutil.which("osascript"):
        raise AuthError("osascript not found in PATH")
    try:
        proc = subprocess.run(
            ["/usr/bin/osascript", "-", url],
            input=APPLESCRIPT_TEMPLATE,
            text=True,
            capture_output=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired as e:
        raise AuthError(f"osascript timed out: {e}") from e
    if proc.returncode != 0:
        raise AuthError(
            f"osascript failed (rc={proc.returncode}): {proc.stderr.strip()}"
        )


def fetch_cookies(
    *,
    url: str = DEFAULT_URL,
    wait_seconds: float = 15.0,
    min_ttl_seconds: int = 600,
) -> str:
    """Trigger Chrome to refresh Homerun, wait for the JWT exchange, return cookies.

    Note: Homerun's SPA only mints a new JWT when the existing one is near
    expiry, so this strategy is most useful as a "kick the browser" fallback
    when ``refresh_token`` is unavailable. The harness should normally try
    ``refresh_token`` first.
    """
    _run_applescript(url)
    time.sleep(wait_seconds)
    cookie_str = rookiepy_fetch()
    if not cookie_has_fresh_jwt(cookie_str, min_ttl_seconds):
        raise AuthError(
            "Chrome reloaded but the JWT in cookies is still stale "
            f"(need >= {min_ttl_seconds}s TTL). Make sure you're logged in "
            "and the Mac is unlocked, or use the refresh_token strategy."
        )
    return cookie_str
