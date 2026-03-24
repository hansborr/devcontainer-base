#!/bin/bash
set -euo pipefail

# Temporarily opens the firewall, installs apt packages, then restores it.
# Usage: sudo fw-install <package> [package...]
# Example: sudo fw-install poppler-utils imagemagick

if [ $# -eq 0 ]; then
    echo "Usage: fw-install <package> [package...]" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: fw-install must be run as root (use sudo)" >&2
    exit 1
fi

# Find and remove the REJECT rule to open outbound traffic
REJECT_RULE=$(iptables -nL OUTPUT --line-numbers | grep -i reject | awk '{print $1}')
if [ -n "$REJECT_RULE" ]; then
    iptables -D OUTPUT "$REJECT_RULE"
fi
iptables -P OUTPUT ACCEPT

echo "Firewall opened. Installing: $*"

apt-get update && apt-get install -y "$@"
EXIT_CODE=$?

echo "Restoring firewall..."
/usr/local/bin/init-firewall.sh

exit $EXIT_CODE
