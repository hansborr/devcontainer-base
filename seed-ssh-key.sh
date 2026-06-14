#!/usr/bin/env bash
set -euo pipefail

# Seed your host SSH directory into the shared 'persist' Podman volume so every
# devcontainer can use it via the `~/.ssh -> ~/persist/.ssh` symlink baked into
# the base image.
#
# Why a volume instead of a bind mount: under enforcing SELinux a rootless-podman
# bind mount of ~/.ssh would need an `:z`/`:Z` relabel, which would also rewrite
# the label on ~/.ssh/authorized_keys and could lock sshd out of host logins.
# This script instead runs `tar` as your normal host user, reading ~/.ssh
# directly — it never bind-mounts or relabels your real ~/.ssh. Your key stays
# encrypted; nothing here decrypts it.
#
# Re-run this whenever you rotate keys or add a known_hosts entry you want shared.
#
# Usage: ./seed-ssh-key.sh [path-to-ssh-dir]    (default: ~/.ssh)

SSH_DIR="${1:-$HOME/.ssh}"

if [ ! -d "$SSH_DIR" ]; then
    echo "ERROR: $SSH_DIR does not exist" >&2
    exit 1
fi

podman volume create persist >/dev/null 2>&1 || true

# Stage into a dir literally named '.ssh' so it always lands at
# /home/node/persist/.ssh regardless of the source dir's name. `cp -a` preserves
# the 600/700 modes that ssh insists on. `podman volume import` MERGES, so any
# existing scratch already in 'persist' is left untouched.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/.ssh"
cp -a "$SSH_DIR/." "$stage/.ssh/"
tar -C "$stage" -cf - .ssh | podman volume import persist -

echo "Seeded $SSH_DIR into the 'persist' volume."
echo "Containers see it at /home/node/persist/.ssh (via the ~/.ssh symlink)."
echo "The :U mount option will chown it to the container user on next start."
