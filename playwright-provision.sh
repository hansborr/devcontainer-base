#!/usr/bin/env bash
# playwright-provision — install Playwright's browser binaries into the
# (persist-routed) ~/.cache/ms-playwright from the Chrome-for-Testing (CFT)
# public GCS bucket, which is reliably reachable through the devcontainer
# firewall.
#
# Why not just `playwright install`? Two independent reasons, both observed in
# practice:
#   1. Its default download edge (cdn.playwright.dev) is CDN-fronted. Our
#      init-firewall.sh resolves allowlisted domains to IPs ONCE at container
#      start and pins them in an ipset, so the CDN's rotating edge IPs go
#      EHOSTUNREACH mid-session. storage.googleapis.com lives in Google's large,
#      stable ranges (already allowlisted) and stays reachable.
#   2. Even against a reachable mirror, Playwright's own extraction step has been
#      seen to stall at 100%. So we download AND unzip manually here.
# Playwright >= 1.58 is CFT-aligned, so the CFT zip layout matches Playwright's
# cache layout and a straight unzip into the build dir is all that's needed.
#
# Usage:
#   playwright-provision            Provision the browser builds THIS project pins
#   playwright-provision --list     Show installed builds + sizes, and what's needed
#   playwright-provision --prune     Remove installed builds this project doesn't need
#
# Run it from inside a project so `playwright install --dry-run` resolves the
# project-pinned Playwright version (hence the exact browser build number). The
# base image can't do this at build time because it doesn't know a downstream
# project's pinned version — wire this into your project's postCreate / a `just`
# recipe / a doctor check instead.

set -euo pipefail

CFT_BASE="https://storage.googleapis.com/chrome-for-testing-public"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- resolve a Playwright CLI, preferring the project-local pin -----------------
find_playwright() {
  if [ -x ./node_modules/.bin/playwright ]; then
    echo "./node_modules/.bin/playwright"
  elif command -v playwright >/dev/null 2>&1; then
    log "WARN: no project-local Playwright found; using the global 'playwright'."
    log "      The browser build may not match a project's pinned version — run"
    log "      this from inside the project for a version-correct provision."
    echo "playwright"
  else
    log "WARN: no local/global Playwright; falling back to 'npx -y playwright'."
    echo "npx -y playwright"
  fi
}

# --- query the browser builds the resolved Playwright wants ---------------------
# `install --dry-run chromium` prints, per browser, a line like
#   browser: chromium version 145.0.7632.6
# followed by
#   Install location:    /home/node/.cache/ms-playwright/chromium-1208
# We trust that Install location verbatim (it already reflects any
# PLAYWRIGHT_BROWSERS_PATH override and our persist symlink).
#
# Emits one "name|version|dir" line per browser.
parse_targets() {
  printf '%s\n' "$1" | awk '
    /^browser:/        { name=$2; ver=""; for (i=1;i<=NF;i++) if ($i=="version") ver=$(i+1) }
    /Install location/ { print name "|" ver "|" $NF }
  '
}

zip_for() {   # map a Playwright browser name -> CFT zip basename (empty if none)
  case "$1" in
    chromium)                 echo "chrome-linux64.zip" ;;
    chromium-headless-shell)  echo "chrome-headless-shell-linux64.zip" ;;
    *)                        echo "" ;;   # ffmpeg etc. — not in the CFT bucket
  esac
}

provision_one() {
  local name="$1" ver="$2" dir="$3"
  local base; base="$(basename "$dir")"

  if [ -f "$dir/INSTALLATION_COMPLETE" ]; then
    log "✓ $base already installed"
    return 0
  fi

  local zip; zip="$(zip_for "$name")"
  if [ -z "$zip" ]; then
    log "• skipping $name ($base) — not provided by the CFT bucket"
    log "  (e.g. ffmpeg; Playwright video recording will be unavailable)"
    return 0
  fi
  [ -n "$ver" ] || die "could not determine version for $name"

  local url="$CFT_BASE/$ver/linux64/$zip"
  local tmp; tmp="$(mktemp)"
  log "↓ $base  ←  $url"
  if ! curl -fSL --retry 3 -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "download failed: $url"
  fi

  mkdir -p "$dir"
  if ! unzip -q -o "$tmp" -d "$dir"; then
    rm -f "$tmp"
    die "unzip failed for $base"
  fi
  rm -f "$tmp"

  # Make the browser binaries executable.
  find "$dir" -type f \
    \( -name chrome -o -name chrome-headless-shell -o -name chrome_crashpad_handler \) \
    -exec chmod +x {} + 2>/dev/null || true

  # Fail loud if the layout ever drifts: some runnable chrome binary must exist.
  if ! find "$dir" -type f \( -name chrome -o -name chrome-headless-shell \) | grep -q .; then
    die "no chrome binary under $dir after unzip — CFT zip layout may have changed"
  fi

  # Markers Playwright checks to consider the build present + validated.
  touch "$dir/INSTALLATION_COMPLETE" "$dir/DEPENDENCIES_VALIDATED"
  log "✓ provisioned $base ($ver)"
}

