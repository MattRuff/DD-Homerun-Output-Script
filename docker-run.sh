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
  echo "Error: rookiepy is not installed in '$PYTHON'." >&2
  echo "  Fix: $PYTHON -m pip install rookiepy" >&2
  echo "  Or create a venv:  python3.12 -m venv .venv && .venv/bin/pip install rookiepy" >&2
  exit 1
fi

# --- Extract cookies from Chrome ---

COOKIES=$("$PYTHON" -c "
import rookiepy, sys
cookies = rookiepy.chrome(['homerunpresales.com'])
if not cookies:
    print('No Homerun cookies in Chrome. Log in first.', file=sys.stderr)
    sys.exit(1)
if not any(c['name'] == 'jwttoken' for c in cookies):
    print('jwttoken not found — log in to Homerun in Chrome and hard-refresh (Cmd+Shift+R).', file=sys.stderr)
    sys.exit(1)
seen = {}
for c in cookies:
    seen[c['name']] = c['value']
print('; '.join(f'{k}={v}' for k, v in seen.items()))
")

docker run --rm -e HOMERUN_COOKIES="$COOKIES" "${IMAGE}:${TAG}" "$@"
