#!/usr/bin/env bash
# Make a cheap, self-contained copy of another project on the shared 'persist'
# volume so it is visible (and writable) from every container. Uses btrfs
# reflinks, so the copy — including its .git and node_modules — costs almost no
# disk until you change files. Prints the clone path on stdout.
#
# Unlike a worktree, this is a full independent repo (its own .git/objects), so
# it works in any container. Source may be a path to a git repo, or a project
# name found under /home/node/repos (the read-only host repos mount). Clones
# land in /home/node/persist/clones/<name>.
set -euo pipefail

src="${1:-}"
if [ -z "$src" ]; then
  echo "usage: refclone <project-name|path> [dest-name]" >&2
  exit 1
fi

if git -C "$src" rev-parse --show-toplevel >/dev/null 2>&1; then
  src_path="$(git -C "$src" rev-parse --show-toplevel)"
elif [ -d "/home/node/repos/$src" ]; then
  src_path="/home/node/repos/$src"
else
  echo "refclone: no such project '$src' (looked under /home/node/repos)" >&2
  exit 1
fi

name="${2:-$(basename "$src_path")}"
dest="/home/node/persist/clones/${name}"
if [ -e "$dest" ]; then
  echo "refclone: destination already exists: $dest" >&2
  exit 1
fi

mkdir -p "$(dirname "$dest")"
# Reflink the whole tree (instant, COW). -a preserves symlinks/perms; pnpm's
# store symlinks keep resolving because the store lives on this same volume.
cp -a --reflink=auto "$src_path" "$dest"
echo "$dest"
