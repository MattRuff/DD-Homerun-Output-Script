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

# --- Extract cookies from Chrome (all profiles) ---

COOKIES=$("$PYTHON" -c "
import sys, os, glob, shutil, sqlite3, subprocess, tempfile

def _get_cookies():
    # Use the same multi-profile extraction as the main script.
    # Reads from all Chrome profiles via macOS Keychain + SQLite.
    if sys.platform != 'darwin':
        try:
            import rookiepy
            return rookiepy.chrome(['homerunpresales.com'])
        except Exception as e:
            print(f'Error: could not read Chrome cookies: {e}', file=sys.stderr)
            sys.exit(1)

    chrome_dir = os.path.expanduser('~/Library/Application Support/Google/Chrome')
    if not os.path.isdir(chrome_dir):
        print('Error: Chrome not found at default path.', file=sys.stderr)
        sys.exit(1)

    try:
        key_raw = subprocess.check_output(
            ['security', 'find-generic-password', '-w', '-s', 'Chrome Safe Storage', '-a', 'Chrome'],
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        print(
            'Error: could not read Chrome Safe Storage key from Keychain.\n'
            '  Keychain prompt: click \"Always Allow\" for \"Chrome Safe Storage\".',
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.backends import default_backend
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except ImportError:
        print('Error: cryptography package not installed. Run: pip install cryptography', file=sys.stderr)
        sys.exit(1)

    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    kdf = PBKDF2HMAC(algorithm=hashes.SHA1(), length=16, salt=b'saltysalt', iterations=1003, backend=default_backend())
    aes_key = kdf.derive(key_raw)

    def _decrypt(enc):
        if not enc or enc[:3] != b'v10':
            return ''
        iv, ct = enc[3:19], enc[19:]
        if len(ct) % 16 != 0:
            return ''
        cipher = Cipher(algorithms.AES(aes_key), modes.CBC(iv), backend=default_backend())
        dec = cipher.decryptor()
        pt = dec.update(ct) + dec.finalize()
        pad = pt[-1]
        pt = pt[:-pad][16:]  # strip PKCS7 padding and 16-byte random prefix
        try:
            return pt.decode('utf-8')
        except UnicodeDecodeError:
            return pt.decode('latin-1')

    all_cookies = {}
    for db_path in sorted(glob.glob(os.path.join(chrome_dir, '*/Cookies'))):
        with tempfile.NamedTemporaryFile(suffix='.db', delete=False) as tmp:
            tmp_path = tmp.name
        try:
            shutil.copy2(db_path, tmp_path)
            conn = sqlite3.connect(tmp_path)
            rows = conn.execute(
                \"SELECT name, encrypted_value, host_key FROM cookies WHERE host_key LIKE '%homerun%'\"
            ).fetchall()
            conn.close()
        except Exception:
            continue
        finally:
            try: os.unlink(tmp_path)
            except OSError: pass
        for name, enc_val, host in rows:
            value = _decrypt(bytes(enc_val))
            all_cookies[name] = {'name': name, 'value': value, 'domain': host}

    return list(all_cookies.values())

cookies = _get_cookies()
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

# --- Detect -o / --output-dir and mount it into the container ---

DOCKER_ARGS=()
SCRIPT_ARGS=()
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -o=*|--output-dir=*)
      OUTPUT_DIR="${1#*=}"
      shift
      ;;
    *)
      SCRIPT_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="$HOME/Documents/homerun_output"
fi
ABS_OUTPUT="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")" || ABS_OUTPUT="$OUTPUT_DIR"
mkdir -p "$ABS_OUTPUT"
DOCKER_ARGS+=(-v "$ABS_OUTPUT:/output")
SCRIPT_ARGS+=(-o /output)

docker run --rm -e HOMERUN_COOKIES="$COOKIES" "${DOCKER_ARGS[@]}" "${IMAGE}:${TAG}" "${SCRIPT_ARGS[@]}"
