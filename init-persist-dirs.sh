#!/usr/bin/env bash
# Ensure shared runtime directories exist on the mounted 'persist' volume.
set -euo pipefail

for d in \
  cache/cargo/registry \
  cache/cargo/git \
  cache/pnpm \
  cache/bun \
  cache/sccache \
  worktrees \
  clones
do
  mkdir -p "$HOME/persist/$d"
done
