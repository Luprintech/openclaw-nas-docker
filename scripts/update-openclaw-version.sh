#!/usr/bin/env bash
#
# Check the official GHCR OpenClaw image tags and update local version pins.
#
# This script intentionally does NOT build or restart containers. It only edits:
#   - .last-openclaw-version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAST_FILE="$PROJECT_DIR/.last-openclaw-version"

GITHUB_REPOSITORY="openclaw/openclaw"
DRY_RUN=false

usage() {
  cat <<'USAGE'
Usage: scripts/update-openclaw-version.sh [--dry-run]

Fetches official OpenClaw image tags from GHCR, picks the newest stable
date-based Docker tag, and updates .last-openclaw-version.

It does not run docker compose build/up/pull.
USAGE
}

error() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        ;;
    esac
  done
}

read_current_version() {
  if [[ -f "$LAST_FILE" ]]; then
    tr -d '[:space:]' < "$LAST_FILE"
  else
    printf ''
  fi
}

fetch_latest_version() {
  local tag

  tag="$(
    curl -fsSL --max-time 15 \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/latest" |
      jq -r '.tag_name // empty'
  )"
  [[ -n "$tag" ]] || error "Could not fetch latest release from GitHub (check network connectivity)."

  # Strip leading 'v' if present (e.g. v2026.5.28 -> 2026.5.28)
  printf '%s\n' "${tag#v}"
}

apply_version() {
  local version="$1"
  printf '%s\n' "$version" > "$LAST_FILE"
}

main() {
  parse_args "$@"
  need_command curl
  need_command jq

  local current latest
  current="$(read_current_version)"
  latest="$(fetch_latest_version)"
  [[ -n "$latest" ]] || error "Could not determine latest stable OpenClaw version."

  printf 'Current OpenClaw version: %s\n' "${current:-unknown}"
  printf 'Latest OpenClaw version:  %s\n' "$latest"

  if [[ "$current" == "$latest" ]]; then
    printf 'Already up to date.\n'
    exit 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    printf 'Dry run: would update local pins to %s\n' "$latest"
    exit 0
  fi

  apply_version "$latest"

  printf '\nUpdated .last-openclaw-version to %s.\n' "$latest"
  printf 'Next manual deploy steps on the NAS, when you choose:\n'
  printf '  docker compose pull\n'
  printf '  docker compose up -d\n'
}

main "$@"
