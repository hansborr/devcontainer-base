#!/usr/bin/env bash
# Create a git worktree for the current repo under the shared 'persist' volume,
# reflink-cloning heavy build dirs (node_modules/target/...) so it costs almost
# no disk on btrfs. Prints the worktree path on stdout (so the `wt` zsh function
# can cd into it); all git chatter goes to stderr.
#
# Worktrees live at /home/node/persist/worktrees/<project>/<branch>.
#
# NOTE: a linked worktree's git metadata points back to THIS container's
# /workspace, so it is only usable from the container that created it. For a
# checkout you can open from another container, use `refclone` instead.
set -euo pipefail

branch="${1:-}"
base="${2:-HEAD}"
if [ -z "$branch" ]; then
  echo "usage: wt <branch> [base-ref]" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "wt: not inside a git repository" >&2
  exit 1
}
project="$(basename "$repo_root")"
branch_slug="$(printf '%s' "$branch" | tr -c '[:alnum:]._-' '_' | cut -c1-80)"
branch_hash="$(printf '%s' "$branch" | sha256sum | cut -c1-8)"
dest="/home/node/persist/worktrees/${project}/${branch_slug}-${branch_hash}"

if [ -e "$dest" ]; then
  echo "wt: worktree already exists: $dest" >&2
  echo "$dest"
  exit 0
fi

mkdir -p "$(dirname "$dest")"

if git -C "$repo_root" show-ref --verify --quiet "refs/heads/${branch}"; then
  git -C "$repo_root" worktree add "$dest" "$branch" >&2
else
  git -C "$repo_root" worktree add -b "$branch" "$dest" "$base" >&2
fi

# Reflink-clone build dirs that exist in the main checkout (instant + COW on
# btrfs; near-zero disk until files diverge). Skips anything already present.
for d in node_modules target .next dist build .turbo; do
  if [ -e "$repo_root/$d" ] && [ ! -e "$dest/$d" ]; then
    cp -a --reflink=auto "$repo_root/$d" "$dest/$d" 2>/dev/null \
      || echo "wt: warning: failed to reflink-copy $d into the worktree" >&2
  fi
done

echo "$dest"
