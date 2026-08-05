#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

WORK_DIR="$TEST_DIR/work"
TEMP_DIR="$TEST_DIR/tmp"
SINGBOX_DAEMON_FILE="$TEST_DIR/sing-box.service"
NGINX_CALL_LOG="$TEST_DIR/nginx-calls"
NGINX_SIGNAL_LOG="$TEST_DIR/nginx-signals"
NGINX_TEST_FAIL="$TEST_DIR/nginx-test-fail"
SYSTEM=Debian
IS_CENTOS=''
L=E
PORT_NGINX=8899
mkdir -p "$WORK_DIR/conf" "$TEMP_DIR" "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/nginx" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NGINX_CALL_LOG"
if [ "${1:-}" = -t ] && [ -e "$NGINX_TEST_FAIL" ]; then
  printf 'invalid nginx configuration\n' >&2
  exit 1
fi
EOF
chmod +x "$TEST_DIR/bin/nginx"
export PATH="$TEST_DIR/bin:$PATH" NGINX_CALL_LOG NGINX_TEST_FAIL

error() {
  printf '%s\n' "$*" >&2
  return 1
}

systemctl() {
  [ "$1" = daemon-reload ]
}

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/20_helpers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/30_system.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/40_config.sh"

NGINX_RUNNING=false
nginx_project_pid() {
  [ "$NGINX_RUNNING" = true ] && printf '4242\n'
}

kill() {
  case "$1" in
    -0 ) [ "$NGINX_RUNNING" = true ] ;;
    -QUIT|-TERM|-KILL )
      printf '%s %s\n' "$1" "$2" >> "$NGINX_SIGNAL_LOG"
      NGINX_RUNNING=false
      ;;
    * ) return 1 ;;
  esac
}

sleep() {
  return 0
}

printf 'events {}\n' > "$WORK_DIR/nginx.conf"
: > "$NGINX_CALL_LOG"
nginx_sync
grep -Fqx -- "-t -c $WORK_DIR/nginx.conf" "$NGINX_CALL_LOG"
grep -Fqx -- "-c $WORK_DIR/nginx.conf" "$NGINX_CALL_LOG"

NGINX_RUNNING=true
: > "$NGINX_CALL_LOG"
nginx_sync
grep -Fqx -- "-t -c $WORK_DIR/nginx.conf" "$NGINX_CALL_LOG"
grep -Fqx -- "-s reload -c $WORK_DIR/nginx.conf" "$NGINX_CALL_LOG"

NGINX_RUNNING=false
touch "$NGINX_TEST_FAIL"
: > "$NGINX_CALL_LOG"
if nginx_sync; then
  printf 'nginx sync unexpectedly accepted an invalid configuration\n' >&2
  exit 1
fi
[ "$(wc -l < "$NGINX_CALL_LOG")" -eq 1 ]
rm -f "$NGINX_TEST_FAIL"

NGINX_RUNNING=true
rm -f "$WORK_DIR/nginx.conf"
: > "$NGINX_SIGNAL_LOG"
nginx_sync
grep -Fqx -- '-QUIT 4242' "$NGINX_SIGNAL_LOG"
[ "$NGINX_RUNNING" = false ]

for ARGO_TYPE in is_token_argo is_json_argo Token Json; do
  argo_is_fixed_tunnel
done
for ARGO_TYPE in is_quicktunnel_argo Try ''; do
  if argo_is_fixed_tunnel; then
    printf 'non-fixed Argo type was treated as fixed: %s\n' "$ARGO_TYPE" >&2
    exit 1
  fi
done

printf 'events {}\n' > "$WORK_DIR/nginx.conf"
SYSTEM=Debian
IS_CENTOS=CentOS7
PORT_NGINX=8899
SINGBOX_DAEMON_FILE="$TEST_DIR/sing-box-systemd.service"
sing-box_systemd
grep -Fqx "ExecStartPre=-$TEST_DIR/bin/nginx -c $WORK_DIR/nginx.conf" "$SINGBOX_DAEMON_FILE"

SYSTEM=Alpine
SINGBOX_DAEMON_FILE="$TEST_DIR/sing-box-openrc"
sing-box_systemd
grep -Fqx "    $TEST_DIR/bin/nginx -c $WORK_DIR/nginx.conf || true" "$SINGBOX_DAEMON_FILE"

PORT_NGINX=''
sing-box_systemd
if grep -Fq "$WORK_DIR/nginx.conf" "$SINGBOX_DAEMON_FILE"; then
  printf 'OpenRC service retained stale nginx startup configuration\n' >&2
  exit 1
fi

printf 'nginx lifecycle tests passed\n'
