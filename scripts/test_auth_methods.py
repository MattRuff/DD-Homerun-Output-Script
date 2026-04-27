#!/usr/bin/env python3
"""Benchmark every Homerun auth strategy and print a results table.

Run from the repo root::

    .venv/bin/python homerun-presales-exporter/scripts/test_auth_methods.py

This is a thin wrapper around ``python -m auth benchmark`` so the script lives
next to the rest of the operational tooling and can be invoked by docs/scripts
without remembering the module path.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG_PARENT = HERE.parent  # homerun-presales-exporter/
if str(PKG_PARENT) not in sys.path:
    sys.path.insert(0, str(PKG_PARENT))

from auth.__main__ import main as auth_main  # noqa: E402


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] != "benchmark":
        args = ["benchmark", *args]
    raise SystemExit(auth_main(args))
