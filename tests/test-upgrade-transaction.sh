#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

WORK_DIR="$TEST_DIR/work"
CUSTOM_DIR="$WORK_DIR/custom"
STATE_DIR="$WORK_DIR/state"
TEMP_DIR="$TEST_DIR/tmp"
LOG_LEVEL_DEFAULT=error
SYSTEM=Debian
mkdir -p "$WORK_DIR/conf" "$CUSTOM_DIR" "$STATE_DIR" "$TEMP_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/20_helpers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/40_config.sh"

cat > "$CUSTOM_DIR/04_outbounds.json" << 'EOF'
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "direct", "tag": "custom-v6"}
  ]
}
EOF
cat > "$CUSTOM_DIR/03_route.json" << 'EOF'
{
  "route": {
    "rules": [
      {"action": "route", "outbound": "custom-v6"}
    ]
  }
}
EOF

cat > "$WORK_DIR/conf/00_log.json" << 'EOF'
{"log":{"disabled":false,"level":"debug","output":"/tmp/old.log","timestamp":true,"legacy":true}}
EOF
cat > "$WORK_DIR/conf/04_experimental.json" << 'EOF'
{"experimental":{"legacy":true}}
EOF
cat > "$WORK_DIR/conf/05_dns.json" << 'EOF'
{"dns":{"servers":[{"type":"local","prefer_go":false}],"strategy":"prefer_ipv6","legacy":true}}
EOF
cat > "$WORK_DIR/conf/06_ntp.json" << 'EOF'
{"ntp":{"enabled":true}}
EOF
cat > "$WORK_DIR/conf/07_http_clients.json" << 'EOF'
{"http_clients":[],"legacy":true}
EOF
cat > "$WORK_DIR/conf/11_fixture_inbounds.json" << 'EOF'
{"inbounds":[]}
EOF
cat > "$WORK_DIR/conf/03_routing.json" << 'EOF'
{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]},"fixture":"old-runtime-route"}
EOF

CUSTOM_ROUTE_HASH=$(sha256sum "$CUSTOM_DIR/03_route.json")
CUSTOM_OUTBOUNDS_HASH=$(sha256sum "$CUSTOM_DIR/04_outbounds.json")
NEW_BINARY="$TEST_DIR/new-sing-box"
cat > "$NEW_BINARY" << 'EOF'
#!/usr/bin/env bash
# NEW_BINARY
set -e
[ "$1" = check ]
[ "$2" = -C ]
CONF_DIR=$3
jq -e '.log.level == "debug" and (.log.legacy | not)' "$CONF_DIR/00_log.json" >/dev/null
jq -e '.dns.strategy == "prefer_ipv6" and .dns.servers[0].prefer_go == false and (.dns.legacy | not)' "$CONF_DIR/05_dns.json" >/dev/null
jq -e '.inbounds == [] and keys == ["inbounds"]' "$CONF_DIR/11_fixture_inbounds.json" >/dev/null
jq -e 'any(.outbounds[]; .tag == "custom-v6") and .route.rules[0].outbound == "custom-v6"' "$CONF_DIR/03_routing.json" >/dev/null
[ ! -e "$CONF_DIR/06_ntp.json" ]
EOF
chmod +x "$NEW_BINARY"

if "$NEW_BINARY" check -C "$WORK_DIR/conf"; then
  printf 'incompatible current configuration unexpectedly passed the new binary check\n' >&2
  exit 1
fi

CANDIDATE_DIR="$TEST_DIR/candidate"
mkdir -p "$CANDIDATE_DIR"
upgrade_prepare_config_candidate "$CANDIDATE_DIR" "$NEW_BINARY"
[ -z "${REAL_SING_BOX:-}" ] || routing_validate_candidate "$CANDIDATE_DIR" "$REAL_SING_BOX"

