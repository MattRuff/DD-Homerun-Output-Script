"""CLI for the auth harness.

Usage::

    # Pick a fresh cookie string and print it to stdout
    python -m auth fetch --priority playwright,refresh_token,applescript,rookiepy

    # One-time interactive Playwright login
    python -m auth bootstrap-playwright

    # Sniff Homerun's refresh endpoint via Playwright network logs
    python -m auth discover-refresh

    # Benchmark every strategy
    python -m auth benchmark
"""

from __future__ import annotations

import argparse
import sys

from . import AuthError, get_fresh_cookies, run_strategy

DEFAULT_PRIORITY = ["refresh_token", "playwright", "applescript", "rookiepy"]


def _cmd_fetch(args) -> int:
    priority = [s.strip() for s in args.priority.split(",") if s.strip()]
    try:
        cookie_str = get_fresh_cookies(
            priority,
            min_ttl_seconds=args.min_ttl,
            verbose=args.verbose,
        )
    except AuthError as e:
        print(str(e), file=sys.stderr)
        return 1
    print(cookie_str)
    return 0


def _cmd_bootstrap_playwright(args) -> int:
    from .strategy_playwright import DEFAULT_STATE_PATH, bootstrap

    state_path = args.state_path or DEFAULT_STATE_PATH
    saved = bootstrap(state_path)
    print(f"Saved storage state to: {saved}", file=sys.stderr)
    return 0


def _cmd_discover_refresh(args) -> int:
    from .strategy_refresh_token import discover_refresh_endpoint

    url = discover_refresh_endpoint(storage_state_path=args.state_path)
    if url:
        print(url)
        return 0
    print("No refresh endpoint observed.", file=sys.stderr)
    return 1


def _cmd_benchmark(args) -> int:
    rows = []
    priority = [s.strip() for s in args.priority.split(",") if s.strip()]
    for name in priority:
        result = run_strategy(name)
        rows.append(result)
    width = max(len(r.name) for r in rows)
    print(
        f"{'strategy':<{width}}  {'ok':<3}  {'elapsed_s':>9}  "
        f"{'jwt_ttl_s':>10}  error"
    )
    print("-" * (width + 50))
    for r in rows:
        ok = "yes" if r.ok else "no"
        ttl = "" if r.jwt_ttl_seconds is None else str(r.jwt_ttl_seconds)
        err = (r.error or "").splitlines()[0] if r.error else ""
        print(
            f"{r.name:<{width}}  {ok:<3}  {r.elapsed_seconds:>9.1f}  "
            f"{ttl:>10}  {err}"
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m auth")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_fetch = sub.add_parser("fetch", help="Print a fresh cookie string to stdout")
    p_fetch.add_argument(
        "--priority",
        default=",".join(DEFAULT_PRIORITY),
        help="Comma-separated strategy order",
    )
    p_fetch.add_argument(
        "--min-ttl",
        type=int,
        default=600,
        help="Minimum required JWT TTL in seconds (default: 600 — Homerun JWTs live ~17 min)",
    )
    p_fetch.add_argument("-v", "--verbose", action="store_true")
    p_fetch.set_defaults(func=_cmd_fetch)

    p_boot = sub.add_parser(
        "bootstrap-playwright",
        help="One-time interactive login that saves storage_state.json",
    )
    p_boot.add_argument("--state-path", default=None)
    p_boot.set_defaults(func=_cmd_bootstrap_playwright)

    p_disc = sub.add_parser(
        "discover-refresh",
        help="Use Playwright to find the JWT refresh endpoint",
    )
    p_disc.add_argument("--state-path", default=None)
    p_disc.set_defaults(func=_cmd_discover_refresh)

    p_bench = sub.add_parser(
        "benchmark",
        help="Run each strategy and print a results table",
    )
    p_bench.add_argument(
        "--priority",
        default=",".join(DEFAULT_PRIORITY),
    )
    p_bench.set_defaults(func=_cmd_benchmark)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
