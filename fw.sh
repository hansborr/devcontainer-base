#!/bin/bash
set -euo pipefail

# fw — toggle the devcontainer egress firewall on/off.
#
#   sudo fw off      Open egress (e.g. to let agents do web research): delete the
#                    REJECT catch-all and set the OUTPUT policy to ACCEPT. Inbound
#                    stays locked. Lasts until you run `fw on` OR the container
#                    restarts — postStartCommand re-applies the full firewall on
#                    every start, so a forgotten `off` self-heals.
#   sudo fw on       Re-apply the full allowlist firewall (runs init-firewall.sh,
#                    which re-resolves the allowlist domains and self-verifies).
#   sudo fw status   Report whether egress is restricted or open.
#
# The firewall is the sandbox's egress boundary, so opening it is deliberately a
# manual, root-only switch. For a one-shot package install that re-secures
# automatically afterwards, use `fw-install <pkg>` instead.

usage() { echo "usage: fw {on|off|status}" >&2; exit 2; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "fw: must run as root — try: sudo fw ${1:-}" >&2
        exit 1
    fi
}

# The allowlist firewall ends the OUTPUT chain with a REJECT catch-all; its
# presence is our signal that the firewall is currently applied.
is_restricted() { iptables -nL OUTPUT 2>/dev/null | grep -q 'REJECT'; }

case "${1:-}" in
    off)
        require_root off
        # Delete every REJECT rule from OUTPUT. Line numbers shift after each
        # delete, so re-read the table and remove the first match until none remain.
        while line=$(iptables -nL OUTPUT --line-numbers | awk '/REJECT/{print $1; exit}'); [ -n "$line" ]; do
            iptables -D OUTPUT "$line"
        done
        iptables -P OUTPUT ACCEPT
        echo "fw: OFF — egress open. Re-secure with 'sudo fw on' (auto-restored on container restart)."
        ;;
    on)
        require_root on
        exec /usr/local/bin/init-firewall.sh
        ;;
    status)
        require_root status
        if is_restricted; then
            echo "fw: ON  — egress restricted to the allowlist"
        else
            echo "fw: OFF — egress open"
        fi
        ;;
    *)
        usage
        ;;
esac