# --- derive the cache root (parent of the build dirs) --------------------------
cache_root_from() {   # $1 = targets text; fall back to the default cache path
  local first
  first="$(printf '%s\n' "$1" | awk -F'|' 'NF>=3 {print $3; exit}')"
  if [ -n "$first" ]; then
    dirname "$first"
  else
    echo "${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
  fi
}

# --- subcommands ---------------------------------------------------------------
cmd_provision() {
  local targets="$1"

  # The cache root (~/.cache/ms-playwright) is a symlink onto the persist volume.
  # If this shell didn't run init-persist-dirs.sh the symlink still dangles, so
  # create its resolved target before mkdir -p tries to descend through it.
  local root; root="$(cache_root_from "$targets")"
  mkdir -p "$(readlink -f "$root" 2>/dev/null || echo "$root")" 2>/dev/null || true

  local any=0
  while IFS='|' read -r name ver dir; do
    [ -n "$dir" ] || continue
    any=1
    provision_one "$name" "$ver" "$dir"
  done <<< "$targets"
  [ "$any" = 1 ] || die "no browser builds parsed from 'playwright install --dry-run'"
  log "Done. Browsers live on the persist volume and survive container rebuilds."
}

cmd_list() {
  local targets="$1" root; root="$(cache_root_from "$targets")"
  local needed; needed="$(printf '%s\n' "$targets" | awk -F'|' 'NF>=3 {print $3}' | xargs -r -n1 basename | sort -u)"

  log "Playwright browser cache: $root"
  if [ -d "$root" ]; then
    local d base mark
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      base="$(basename "$d")"
      mark="  "; grep -qxF "$base" <<< "$needed" && mark="✓ "
      log "  ${mark}$(du -sh "$d" 2>/dev/null | cut -f1)	$base"
    done
  else
    log "  (nothing installed yet)"
  fi
  log ""
  log "Needed by this project: ${needed:-<none parsed>}"
  log "Rows without ✓ are unused by THIS project (another project may still need"
  log "them — the persist volume is shared). Use --prune to remove them."
}

cmd_prune() {
  local targets="$1" root; root="$(cache_root_from "$targets")"
  local needed; needed="$(printf '%s\n' "$targets" | awk -F'|' 'NF>=3 {print $3}' | xargs -r -n1 basename | sort -u)"
  [ -d "$root" ] || { log "Nothing to prune ($root does not exist)."; return 0; }

  log "NOTE: the persist volume is shared across projects — pruning removes builds"
  log "      that THIS project doesn't pin; another project may have to re-provision."
  local d base removed=0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    if grep -qxF "$base" <<< "$needed"; then
      log "  keep   $base"
    else
      log "  remove $base"
      rm -rf "$d"
      removed=1
    fi
  done
  [ "$removed" = 1 ] || log "Nothing to prune — all installed builds are needed."
}

# --- main ----------------------------------------------------------------------
main() {
  local action="provision"
  case "${1:-}" in
    ""|provision) action="provision" ;;
    --list|list)  action="list" ;;
    --prune|prune) action="prune" ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# \{0,1\}//'
      return 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac

  local pw dry targets
  pw="$(find_playwright)"
  if ! dry="$($pw install --dry-run chromium 2>/dev/null)"; then
    die "'$pw install --dry-run chromium' failed — is Playwright installed?"
  fi
  targets="$(parse_targets "$dry")"
  if [ -z "$targets" ]; then
    log "Could not parse browsers from 'playwright install --dry-run'. Raw output:"
    printf '%s\n' "$dry" >&2
    die "unrecognized --dry-run format"
  fi

  case "$action" in
    provision) cmd_provision "$targets" ;;
    list)      cmd_list "$targets" ;;
    prune)     cmd_prune "$targets" ;;
  esac
}

main "$@"
