#!/usr/bin/env bash
# Install (or update) a systemd user timer that runs prune-images.sh weekly.
#
# Idempotent: re-run after editing the schedule or moving the repo to refresh
# the units. The service calls prune-images.sh by absolute path from this repo.
#
# Inspect:   systemctl --user list-timers podman-image-prune.timer
# Run now:   systemctl --user start podman-image-prune.service
# Logs:      journalctl --user -u podman-image-prune.service
# Disable:   systemctl --user disable --now podman-image-prune.timer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/podman-image-prune.service" <<EOF
[Unit]
Description=Prune unused Podman images older than threshold

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/prune-images.sh
EOF

cat > "$UNIT_DIR/podman-image-prune.timer" <<EOF
[Unit]
Description=Weekly Podman image prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now podman-image-prune.timer

echo "Installed podman-image-prune.timer:"
systemctl --user list-timers podman-image-prune.timer --no-pager

# Note: user systemd units only run while you are logged in. To let the timer
# fire even when logged out, enable lingering once:  sudo loginctl enable-linger "$USER"
