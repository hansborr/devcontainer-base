#!/usr/bin/env bash
# Host-side lint entrypoint. Needs nothing installed on the host: it runs
# lint-checks.sh inside the already-built base image, which carries all three
# linters (shellcheck/hadolint/yamllint). CI runs lint-checks.sh directly.
set -euo pipefail
cd "$(dirname "$0")"
exec podman run --rm -v "$PWD:/lint:ro,z" -w /lint \
    localhost/claude-devcontainer:latest ./lint-checks.sh
