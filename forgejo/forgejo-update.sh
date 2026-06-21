#!/usr/bin/env bash
# Update the self-hosted Forgejo deployment in place — scripts the manual update steps
# from forgejo/README.md into one command, with a pre-update volume snapshot, a health
# gate, and printed rollback steps. Run on the devbox HOST as the `dev` user (rootless
# podman + systemd --user); NOT inside a devcontainer.
#
# Forgejo tracks the moving LTS tag codeberg.org/forgejo/forgejo:15, so a server update
# is just: pull :15, and if the image actually changed, snapshot + restart + verify.
# The plan mandates "update only after a dump" — the volume snapshot here is that safety
# net (it captures the sqlite DB + repos + config, and unlike `forgejo dump` it works
# even on a zero-repo instance and needs no aura-farming SSH).
#
# Usage:
#   forgejo-update.sh                 # update server, then runner (default: all)
#   forgejo-update.sh server          # only the Forgejo server image
#   forgejo-update.sh runner          # only the CI runner image (rebuild from base)
#   forgejo-update.sh --check [all]   # report what WOULD update; never restarts
#   forgejo-update.sh --no-backup ... # skip the pre-update volume snapshot (faster/riskier)
#   forgejo-update.sh --force  ...    # restart even if the image digest is unchanged
#
# Env overrides:
#   SNAPSHOT_DIR  pre-update snapshots dir   (default ~/service-backups/forgejo)
#   KEEP          snapshots to retain        (default 5)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUADLET_DIR="$HOME/.config/containers/systemd"
SERVER_IMAGE="codeberg.org/forgejo/forgejo:15"
RUNNER_BASE_IMAGE="data.forgejo.org/forgejo/runner:12"
RUNNER_IMAGE="localhost/forgejo-runner:latest"
DATA_VOLUME="forgejo-data"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/service-backups/forgejo}"
KEEP="${KEEP:-5}"

CHECK=0; NO_BACKUP=0; FORCE=0; TARGET=""
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --no-backup) NO_BACKUP=1 ;;
    --force) FORCE=1 ;;
    server|runner|all) TARGET="$a" ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done
TARGET="${TARGET:-all}"

# Health URL comes from the deployed unit so it auto-adapts if the domain/IP changes.
ROOT_URL="$(grep -oP 'FORGEJO__server__ROOT_URL=\K\S+' "$QUADLET_DIR/forgejo.container" 2>/dev/null || true)"
ROOT_URL="${ROOT_URL:-http://devbox.tail76c33c.ts.net:3000/}"
HEALTH_URL="${ROOT_URL%/}/api/v1/version"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

snapshot_volume() {  # caller stops the service first so this is a *consistent* snapshot
  local vol="$1" ts f
  mkdir -p "$SNAPSHOT_DIR"
  ts="$(date +%Y%m%d-%H%M%S)"
  f="$SNAPSHOT_DIR/${vol}-${ts}.tar"
  echo "  snapshotting volume '$vol' -> $f"
  podman volume export "$vol" -o "$f"
  echo "  snapshot size: $(du -h "$f" | cut -f1)"
  # Retain newest $KEEP.
  ls -1t "$SNAPSHOT_DIR/${vol}-"*.tar 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
}

wait_health() {  # poll the API for up to ~60s
  local i
  for i in $(seq 1 30); do
    curl -fsS "$HEALTH_URL" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

update_server() {
  log "Forgejo server ($SERVER_IMAGE)"
  local prev_running new_id
  prev_running="$(podman inspect --format '{{.Image}}' forgejo 2>/dev/null || echo none)"
  echo "  pulling $SERVER_IMAGE ..."
  podman pull -q "$SERVER_IMAGE" >/dev/null
  new_id="$(podman image inspect --format '{{.Id}}' "$SERVER_IMAGE")"

  if [ "$prev_running" = "$new_id" ] && [ "$FORCE" != 1 ]; then
    echo "  already running the latest $SERVER_IMAGE — nothing to do."
    return 0
  fi
  if [ "$CHECK" = 1 ]; then
    echo "  UPDATE AVAILABLE: running ${prev_running:0:19} -> pulled ${new_id:0:19}"
    echo "  (--check: not restarting)"
    return 0
  fi

  if [ "$NO_BACKUP" = 1 ]; then
    echo "  (--no-backup) restarting forgejo.service onto the new image ..."
    systemctl --user restart forgejo.service
  else
    echo "  stopping forgejo.service for a consistent snapshot ..."
    systemctl --user stop forgejo.service
    if ! snapshot_volume "$DATA_VOLUME"; then
      echo "  snapshot failed — restarting the (old) service and aborting." >&2
      systemctl --user start forgejo.service
      return 1
    fi
    echo "  starting forgejo.service onto the new image ..."
    systemctl --user start forgejo.service
  fi
  if wait_health; then
    echo "  OK — $(curl -fsS "$HEALTH_URL")"
    echo "  previous image kept for rollback: ${prev_running:0:19}"
  else
    echo "  !! HEALTH CHECK FAILED after restart. Recent logs:" >&2
    podman logs --tail 20 forgejo 2>&1 | sed 's/^/    /' >&2
    cat >&2 <<EOF

  ROLLBACK (previous image still local):
    podman tag $prev_running $SERVER_IMAGE
    systemctl --user stop forgejo.service
    # for a clean data restore, recreate the volume from the snapshot:
    #   podman volume rm $DATA_VOLUME && podman volume create $DATA_VOLUME
    #   podman volume import $DATA_VOLUME "$SNAPSHOT_DIR/${DATA_VOLUME}-<ts>.tar"
    systemctl --user start forgejo.service
EOF
    return 1
  fi
}

update_runner() {
  log "Forgejo runner ($RUNNER_IMAGE)"
  if [ "$CHECK" = 1 ]; then
    echo "  pulling runner binary base $RUNNER_BASE_IMAGE to check for a newer build ..."
    podman pull -q "$RUNNER_BASE_IMAGE" >/dev/null || true
    echo "  (--check: not rebuilding/restarting. Runner is rebuilt FROM the local base"
    echo "   image too — run ./build.sh first if you want the latest dev base.)"
    return 0
  fi
  echo "  pulling runner binary base $RUNNER_BASE_IMAGE ..."
  podman pull -q "$RUNNER_BASE_IMAGE" >/dev/null
  echo "  rebuilding $RUNNER_IMAGE (FROM the local dev base) ..."
  podman build -t "$RUNNER_IMAGE" "$SCRIPT_DIR/runner"
  echo "  restarting forgejo-runner.service ..."
  systemctl --user restart forgejo-runner.service
  # Registration lives on the forgejo-runner-data volume, not the image, so no re-register.
  local i
  for i in $(seq 1 20); do
    if [ "$(systemctl --user is-active forgejo-runner.service)" = active ] \
       && podman logs --tail 30 forgejo-runner 2>&1 | grep -q 'declared successfully'; then
      echo "  OK — runner reconnected:"
      podman logs --tail 3 forgejo-runner 2>&1 | sed 's/^/    /'
      return 0
    fi
    sleep 2
  done
  echo "  !! runner did not report 'declared successfully' after restart. Logs:" >&2
  podman logs --tail 20 forgejo-runner 2>&1 | sed 's/^/    /' >&2
  return 1
}

case "$TARGET" in
  server) update_server ;;
  runner) update_runner ;;
  all)    update_server; update_runner ;;
esac

log "Done."
