#!/usr/bin/env bash
set -euo pipefail

# Usage: devcontainer-rebuild.sh [path-to-repo]
# Example: devcontainer-rebuild.sh ~/repos/dnd-claude

REPO_DIR="${1:-.}"
REPO_DIR="$(cd "$REPO_DIR" && pwd)"
COMPOSE_FILE="$REPO_DIR/.devcontainer/docker-compose.yml"

# The shared cross-project 'persist' volume is declared `external` in the compose
# templates, so it must exist before launch. Create it once, idempotently.
podman volume create persist >/dev/null 2>&1 || true

if [ -f "$COMPOSE_FILE" ]; then
    echo "Tearing down existing containers (compose)..."
    podman-compose -f "$COMPOSE_FILE" down
fi

echo "Rebuilding and launching devcontainer..."
devcontainer up \
    --workspace-folder "$REPO_DIR" \
    --docker-path podman \
    --docker-compose-path podman-compose \
    --remove-existing-container
