#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# Block all IPv6 traffic — the allowlist rules are IPv4-only
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Reset default policies to ACCEPT before flushing so traffic isn't dropped
# between the flush and when the new rules are applied (also makes re-runs safe)
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# Allow outbound DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
# Allow inbound DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# NOTE: deliberately NO global tcp/22 allow — it would defeat the egress
# allowlist (ssh/scp/tunnel to any host). GitHub SSH is covered by the
# allowed-domains ipset (matched on all ports) and devbox SSH by its
# port-2222 rule below; for ad-hoc SSH elsewhere use `sudo fw off`.
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges.
# The unauthenticated /meta endpoint is rate-limited (60 req/hr/IP), and an
# abort here kills postStartCommand and blocks container start — so retry,
# then fall back to the last-good copy cached on the persist volume.
GH_META_CACHE=/home/node/persist/cache/github-meta.json
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -fsSL --retry 3 --retry-delay 2 https://api.github.com/meta || true)
if [ -n "$gh_ranges" ] && echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    # Cache the last-good copy. This script runs as root and may precede
    # init-persist-dirs.sh, so create the cache dir node-owned to keep later
    # toolchain writes into persist/cache working.
    if install -d -o node -g node "${GH_META_CACHE%/*}" 2>/dev/null; then
        tmp=$(mktemp) && printf '%s\n' "$gh_ranges" > "$tmp" && chmod 0644 "$tmp" \
            && mv "$tmp" "$GH_META_CACHE" || true
    fi
elif [ -s "$GH_META_CACHE" ] && jq -e '.web and .api and .git' "$GH_META_CACHE" >/dev/null 2>&1; then
    echo "WARN: live GitHub /meta fetch failed — using cached copy $GH_META_CACHE"
    gh_ranges=$(cat "$GH_META_CACHE")
else
    echo "ERROR: GitHub /meta unavailable and no valid cache at $GH_META_CACHE"
    exit 1
fi

# Aggregate GitHub's published ranges. We fold in the `.copilot` section
# alongside web/api/git so the GitHub Copilot CLI works: api.githubcopilot.com
# sits in 140.82.112.0/20 (already in web/api), but the Azure-hosted
# copilot-proxy.githubusercontent.com (138.91.182.224) is ONLY in `.copilot`.
# The copilot section's IPv6 ranges duplicate ones already in web/api/git and
# are dropped by `aggregate` (IPv4-only), same as today. `+ .copilot` is a safe
# no-op (jq treats array + null as the array) if GitHub ever drops the section.
echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add --exist allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git + .copilot)[]' | aggregate -q)

# Resolve and add allowed domains
# Required domains: failure aborts startup
REQUIRED_DOMAINS=(
    "registry.npmjs.org"
    "api.anthropic.com"
    "downloads.claude.ai"
    "index.crates.io"
    "static.crates.io"
    "static.rust-lang.org"
)

# Optional domains: failure logs a warning but continues
OPTIONAL_DOMAINS=(
    "binaries.prisma.sh"
    "sentry.io"
    "statsig.anthropic.com"
    "statsig.com"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
    "cdn.playwright.dev"
    "storage.googleapis.com"
    "api.openai.com"
    "cdn.openai.com"
    "auth.openai.com"
    "auth0.openai.com"
    "chatgpt.com"
    "ab.chatgpt.com"
    "pypi.org"
    "files.pythonhosted.org"
    # Cursor CLI: agent API (api2/api3/api4), codebase indexing (repo42),
    # login (cursor.com + authenticator), self-update/installer (downloads).
    # Some are Cloudflare-fronted, so edge IPs can rotate mid-session — same
    # caveat as chatgpt.com; re-run `sudo fw on` if cursor goes EHOSTUNREACH.
    "cursor.com"
    "api2.cursor.sh"
    "api3.cursor.sh"
    "api4.cursor.sh"
    "repo42.cursor.sh"
    "authenticator.cursor.sh"
    "downloads.cursor.com"
    # Agent-request endpoints (docs list *.api5.cursor.sh — no wildcard
    # support here, so the documented concrete names are enumerated; the
    # bare api5/authentication apexes have no A records and are omitted)
    # and the authentication/token-issuer hosts behind CLI login.
    "agent.api5.cursor.sh"
    "agentn.api5.cursor.sh"
    "agent.us.api5.cursor.sh"
    "agentn.us.api5.cursor.sh"
    "agent.global.api5.cursor.sh"
    "agentn.global.api5.cursor.sh"
    "authenticate.cursor.sh"
    "prod.authentication.cursor.sh"
)

resolve_and_add() {
    local domain="$1"
    local required="$2"
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        if [ "$required" = "true" ]; then
            echo "ERROR: Failed to resolve required domain $domain"
            exit 1
        else
            echo "WARN: Failed to resolve optional domain $domain — skipping"
            return 0
        fi
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add --exist allowed-domains "$ip"
    done < <(echo "$ips")
}

for domain in "${REQUIRED_DOMAINS[@]}"; do
    resolve_and_add "$domain" true
done

for domain in "${OPTIONAL_DOMAINS[@]}"; do
    resolve_and_add "$domain" false
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Allow the self-hosted devbox services over the tailnet: Forgejo HTTP/SSH git
# (3000/2222) and the Dolt remotesapi used by beads `bd dolt push/pull` (50051).
# Port-scoped, and only when the host resolves into the tailnet CGNAT range
# (100.64.0.0/10), so an empty/hijacked DNS answer can't open a hole to the world.
# This single block reconciles the Forgejo plan §6.2 and the Dolt deploy guide
# (dolt/README.md) — do NOT also add the Forgejo-only block from the plan; the 50051
# entry here covers beads.
DEVBOX_HOST="devbox.tail76c33c.ts.net"
devbox_ip=$(dig +short A "$DEVBOX_HOST" 2>/dev/null | head -n1 || true)
if [ -z "$devbox_ip" ]; then
    devbox_ip="100.65.243.16"   # fallback if MagicDNS isn't resolvable at firewall time
fi
if [[ "$devbox_ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
    for port in 3000 2222 50051; do   # Forgejo http, Forgejo ssh, Dolt remotesapi (beads)
        iptables -A OUTPUT -p tcp -d "$devbox_ip" --dport "$port" -j ACCEPT
    done
    echo "Allowed devbox services at $devbox_ip on tcp/{3000,2222,50051}"
else
    echo "WARN: $DEVBOX_HOST resolved to '$devbox_ip' (not in 100.64.0.0/10) — skipping devbox allow"
fi

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
