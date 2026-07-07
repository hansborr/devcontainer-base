#!/usr/bin/env bash
# Update the self-hosted Dolt (beads remote) deployment — scripts the manual steps into
# one command with a pre-update volume snapshot, a health gate, and printed rollback.
# Run on the devbox HOST as the `dev` user (rootless podman + systemd --user); NOT inside
# a devcontainer.
#
# Unlike Forgejo (which tracks the moving :15 tag), dolt.container PINS an exact image
# version, so an update is a deliberate version bump: this script rewrites the Image= tag
# in dolt.container, re-applies the unit to ~/.config, restarts, and verifies. The tag
# bump is a real source change — commit dolt.container afterward.
#
# Usage:
#   dolt-update.sh <version>           # e.g. dolt-update.sh 2.2.5  -> pins :2.2.5
#   dolt-update.sh --check             # print current pinned/running version, then exit
#   dolt-update.sh --no-backup <ver>   # skip the pre-update volume snapshot (faster/riskier)
#   dolt-update.sh --force <ver>       # re-apply even if already pinned to <ver>
#
# Env overrides:
#   SNAPSHOT_DIR  pre-update snapshots dir   (default ~/service-backups/dolt)
#   KEEP          snapshots to retain        (default 5)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUADLET_DIR="$HOME/.config/containers/systemd"
UNIT_SRC="$SCRIPT_DIR/dolt.container"
UNIT_DST="$QUADLET_DIR/dolt.container"
IMAGE_REPO="docker.io/dolthub/dolt-sql-server"
CONTAINER="beads-dolt"
DATA_VOLUME="dolt"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/service-backups/dolt}"
KEEP="${KEEP:-5}"

CHECK=0; NO_BACKUP=0; FORCE=0; VERSION=""
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --no-backup) NO_BACKUP=1 ;;
    --force) FORCE=1 ;;
    --*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) VERSION="$a" ;;
  esac
done

current_pin="$(grep -oP "^Image=$IMAGE_REPO:\K\S+" "$UNIT_SRC" 2>/dev/null || true)"
running_img="$(podman inspect --format '{{.ImageName}}' "$CONTAINER" 2>/dev/null || echo 'not running')"

# remotesapi IP for the TCP liveness check, parsed from the unit (fallback to known IP).
TS_IP="$(grep -oP '^PublishPort=\K[0-9.]+(?=:50051:50051)' "$UNIT_SRC" 2>/dev/null || true)"
TS_IP="${TS_IP:-100.65.243.16}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

if [ "$CHECK" = 1 ]; then
  log "Dolt version"
  echo "  pinned in dolt.container : ${current_pin:-<none>}"
  echo "  running image           : $running_img"
  echo "  to update               : $0 <version>   (see https://github.com/dolthub/dolt/releases)"
  exit 0
fi

[ -n "$VERSION" ] || { echo "error: a target version is required (dolt pins an exact tag). Try: $0 --check" >&2; exit 2; }
if [ "$VERSION" = "$current_pin" ] && [ "$FORCE" != 1 ]; then
  echo "already pinned to $IMAGE_REPO:$VERSION (use --force to re-apply)."; exit 0
fi

log "Dolt update: ${current_pin:-?} -> $VERSION"

# Fail early if the target tag doesn't exist / can't be pulled.
echo "  pulling $IMAGE_REPO:$VERSION ..."
podman pull -q "$IMAGE_REPO:$VERSION" >/dev/null

# Pre-update snapshot of the beads data. Stop first so the export is consistent (Dolt's
# chunk store can be mid-write); the unit rewrite below then brings it back on $VERSION.
if [ "$NO_BACKUP" = 1 ]; then
  echo "  (--no-backup: skipping snapshot; will just restart onto $VERSION)"
else
  echo "  stopping dolt.service for a consistent snapshot ..."
  systemctl --user stop dolt.service
  mkdir -p "$SNAPSHOT_DIR"
  ts="$(date +%Y%m%d-%H%M%S)"
  snap="$SNAPSHOT_DIR/${DATA_VOLUME}-${ts}.tar"
  echo "  snapshotting volume '$DATA_VOLUME' -> $snap"
  if ! podman volume export "$DATA_VOLUME" -o "$snap"; then
    echo "  snapshot failed — restarting the (old) service and aborting." >&2
    systemctl --user start dolt.service
    exit 1
  fi
  echo "  snapshot size: $(du -h "$snap" | cut -f1)"
  ls -1t "$SNAPSHOT_DIR/${DATA_VOLUME}-"*.tar 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
fi

# Rewrite the pin in the repo source, then re-apply to ~/.config and reload + (re)start.
echo "  rewriting Image= tag in dolt.container ($current_pin -> $VERSION) ..."
sed -i "s|^Image=$IMAGE_REPO:.*|Image=$IMAGE_REPO:$VERSION|" "$UNIT_SRC"
cp "$UNIT_SRC" "$UNIT_DST"
systemctl --user daemon-reload
echo "  (re)starting $CONTAINER onto $VERSION ..."
systemctl --user restart dolt.service

# Health gate: container running + both ports (SQL 3306 loopback, remotesapi 50051) live.
ok=0
for _ in $(seq 1 30); do
  if [ "$(podman inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ] \
     && (exec 3<>/dev/tcp/127.0.0.1/3306) 2>/dev/null \
     && (exec 3<>/dev/tcp/"$TS_IP"/50051) 2>/dev/null; then
    ok=1; break
  fi
  sleep 2
done

if [ "$ok" = 1 ]; then
  log "OK — dolt is on $VERSION; SQL :3306 and remotesapi :50051 are accepting connections."
  echo "  Remember to commit the version bump:  git -C $(dirname "$SCRIPT_DIR") add dolt/dolt.container && git commit"
else
  echo "  !! HEALTH CHECK FAILED. Recent logs:" >&2
  podman logs --tail 20 "$CONTAINER" 2>&1 | sed 's/^/    /' >&2
  cat >&2 <<EOF

  ROLLBACK to $current_pin:
    sed -i "s|^Image=$IMAGE_REPO:.*|Image=$IMAGE_REPO:$current_pin|" "$UNIT_SRC"
    cp "$UNIT_SRC" "$UNIT_DST" && systemctl --user daemon-reload
    # for a clean data restore from the snapshot:
    #   systemctl --user stop dolt.service
    #   podman volume rm $DATA_VOLUME && podman volume create $DATA_VOLUME
    #   podman volume import $DATA_VOLUME "${snap:-$SNAPSHOT_DIR/${DATA_VOLUME}-<ts>.tar}"
    systemctl --user restart dolt.service
EOF
  exit 1
fi
