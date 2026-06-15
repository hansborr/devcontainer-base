#!/usr/bin/env bash
# Prune unused Podman images older than PRUNE_UNTIL (default 7 days / 168h).
#
# Removes every image that is (a) not currently used by any container and
# (b) older than the threshold. This INCLUDES tagged images such as the
# localhost/claude-devcontainer base image when nothing references it and it
# has aged past the threshold — the age gate is the only thing protecting it,
# so keep PRUNE_UNTIL comfortably longer than your base-image rebuild cadence.
#
# Run on a schedule by the podman-image-prune.timer systemd user unit
# (install with ./install-prune-timer.sh). Safe to run by hand to prune now:
#   ./prune-images.sh                 # default 7-day threshold
#   PRUNE_UNTIL=720h ./prune-images.sh  # keep anything newer than 30 days
set -euo pipefail

PRUNE_UNTIL="${PRUNE_UNTIL:-168h}"

echo "== podman image prune (removing unused images older than ${PRUNE_UNTIL}) =="
echo "--- disk usage before ---"
podman system df

podman image prune --all --force --filter "until=${PRUNE_UNTIL}"

echo "--- disk usage after ---"
podman system df
