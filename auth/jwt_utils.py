"""JWT helpers used by every auth strategy.

Promoted from `_check_jwt_expiry` inside `pull_info_from_opp.py`.

These helpers are pure (no I/O, no exits) so they can be shared between the
strategies, the test harness, and the wrapper script.
"""

from __future__ import annotations

import base64
import json
import time


def parse_jwt_exp(token: str) -> int | None:
    """Return the `exp` claim (unix seconds) from a JWT, or None if unparseable."""
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
    except (IndexError, ValueError, json.JSONDecodeError):
        return None
    exp = payload.get("exp")
    return int(exp) if isinstance(exp, (int, float)) else None


def cookies_to_dict(cookie_str: str) -> dict[str, str]:
    """Parse a `name=value; name=value` cookie string into a dict."""
    out: dict[str, str] = {}
    for part in cookie_str.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        name, _, value = part.partition("=")
        out[name.strip()] = value.strip()
    return out


def dict_to_cookies(cookies: dict[str, str]) -> str:
    """Render a dict back into a cookie header string."""
    return "; ".join(f"{k}={v}" for k, v in cookies.items())


def cookie_jwt_ttl_seconds(cookie_str: str) -> int | None:
    """Return seconds until the cookie's `jwttoken` expires (negative if expired)."""
    jar = cookies_to_dict(cookie_str)
    token = jar.get("jwttoken")
    if not token:
        return None
    exp = parse_jwt_exp(token)
    if exp is None:
        return None
    return int(exp - time.time())


def cookie_has_fresh_jwt(cookie_str: str, min_ttl_seconds: int = 1800) -> bool:
    """True iff jwttoken exists and has at least `min_ttl_seconds` left."""
    ttl = cookie_jwt_ttl_seconds(cookie_str)
    return ttl is not None and ttl >= min_ttl_seconds
