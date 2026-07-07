#!/bin/bash
# Temporarily open the firewall, install apt packages, then ALWAYS re-secure it
# — even if the install fails. The EXIT trap is what guarantees that: without it,
# a failing apt-get under the shell's error handling would abort the script with
# egress left wide open.
#
# Usage: sudo fw-install <package> [package...]
# Example: sudo fw-install poppler-utils imagemagick
#
# This is for one-shot installs only. To open the firewall and LEAVE it open
# (e.g. for web research), use `sudo fw off` / `sudo fw on` instead.
#
# Note: -e is intentionally OFF so we keep control after an apt failure; the EXIT
# trap re-secures and the script still exits with apt's real status (it's the
# last command). Packages installed this way do not survive a container rebuild.
set -uo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: fw-install <package> [package...]" >&2
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: fw-install must be run as root (use sudo)" >&2
    exit 1
fi

# Re-secure on ANY exit: clean finish, apt failure, or interrupt. If the
# re-apply itself fails (e.g. GitHub /meta unreachable partway through, after
# rules were already flushed), fail CLOSED and loud: force the default OUTPUT
# policy to DROP so the sandbox never sits silently open until `sudo fw on`
# succeeds.
trap 'if ! /usr/local/bin/init-firewall.sh; then
        echo "CRITICAL: firewall re-apply FAILED — forcing egress DROP. Fix and run: sudo fw on" >&2
        iptables -P OUTPUT DROP
      fi' EXIT

/usr/local/bin/fw off >/dev/null
echo "Firewall opened. Installing: $*"
apt-get update && apt-get install -y "$@"
