"""Pluggable Homerun auth strategies.

The public entry point is :func:`get_fresh_cookies`, which tries the requested
strategies in order and returns the first cookie string whose ``jwttoken`` has
at least ``min_ttl_seconds`` left.

Each strategy lives in its own module (``strategy_*.py``) and exposes::

    def fetch_cookies(**kwargs) -> str:  # raises AuthError on failure

so callers can swap strategies independently of the harness.
"""

from __future__ import annotations

import sys
import time
from dataclasses import dataclass
from typing import Callable

from .jwt_utils import cookie_has_fresh_jwt, cookie_jwt_ttl_seconds


class AuthError(RuntimeError):
    """Raised by a strategy when it cannot produce fresh cookies."""


@dataclass
class StrategyResult:
    name: str
    ok: bool
    elapsed_seconds: float
    jwt_ttl_seconds: int | None
    cookie_str: str | None
    error: str | None


# Lazy imports so missing optional deps (e.g. playwright) only blow up if the
# user actually selects that strategy.
def _load(name: str) -> Callable[..., str]:
    if name == "rookiepy":
        from .strategy_rookiepy import fetch_cookies
    elif name == "playwright":
        from .strategy_playwright import fetch_cookies
    elif name == "refresh_token":
        from .strategy_refresh_token import fetch_cookies
    elif name == "applescript":
        from .strategy_applescript import fetch_cookies
    else:
        raise AuthError(f"unknown strategy: {name!r}")
    return fetch_cookies


def run_strategy(name: str, **kwargs) -> StrategyResult:
    """Run one strategy and return a structured result (never raises)."""
    started = time.time()
    try:
        fn = _load(name)
        cookie_str = fn(**kwargs)
    except AuthError as e:
        return StrategyResult(
            name=name,
            ok=False,
            elapsed_seconds=time.time() - started,
            jwt_ttl_seconds=None,
            cookie_str=None,
            error=str(e),
        )
    except Exception as e:  # surface everything else as a strategy failure
        return StrategyResult(
            name=name,
            ok=False,
            elapsed_seconds=time.time() - started,
            jwt_ttl_seconds=None,
            cookie_str=None,
            error=f"{type(e).__name__}: {e}",
        )

    ttl = cookie_jwt_ttl_seconds(cookie_str or "")
    return StrategyResult(
        name=name,
        ok=bool(cookie_str) and ttl is not None and ttl > 0,
        elapsed_seconds=time.time() - started,
        jwt_ttl_seconds=ttl,
        cookie_str=cookie_str,
        error=None,
    )


def get_fresh_cookies(
    strategies: list[str],
    *,
    min_ttl_seconds: int = 600,
    verbose: bool = False,
    **strategy_kwargs,
) -> str:
    """Try strategies in order; return the first cookie string with a fresh JWT.

    Raises :class:`AuthError` if none succeed.
    """
    last_error: list[str] = []
    for name in strategies:
        if verbose:
            print(f"[auth] trying {name}...", file=sys.stderr)
        result = run_strategy(name, **strategy_kwargs.get(name, {}))
        if (
            result.ok
            and result.cookie_str
            and cookie_has_fresh_jwt(result.cookie_str, min_ttl_seconds)
        ):
            if verbose:
                print(
                    f"[auth] {name} OK (jwt_ttl={result.jwt_ttl_seconds}s, "
                    f"elapsed={result.elapsed_seconds:.1f}s)",
                    file=sys.stderr,
                )
            return result.cookie_str
        msg = result.error or (
            f"jwt_ttl={result.jwt_ttl_seconds}s below min={min_ttl_seconds}s"
        )
        last_error.append(f"{name}: {msg}")
        if verbose:
            print(f"[auth] {name} FAILED ({msg})", file=sys.stderr)

    raise AuthError("all strategies failed:\n  - " + "\n  - ".join(last_error))


__all__ = [
    "AuthError",
    "StrategyResult",
    "get_fresh_cookies",
    "run_strategy",
]
