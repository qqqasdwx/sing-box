#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SYSTEM=Debian
IS_CENTOS=''
WORK_DIR="$TEST_DIR/work"
TEMP_DIR="$TEST_DIR/tmp"
MOCK_PID_FILE="$TEST_DIR/main.pid"
MOCK_SIGNAL_FILE="$TEST_DIR/signal"
MOCK_ROUTING_FILE="$TEST_DIR/routing"
MOCK_ROUTING_FAIL="$TEST_DIR/routing-fail"
MOCK_CHANGE_PID="$TEST_DIR/change-pid"
mkdir -p "$WORK_DIR" "$TEMP_DIR"

service_command_log_file() {
  printf '%s/service-%s-%s.log\n' "$TEMP_DIR" "$1" "$2"
}

routing_publish() {
  printf 'called\n' >> "$MOCK_ROUTING_FILE"
  [ ! -e "$MOCK_ROUTING_FAIL" ]
}

systemctl() {
  case "$1" in
    daemon-reload )
      return 0
      ;;
    show )
      cat "$MOCK_PID_FILE"
      ;;
    kill )
      printf '%s\n' "$*" >> "$MOCK_SIGNAL_FILE"
      [ ! -e "$MOCK_CHANGE_PID" ] || printf '4243\n' > "$MOCK_PID_FILE"
      ;;
    is-active )
      printf 'active\n'
      ;;
    * )
      printf 'unexpected systemctl call: %s\n' "$*" >&2
      return 1
      ;;
  esac
}

sleep() {
  return 0
}

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/30_system.sh"

printf '4242\n' > "$MOCK_PID_FILE"
cmd_systemctl reload sing-box
grep -qx 'called' "$MOCK_ROUTING_FILE"
grep -qx 'kill --kill-who=main --signal=HUP sing-box' "$MOCK_SIGNAL_FILE"

rm -f "$MOCK_SIGNAL_FILE"
touch "$MOCK_ROUTING_FAIL"
if cmd_systemctl reload sing-box; then
  printf 'reload unexpectedly succeeded after configuration validation failed\n' >&2
  exit 1
fi
[ ! -e "$MOCK_SIGNAL_FILE" ] || {
  printf 'HUP was sent after configuration validation failed\n' >&2
  exit 1
}

rm -f "$MOCK_ROUTING_FAIL"
touch "$MOCK_CHANGE_PID"
printf '4242\n' > "$MOCK_PID_FILE"
if cmd_systemctl reload sing-box; then
  printf 'reload unexpectedly succeeded after the main PID changed\n' >&2
  exit 1
fi

printf 'safe reload tests passed\n'
