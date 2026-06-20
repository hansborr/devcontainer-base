#!/usr/bin/env bash
# Nightly Forgejo backup: dump *inside* the container, copy the archive out to the
# host, then rsync it to aura-farming over the tailnet. The GitHub push mirror backs
# up code only; `forgejo dump` is what captures issues, PRs, settings, attachments,
# the Actions/CI history, and the sqlite DB. Runs as the systemd --user oneshot
# forgejo-dump.service, scheduled nightly by forgejo-dump.timer.
#
# Config (target host, retention) is read from forgejo/.env — copy .env.example to
# .env. Prereq: an SSH key on the devbox *host* (the `dev` user) trusted by
# aura-farming — this is separate from the in-container ssh-agent key. See README §Backups.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional overrides from forgejo/.env (gitignored).
if [ -f "$SCRIPT_DIR/.env" ]; then set -a; . "$SCRIPT_DIR/.env"; set +a; fi
AURA_HOST="${AURA_HOST:-aura-farming.tail76c33c.ts.net}"
AURA_USER="${AURA_USER:-dev}"
REMOTE_DIR="${REMOTE_DIR:-forgejo-backups}"
RETENTION="${RETENTION:-14}"

ts="$(date +%Y%m%d-%H%M%S)"
name="forgejo-dump-${ts}.zip"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# 1. Dump inside the container as the git user (uid 1000). --config points at the
#    standard image's app.ini (rootless image would be /etc/gitea/app.ini instead).
podman exec -u 1000 -w /tmp forgejo \
  forgejo dump --config /data/gitea/conf/app.ini --file "/tmp/${name}" --skip-log

# 2. Copy the archive out of the container, then remove it from the container's /tmp.
podman cp "forgejo:/tmp/${name}" "${stage}/${name}"
podman exec forgejo rm -f "/tmp/${name}"

# 3. Ship it to aura-farming over the tailnet (host SSH key, not the in-container agent).
ssh "${AURA_USER}@${AURA_HOST}" "mkdir -p ~/${REMOTE_DIR}"
rsync -e ssh -a "${stage}/${name}" "${AURA_USER}@${AURA_HOST}:~/${REMOTE_DIR}/"

# 4. Prune old dumps on the remote, keeping the newest $RETENTION.
ssh "${AURA_USER}@${AURA_HOST}" \
  "ls -1t ~/${REMOTE_DIR}/forgejo-dump-*.zip 2>/dev/null | tail -n +$((RETENTION + 1)) | xargs -r rm -f"

echo "Forgejo backup ${name} -> ${AURA_USER}@${AURA_HOST}:~/${REMOTE_DIR}/ (retain ${RETENTION})"
