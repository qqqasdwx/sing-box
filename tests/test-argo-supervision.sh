#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SYSTEM=Alpine
WORK_DIR="$TEST_DIR/work"
TEMP_DIR="$TEST_DIR/tmp"
ARGO_DAEMON_FILE="$TEST_DIR/argo"
L=E
mkdir -p "$WORK_DIR/logs" "$TEMP_DIR"

warning() { printf '%s\n' "$*" >/dev/null; }
info() { printf '%s\n' "$*" >/dev/null; }

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/40_config.sh"

assert_supervised_service() {
  grep -Fqx 'command="'"$WORK_DIR"'/cloudflared"' "$ARGO_DAEMON_FILE"
  grep -Fqx 'supervisor="supervise-daemon"' "$ARGO_DAEMON_FILE"
  grep -Fqx 'respawn_delay=5' "$ARGO_DAEMON_FILE"
  grep -Fqx 'respawn_max=10' "$ARGO_DAEMON_FILE"
  grep -Fqx 'respawn_period=60' "$ARGO_DAEMON_FILE"
  if grep -Fq 'command_background=' "$ARGO_DAEMON_FILE"; then
    printf 'generated service still backgrounds cloudflared without supervision\n' >&2
    return 1
  fi
  if grep -Fq 'command="'"$WORK_DIR"'/cloudflared tunnel"' "$ARGO_DAEMON_FILE"; then
    printf 'generated service includes the tunnel subcommand in command\n' >&2
    return 1
  fi
}

TOKEN='test-token-value'
ARGO_RUNS="$WORK_DIR/cloudflared tunnel --edge-ip-version auto run --token $TOKEN"
argo_systemd
assert_supervised_service
grep -Fqx "command_args=\"tunnel --edge-ip-version auto run --token $TOKEN\"" "$ARGO_DAEMON_FILE"

ARGO_RUNS="$WORK_DIR/cloudflared tunnel --edge-ip-version auto --config $WORK_DIR/tunnel.yml run"
argo_systemd
assert_supervised_service
grep -Fqx "command_args=\"tunnel --edge-ip-version auto --config $WORK_DIR/tunnel.yml run\"" "$ARGO_DAEMON_FILE"

ARGO_RUNS="$WORK_DIR/cloudflared tunnel --edge-ip-version auto --no-autoupdate --url http://localhost:8899"
argo_systemd
assert_supervised_service
grep -Fqx 'command_args="tunnel --edge-ip-version auto --no-autoupdate --url http://localhost:8899"' "$ARGO_DAEMON_FILE"

RC_RUNNING=false
RC_START_CALLS=0
RC_FAIL_FIRST_START=false
RC_ACTION_LOG="$TEST_DIR/rc-actions"
rc-service() {
  local SERVICE=$1 ACTION=$2
  [ "$SERVICE" = argo ]
  printf '%s\n' "$ACTION" >> "$RC_ACTION_LOG"
  case "$ACTION" in
    status ) [ "$RC_RUNNING" = true ] ;;
    stop ) RC_RUNNING=false ;;
    start )
      RC_START_CALLS=$((RC_START_CALLS + 1))
      if [ "$RC_FAIL_FIRST_START" = true ] && [ "$RC_START_CALLS" -eq 1 ]; then
        return 1
      fi
      RC_RUNNING=true
      ;;
    * ) return 1 ;;
  esac
}

write_legacy_service() {
  local ARGS=$1
  cat > "$ARGO_DAEMON_FILE" << EOF
#!/sbin/openrc-run
command="$WORK_DIR/cloudflared tunnel"
command_args="$ARGS"
pidfile="/var/run/\${RC_SVCNAME}.pid"
command_background="yes"
EOF
  chmod 755 "$ARGO_DAEMON_FILE"
}

# A stopped legacy service is migrated without starting it.
write_legacy_service "--edge-ip-version auto run --token $TOKEN"
RC_RUNNING=false
: > "$RC_ACTION_LOG"
migrate_argo_openrc_supervision
assert_supervised_service
grep -Fqx "command_args=\"tunnel --edge-ip-version auto run --token $TOKEN\"" "$ARGO_DAEMON_FILE"
[ "$RC_RUNNING" = false ]
[ "$(cat "$RC_ACTION_LOG")" = status ]

# A running Quick Tunnel is not rewritten or restarted because that changes its hostname.
write_legacy_service '--edge-ip-version auto --no-autoupdate --url http://localhost:8899'
cp "$ARGO_DAEMON_FILE" "$TEST_DIR/quick-before"
RC_RUNNING=true
: > "$RC_ACTION_LOG"
migrate_argo_openrc_supervision
cmp -s "$TEST_DIR/quick-before" "$ARGO_DAEMON_FILE"
[ "$(cat "$RC_ACTION_LOG")" = status ]

# If the supervised service cannot start, the exact legacy file and service are restored.
write_legacy_service "--edge-ip-version auto --config $WORK_DIR/tunnel.yml run"
cp "$ARGO_DAEMON_FILE" "$TEST_DIR/legacy-before"
RC_RUNNING=true
RC_START_CALLS=0
RC_FAIL_FIRST_START=true
: > "$RC_ACTION_LOG"
if migrate_argo_openrc_supervision; then
  printf 'migration unexpectedly succeeded after the supervised service failed to start\n' >&2
  exit 1
fi
cmp -s "$TEST_DIR/legacy-before" "$ARGO_DAEMON_FILE"
[ "$RC_START_CALLS" -eq 2 ]
[ "$RC_RUNNING" = true ]

printf 'Argo supervision tests passed\n'
