#!/usr/bin/env bash
# Build and push to Docker Hub. Requires Docker running and `docker login`.
# Usage: $0 [tag]   (default tag: latest)
# Override image with: DOCKER_IMAGE=user/repo $0 [tag]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${DOCKER_IMAGE:-matthewruyffelaert667/homerun-ddog-scripts}"
TAG="${1:-latest}"
IMG="${IMAGE}:${TAG}"
docker build -t "$IMG" "$SCRIPT_DIR"
docker push "$IMG"
echo "Pushed $IMG"
