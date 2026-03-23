#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="claude-devcontainer:latest"

echo "Building shared devcontainer base image: $IMAGE_NAME"
podman build -t "$IMAGE_NAME" "$SCRIPT_DIR"
echo "Done. Image: $IMAGE_NAME"
