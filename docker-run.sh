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

PYTHON="${HOMERUN_PYTHON:-python3}"

COOKIES=$("$PYTHON" -c "
import rookiepy, sys
cookies = rookiepy.chrome(['homerunpresales.com'])
if not cookies:
    print('No Homerun cookies in Chrome. Log in first.', file=sys.stderr)
    sys.exit(1)
if not any(c['name'] == 'jwttoken' for c in cookies):
    print('jwttoken not found — log in to Homerun in Chrome.', file=sys.stderr)
    sys.exit(1)
seen = {}
for c in cookies:
    seen[c['name']] = c['value']
print('; '.join(f'{k}={v}' for k, v in seen.items()))
")

docker run --rm -e HOMERUN_COOKIES="$COOKIES" "${IMAGE}:${TAG}" "$@"
