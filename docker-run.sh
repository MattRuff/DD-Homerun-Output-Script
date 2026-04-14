#!/usr/bin/env bash
# Run the Homerun exporter in Docker with auto-extracted Chrome cookies.
# Usage: ./docker-run.sh [args...]
#   ./docker-run.sh --all
#   ./docker-run.sh --list
#   ./docker-run.sh "Acme Corp - New Business - Annual - 2026"
#
# Requires rookiepy installed on the host (pip install rookiepy).
# Override image with: DOCKER_IMAGE=user/repo ./docker-run.sh [args...]
set -euo pipefail

IMAGE="${DOCKER_IMAGE:-matthewruyffelaert667/homerun-ddog-scripts}"
TAG="${DOCKER_TAG:-latest}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${HOMERUN_PYTHON:-}" ]; then
  PYTHON="$HOMERUN_PYTHON"
elif [ -x "$SCRIPT_DIR/../.venv/bin/python" ]; then
  PYTHON="$SCRIPT_DIR/../.venv/bin/python"
elif [ -x "$SCRIPT_DIR/.venv/bin/python" ]; then
  PYTHON="$SCRIPT_DIR/.venv/bin/python"
else
  PYTHON="python3"
fi

# --- Validate Python environment ---

if ! command -v "$PYTHON" &>/dev/null; then
  echo "Error: Python not found at '$PYTHON'." >&2
  echo "  Install Python 3.12 or set HOMERUN_PYTHON to your Python binary." >&2
  echo "  Example: brew install python@3.12" >&2
  exit 1
fi

PY_VERSION=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>&1) || {
  echo "Error: could not determine Python version from '$PYTHON'." >&2
  exit 1
}

PY_MAJOR=$("$PYTHON" -c "import sys; print(sys.version_info.major)")
PY_MINOR=$("$PYTHON" -c "import sys; print(sys.version_info.minor)")

if [ "$PY_MAJOR" -lt 3 ] || ([ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]); then
  echo "Error: Python >= 3.10 required (found $PY_VERSION at $PYTHON)." >&2
  exit 1
fi

if [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -gt 12 ]; then
  echo "Error: rookiepy requires Python <= 3.12 (found $PY_VERSION at $PYTHON)." >&2
  echo "  Fix: install Python 3.12 and create a venv:" >&2
  echo "    brew install python@3.12" >&2
  echo "    python3.12 -m venv .venv" >&2
  echo "    .venv/bin/pip install rookiepy" >&2
  echo "  Then re-run this script (it auto-detects .venv)." >&2
  exit 1
fi

if ! "$PYTHON" -c "import rookiepy" &>/dev/null; then
  echo "rookiepy not found — installing..." >&2
  "$PYTHON" -m pip install rookiepy >&2 || {
    echo "Error: failed to install rookiepy." >&2
    echo "  Try manually: $PYTHON -m pip install rookiepy" >&2
    exit 1
  }
fi

# --- Extract cookies from Chrome ---

COOKIES=$("$PYTHON" -c "
import sys
try:
    import rookiepy
except ImportError:
    print('Error: rookiepy not importable even after install attempt.', file=sys.stderr)
    sys.exit(1)
try:
    cookies = rookiepy.chrome(['homerunpresales.com'])
except RuntimeError as e:
    err = str(e).lower()
    if 'can\'t find cookies' in err or 'no such file' in err:
        print(
            'Error: could not read Chrome cookie database.\n'
            '  On macOS this usually means your terminal app lacks Full Disk Access.\n'
            '  Fix: System Settings > Privacy & Security > Full Disk Access\n'
            '        -> toggle ON your terminal (Terminal, iTerm2, Cursor, VS Code, etc.)\n'
            '        -> restart the terminal and try again.',
            file=sys.stderr,
        )
    else:
        print(
            f'Error: rookiepy could not read Chrome cookies: {e}\n'
            '  On macOS, check:\n'
            '    1. Full Disk Access granted to your terminal app\n'
            '    2. Keychain prompt: click \"Always Allow\" for \"Chrome Safe Storage\"',
            file=sys.stderr,
        )
    sys.exit(1)
except OSError as e:
    print(
        f'Error: OS permission error reading Chrome cookies: {e}\n'
        '  On macOS: grant Full Disk Access to your terminal app:\n'
        '    System Settings > Privacy & Security > Full Disk Access\n'
        '  Then restart the terminal and try again.',
        file=sys.stderr,
    )
    sys.exit(1)
if not cookies:
    print('Error: no Homerun cookies found in Chrome. Log in to Homerun first.', file=sys.stderr)
    sys.exit(1)
if not any(c['name'] == 'jwttoken' for c in cookies):
    print(
        'Error: jwttoken not found in Chrome cookies.\n'
        '  Log in to Homerun in Chrome, do a hard refresh (Cmd+Shift+R),\n'
        '  wait for the page to fully load, then re-run.',
        file=sys.stderr,
    )
    sys.exit(1)
seen = {}
for c in cookies:
    seen[c['name']] = c['value']
print('; '.join(f'{k}={v}' for k, v in seen.items()))
")

docker run --rm -e HOMERUN_COOKIES="$COOKIES" "${IMAGE}:${TAG}" "$@"
