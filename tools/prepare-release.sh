#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${1:-"$ROOT_DIR/.release"}"

case "$DEST_DIR" in
  ""|"/"|"$ROOT_DIR"|"$ROOT_DIR/" )
    printf 'Refusing unsafe release destination: %s\n' "$DEST_DIR" >&2
    exit 2
    ;;
esac

"$ROOT_DIR/tools/bundle.sh" --check

rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

release_files=(
  sing-box.sh
  docker_init.sh
  Dockerfile
  README.md
  CHANGELOG.md
  LICENSE
  config.conf
  force_version
)

for file in "${release_files[@]}"; do
  cp "$ROOT_DIR/$file" "$DEST_DIR/$file"
done

printf 'Prepared release tree: %s\n' "$DEST_DIR"
