"""rookiepy strategy: pulls Homerun cookies straight from Chrome's cookie DB.

Extracted (and de-`sys.exit`-ed) from the original ``_get_cookies`` flow in
``pull_info_from_opp.py``.

Limitations:
 - Requires Chrome and an active Homerun login on the same machine.
 - Requires Full Disk Access on macOS.
 - Does NOT trigger a JWT refresh; if the cached JWT is stale, this strategy
   reports failure and the harness falls through to the next one.
"""

from __future__ import annotations

import sys

from . import AuthError
from .jwt_utils import dict_to_cookies


def fetch_cookies(domain: str = "homerunpresales.com") -> str:
    try:
        import rookiepy  # type: ignore
    except ImportError as e:
        raise AuthError(f"rookiepy not installed: {e}") from e

    try:
        cookies = rookiepy.chrome([domain])
    except RuntimeError as e:
        err = str(e).lower()
        hint = ""
        if sys.platform == "darwin" and (
            "can't find cookies" in err or "no such file" in err
        ):
            hint = " (grant Full Disk Access to the terminal/process)"
        raise AuthError(f"rookiepy could not read Chrome cookies: {e}{hint}") from e
    except OSError as e:
        raise AuthError(f"OS error reading Chrome cookies: {e}") from e

    if not cookies:
        raise AuthError("no Homerun cookies in Chrome — log in first")

    if not any(c.get("name") == "jwttoken" for c in cookies):
        raise AuthError("jwttoken not present in Chrome cookies")

    seen: dict[str, str] = {}
    for c in cookies:
        name = c.get("name")
        value = c.get("value")
        if name is None or value is None:
            continue
        seen[name] = value
    return dict_to_cookies(seen)
