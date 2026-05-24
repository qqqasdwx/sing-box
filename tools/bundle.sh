#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=false
TARGET=all

usage() {
  printf 'Usage: %s [--check] [all|vps|docker]\n' "${0##*/}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check )
      CHECK=true
      ;;
    all|vps|docker )
      TARGET="$1"
      ;;
    -h|--help )
      usage
      exit 0
      ;;
    * )
      usage >&2
      exit 2
      ;;
  esac
  shift
done

bundle_file() {
  local output="$1"
  shift

  local tmp
  tmp="$(mktemp)"

  local input
  for input in "$@"; do
    if [ ! -f "$input" ]; then
      rm -f "$tmp"
      printf 'Missing bundle input: %s\n' "$input" >&2
      exit 1
    fi
    cat "$input" >> "$tmp"
  done

  # Preserve the historical root artifacts, which currently have no trailing LF.
  if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l)" -gt 0 ]; then
    truncate -s -1 "$tmp"
  fi

  if [ "$CHECK" = true ]; then
    if ! cmp -s "$tmp" "$output"; then
      printf 'Generated file is stale: %s\n' "${output#$ROOT_DIR/}" >&2
      printf 'Run tools/bundle.sh and commit the updated file.\n' >&2
      rm -f "$tmp"
      exit 1
    fi
    rm -f "$tmp"
  else
    mv "$tmp" "$output"
  fi
}

bundle_vps() {
  bundle_file "$ROOT_DIR/sing-box.sh" \
    "$ROOT_DIR/src/vps/00_prelude.sh" \
    "$ROOT_DIR/src/vps/10_i18n.sh" \
    "$ROOT_DIR/src/vps/20_helpers.sh" \
    "$ROOT_DIR/src/vps/30_system.sh" \
    "$ROOT_DIR/src/vps/40_config.sh" \
    "$ROOT_DIR/src/vps/50_runtime.sh" \
    "$ROOT_DIR/src/vps/90_main.sh"
}

bundle_docker() {
  bundle_file "$ROOT_DIR/docker_init.sh" \
    "$ROOT_DIR/src/docker/00_prelude.sh" \
    "$ROOT_DIR/src/vps/10_i18n.sh" \
    "$ROOT_DIR/src/vps/20_helpers.sh" \
    "$ROOT_DIR/src/vps/30_system.sh" \
    "$ROOT_DIR/src/vps/40_config.sh" \
    "$ROOT_DIR/src/vps/50_runtime.sh" \
    "$ROOT_DIR/src/docker/80_overrides.sh" \
    "$ROOT_DIR/src/docker/90_main.sh"
}

case "$TARGET" in
  all )
    bundle_vps
    bundle_docker
    ;;
  vps )
    bundle_vps
    ;;
  docker )
    bundle_docker
    ;;
esac
