#!/usr/bin/env bash
# shellcheck disable=SC2154  # the target arrays are assigned via nameref in collect()
# The actual lint pass over this repo. Runs anywhere shellcheck/hadolint/
# yamllint exist: inside the base image (via ./lint.sh on the host) or
# directly on the Forgejo CI runner (.forgejo/workflows/lint.yml — the runner
# image is built FROM the base image, so the linters are already there).
set -euo pipefail
cd "$(dirname "$0")"
shopt -s globstar nullglob dotglob

# Glob with dotglob (to reach .devcontainer*/), then drop .git internals.
collect() {
    local -n out=$1
    shift
    out=()
    local f
    for f in "$@"; do
        [[ "$f" == .git/* ]] && continue
        out+=("$f")
    done
}

collect shell_scripts ./**/*.sh
collect dockerfiles ./**/Dockerfile
collect yaml_files ./**/*.yml ./**/*.yaml

echo "shellcheck (${#shell_scripts[@]} scripts)..."
shellcheck -S warning "${shell_scripts[@]}"

echo "hadolint (${#dockerfiles[@]} Dockerfiles)..."
hadolint "${dockerfiles[@]}"

echo "yamllint (${#yaml_files[@]} files)..."
yamllint "${yaml_files[@]}"   # config: ./.yamllint

echo "All lint checks passed."
