#!/usr/bin/env bash
set -euo pipefail

# Back up / restore the Podman volumes that hold your Claude + Codex + Copilot state (auth,
# conversation history, settings, memory) and the shared 'persist' scratch volume
# (which also carries your seeded ~/.ssh) — for moving to another machine.
#
# Volume names are preserved exactly, so compose-namespaced volumes
# (e.g. musi_claude-config) restore to the same name the compose project expects,
# as long as the project's .env (PROJECT_NAME) matches on the new machine.
#
# Usage:
#   ./migrate-volumes.sh list                 # show which volumes match
#   ./migrate-volumes.sh backup  [dest-dir]   # default: ./volume-backup
#   ./migrate-volumes.sh restore [src-dir]    # default: ./volume-backup
#
# Migration flow:
#   (old machine)  ./migrate-volumes.sh backup ~/dc-backup
#                  rsync/scp ~/dc-backup to the new machine
#   (new machine)  ./migrate-volumes.sh restore ~/dc-backup
#                  then ./build.sh && ./devcontainer-rebuild.sh <each project>
#
# NOTE: the backup tars contain your auth tokens and (for 'persist') your
# encrypted SSH key. Treat the backup directory as sensitive.

# Allowlist of what to migrate. PROJECTS are compose project names (namespaced
# by each repo's .env PROJECT_NAME, e.g. musi -> musi_claude-config); add a
# project here as you create one. GLOBALS are exact, unnamespaced volume names.
# Only auth/config/history volumes are carried — not Postgres/Redis or caches.
PROJECTS=(musi matoki)
GLOBALS=(persist)
TYPES='claude-config|codex-config|copilot-config|shell-history|bash-history'

matching_volumes() {
    local proj glob pattern
    proj=$(IFS='|'; echo "${PROJECTS[*]}")
    glob=$(IFS='|'; echo "${GLOBALS[*]}")
    pattern="^(${proj})_(${TYPES})\$|^(${glob})\$"
    podman volume ls --format '{{.Name}}' | grep -E "$pattern" || true
}

cmd="${1:-}"
dir="${2:-./volume-backup}"

case "$cmd" in
  list)
    echo "Volumes that match the backup pattern:"
    matching_volumes | sed 's/^/  /'
    ;;

  backup)
    mkdir -p "$dir"
    vols="$(matching_volumes)"
    if [ -z "$vols" ]; then
        echo "No matching volumes found." >&2
        exit 1
    fi
    printf '%s\n' "$vols" | while read -r v; do
        [ -z "$v" ] && continue
        echo "Exporting $v -> $dir/$v.tar"
        podman volume export "$v" -o "$dir/$v.tar"
    done
    printf '%s\n' "$vols" > "$dir/MANIFEST.txt"
    echo
    echo "Backed up to: $dir"
    echo "Copy it to the new machine, then run: ./migrate-volumes.sh restore '$dir'"
    ;;

  restore)
    if [ ! -d "$dir" ]; then
        echo "ERROR: $dir not found" >&2
        exit 1
    fi
    shopt -s nullglob
    tars=("$dir"/*.tar)
    if [ ${#tars[@]} -eq 0 ]; then
        echo "ERROR: no .tar files in $dir" >&2
        exit 1
    fi
    for tar in "${tars[@]}"; do
        v="$(basename "$tar" .tar)"
        echo "Restoring $v <- $tar"
        podman volume create "$v" >/dev/null 2>&1 || true
        podman volume import "$v" "$tar"
    done
    echo
    echo "Restored ${#tars[@]} volume(s). Now run ./build.sh and rebuild each project."
    ;;

  *)
    echo "Usage: $0 {list|backup|restore} [dir]" >&2
    exit 1
    ;;
esac
