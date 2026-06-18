#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="claude-devcontainer:latest"

echo "Building shared devcontainer base image: $IMAGE_NAME"

# Inherit the host timezone so container clocks/logs match this machine.
# Override with `TZ=America/New_York ./build.sh`; falls back to the Dockerfile
# ARG default if detection fails.
TZ="${TZ:-$(timedatectl show -p Timezone --value 2>/dev/null \
      || readlink -f /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')}"

if [ -n "$TZ" ]; then
  echo "Using timezone: $TZ"
  podman build --build-arg TZ="$TZ" -t "$IMAGE_NAME" "$SCRIPT_DIR"
else
  podman build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi
echo "Done. Image: $IMAGE_NAME"
