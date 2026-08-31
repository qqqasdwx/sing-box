#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

TEMP_DIR="$TEST_DIR/tmp"
GH_PROXY='https://proxy.example/'
mkdir -p "$TEMP_DIR" "$TEST_DIR/fixture/sing-box-1.14.0-linux-amd64"

cat > "$TEST_DIR/fixture/sing-box-1.14.0-linux-amd64/sing-box" << 'EOF'
#!/usr/bin/env sh
[ "$1" = version ] && printf 'sing-box version 1.14.0\n'
EOF
chmod +x "$TEST_DIR/fixture/sing-box-1.14.0-linux-amd64/sing-box"
tar -czf "$TEST_DIR/good.tar.gz" -C "$TEST_DIR/fixture" sing-box-1.14.0-linux-amd64/sing-box
printf 'not a tar archive\n' > "$TEST_DIR/corrupt.tar.gz"

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/30_system.sh"

WGET_MODE=retry
WGET_COUNT_FILE="$TEST_DIR/wget-count"
WGET_URL_LOG="$TEST_DIR/wget-urls"
printf '0\n' > "$WGET_COUNT_FILE"
: > "$WGET_URL_LOG"

wget() {
  local OUTPUT='' URL='' ARG COUNT
  while [ "$#" -gt 0 ]; do
    ARG=$1
    shift
    case "$ARG" in
      -qO ) OUTPUT=$1; shift ;;
      http://*|https://* ) URL=$ARG ;;
    esac
  done

  COUNT=$(( $(cat "$WGET_COUNT_FILE") + 1 ))
  printf '%s\n' "$COUNT" > "$WGET_COUNT_FILE"
  printf '%s\n' "$URL" >> "$WGET_URL_LOG"
  case "$WGET_MODE" in
    retry )
      [ "$COUNT" -eq 1 ] && cp "$TEST_DIR/corrupt.tar.gz" "$OUTPUT" || cp "$TEST_DIR/good.tar.gz" "$OUTPUT"
      ;;
    corrupt )
      cp "$TEST_DIR/corrupt.tar.gz" "$OUTPUT"
      ;;
    * ) return 1 ;;
  esac
}

sleep() { return 0; }

OUTPUT="$TEMP_DIR/sing-box"
download_sing_box_release_binary 1.14.0 amd64 "$OUTPUT"
[ -x "$OUTPUT" ]
[ "$("$OUTPUT" version)" = 'sing-box version 1.14.0' ]
[ "$(cat "$WGET_COUNT_FILE")" -eq 2 ]
if awk '!/^https:\/\/proxy\.example\/https:\/\/github\.com\/SagerNet\/sing-box\/releases\/download\// { exit 1 }' "$WGET_URL_LOG"; then
  :
else
  printf 'download retry bypassed the configured GH_PROXY\n' >&2
  exit 1
fi
[ ! -e "$TEMP_DIR/sing-box-1.14.0-linux-amd64.tar.gz.download" ]
[ ! -d "$TEMP_DIR/sing-box-1.14.0-linux-amd64" ]

WGET_MODE=corrupt
printf '0\n' > "$WGET_COUNT_FILE"
if download_sing_box_release_binary 1.14.1 amd64 "$TEMP_DIR/invalid"; then
  printf 'corrupt sing-box archive was accepted\n' >&2
  exit 1
fi
[ "$(cat "$WGET_COUNT_FILE")" -eq 3 ]
[ ! -e "$TEMP_DIR/invalid" ]

printf 'sing-box download integrity tests passed\n'