jq -e '.log.level == "debug" and (.log.legacy | not)' "$CANDIDATE_DIR/00_log.json" >/dev/null
jq -e '.dns.strategy == "prefer_ipv6" and .dns.servers[0].prefer_go == false' "$CANDIDATE_DIR/05_dns.json" >/dev/null
jq -e '.inbounds == [] and keys == ["inbounds"]' "$CANDIDATE_DIR/11_fixture_inbounds.json" >/dev/null
jq -e 'any(.outbounds[]; .tag == "custom-v6") and .route.rules[0].outbound == "custom-v6"' "$CANDIDATE_DIR/03_routing.json" >/dev/null
[ ! -e "$CANDIDATE_DIR/06_ntp.json" ]
jq -e '.log.legacy == true' "$WORK_DIR/conf/00_log.json" >/dev/null
[ -e "$WORK_DIR/conf/06_ntp.json" ]
[ "$(sha256sum "$CUSTOM_DIR/03_route.json")" = "$CUSTOM_ROUTE_HASH" ]
[ "$(sha256sum "$CUSTOM_DIR/04_outbounds.json")" = "$CUSTOM_OUTBOUNDS_HASH" ]

SERVICE_MODE=success
SERVICE_LOG="$TEST_DIR/service.log"
cmd_systemctl() {
  local ACTION=$1
  printf '%s %s\n' "$ACTION" "${2:-}" >> "$SERVICE_LOG"
  case "$ACTION" in
    disable ) return 0 ;;
    enable|status )
      if grep -q 'NEW_BINARY' "$WORK_DIR/sing-box"; then
        [ "$SERVICE_MODE" != fail_new ]
      else
        [ "$SERVICE_MODE" != fail_restore ]
      fi
      ;;
  esac
}
service_failure_detail() {
  printf 'simulated new service failure'
}
sleep() {
  return 0
}

cat > "$WORK_DIR/sing-box" << 'EOF'
#!/bin/sh
# OLD_BINARY
EOF
chmod +x "$WORK_DIR/sing-box"
upgrade_install_transaction "$NEW_BINARY" "$CANDIDATE_DIR"
grep -q 'NEW_BINARY' "$WORK_DIR/sing-box"
jq -e '.log.level == "debug" and (.log.legacy | not)' "$WORK_DIR/conf/00_log.json" >/dev/null
if find "$WORK_DIR" -maxdepth 1 -name '*.upgrade.*' -print -quit | grep -q .; then
  printf 'successful upgrade left transaction artifacts behind\n' >&2
  exit 1
fi

rm -rf "$WORK_DIR/conf"
mkdir -p "$WORK_DIR/conf"
cat > "$WORK_DIR/conf/marker.json" << 'EOF'
{"fixture":"original-complete-config"}
EOF
cat > "$WORK_DIR/sing-box" << 'EOF'
#!/bin/sh
# OLD_BINARY
EOF
chmod +x "$WORK_DIR/sing-box"
ROLLBACK_CANDIDATE="$TEST_DIR/rollback-candidate"
mkdir -p "$ROLLBACK_CANDIDATE"
cat > "$ROLLBACK_CANDIDATE/marker.json" << 'EOF'
{"fixture":"candidate-config"}
EOF
ROLLBACK_BINARY="$TEST_DIR/rollback-sing-box"
cat > "$ROLLBACK_BINARY" << 'EOF'
#!/bin/sh
# NEW_BINARY
EOF
chmod +x "$ROLLBACK_BINARY"

ORIGINAL_CONFIG_HASH=$(sha256sum "$WORK_DIR/conf/marker.json")
SERVICE_MODE=fail_new
set +e
upgrade_install_transaction "$ROLLBACK_BINARY" "$ROLLBACK_CANDIDATE"
UPGRADE_RC=$?
set -e
[ "$UPGRADE_RC" -eq 2 ]
grep -q 'OLD_BINARY' "$WORK_DIR/sing-box"
[ "$(sha256sum "$WORK_DIR/conf/marker.json")" = "$ORIGINAL_CONFIG_HASH" ]
[ ! -e "$WORK_DIR/conf/06_ntp.json" ]
[ "$UPGRADE_FAILURE_DETAIL" = 'simulated new service failure' ]
if find "$WORK_DIR" -maxdepth 1 -name '*.upgrade.*' -print -quit | grep -q .; then
  printf 'rolled-back upgrade left transaction artifacts behind\n' >&2
  exit 1
fi

printf 'upgrade compatibility and transaction tests passed\n'
