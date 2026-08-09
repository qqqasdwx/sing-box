#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

WORK_DIR="$TEST_DIR/work"
TEMP_DIR="$TEST_DIR/tmp"
CUSTOM_DIR="$WORK_DIR/custom"
STATE_DIR="$WORK_DIR/state"
FIREWALL_STATE_DIR="$WORK_DIR/firewall"
SERVICE_FIREWALL_STATE_FILE="$FIREWALL_STATE_DIR/service_ports.list"
ARGO_DAEMON_FILE="$TEST_DIR/argo.service"
SINGBOX_DAEMON_FILE="$TEST_DIR/sing-box.service"
SYSTEM=Debian
L=E
E=()
C=()
PROTOCOL_LIST=("XTLS + reality" "hysteria2" "tuic" "ShadowTLS" "shadowsocks" "trojan" "vmess + ws" "vless + ws + tls" "H2 + reality" "gRPC + reality" "AnyTLS" "naive" "SOCKS5")
NODE_TAG=("xtls-reality" "hysteria2" "tuic" "ShadowTLS" "shadowsocks" "trojan" "vmess-ws" "vless-ws-tls" "h2-reality" "grpc-reality" "anytls" "naive" "socks5")
DEFAULT_PROTOCOL_CODES=(b c d e f g h i j k l m)
CONSECUTIVE_PORTS=${#PROTOCOL_LIST[@]}
MIN_PORT=100
MAX_PORT=65520
mkdir -p "$WORK_DIR"/{cert,conf,custom,firewall,state,subscribe} "$TEMP_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/20_helpers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/25_subscriptions.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/30_system.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/40_config.sh"

# Load only the subscription exporter; sourcing the complete runtime module also runs its CLI tail.
eval "$(sed -n '/^export_list() {/,/^# 创建快捷方式/{ /^# 创建快捷方式/d; p; }' "$ROOT_DIR/src/vps/50_runtime.sh")"

CHOOSE_PROTOCOLS=a
normalize_install_protocols
[ "${INSTALL_PROTOCOLS[*]}" = "b c d e f g h i j k l m" ]
! array_contains n "${INSTALL_PROTOCOLS[@]}"

CHOOSE_PROTOCOLS=n
normalize_install_protocols
[ "${INSTALL_PROTOCOLS[*]}" = n ]

CHOOSE_PROTOCOLS=''
SOCKS5=true
normalize_install_protocols
[ "${INSTALL_PROTOCOLS[*]}" = n ]

CHOOSE_PROTOCOLS=switch
SOCKS5=true
normalize_install_protocols
[ "${INSTALL_PROTOCOLS[*]}" = n ]

START_PORT=19080
PORT_SOCKS5=''
resolve_protocol_ports
[ "$PORT_SOCKS5" = 19080 ]

unset SOCKS5_USERNAME SOCKS5_PASSWORD
prepare_socks5_credentials
valid_socks5_username "$SOCKS5_USERNAME"
valid_socks5_password "$SOCKS5_PASSWORD"

SOCKS5_USERNAME=test-user
SOCKS5_PASSWORD=test-password-123
NODE_NAME_CONFIRM='Test SOCKS'
NODE_NAME[23]="$NODE_NAME_CONFIRM"
INSTALL_PROTOCOLS=(n)
PORT_SOCKS5=19080
ssl_certificate addons.mozilla.org
TLS_SERVER=addons.mozilla.org
routing_migrate_legacy() { return 0; }
normalize_ws_domain_mode() { return 0; }
sing-box_json change

SOCKS_CONFIG="$WORK_DIR/conf/23_socks5_inbounds.json"
jq -e '
  .inbounds | length == 1 and
  .[0].type == "socks" and
  .[0].listen == "::" and
  .[0].listen_port == 19080 and
  .[0].users == [{"username":"test-user","password":"test-password-123"}]
' "$SOCKS_CONFIG" >/dev/null

cat > "$WORK_DIR/list" << 'EOF'
{"tag":"Test SOCKS socks5",
 "server":"203.0.113.10"}
EOF
STATUS[1]=stopped
IS_SUB=no_sub
IS_ARGO=no_argo
text() { printf 'text-%s' "$1"; }
check_port_hopping_nat() { unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE PORT_HOPPING_TARGET; }
fetch_nodes_value
[ "${NODE_NAME[23]}" = 'Test SOCKS' ]
[ "$PORT_SOCKS5" = 19080 ]
[ "$SOCKS5_USERNAME" = test-user ]
[ "$SOCKS5_PASSWORD" = test-password-123 ]

CONFIG_FILE="$TEST_DIR/config.conf"
cp "$ROOT_DIR/config.conf" "$CONFIG_FILE"
NONINTERACTIVE_INSTALL=noninteractive_install
INSTALL_PROTOCOLS=(n)
SOCKS5=true
START_PORT=19080
LOG_LEVEL=error
SERVER_IP=203.0.113.10
TLS_SERVER=addons.mozilla.org
FINGER_PRINT=chrome
NODE_NAME_CONFIRM='Test SOCKS'
UUID_CONFIRM=11111111-1111-4111-8111-111111111111
write_config_state_file >/dev/null
grep -Fqx "SOCKS5='true'" "$CONFIG_FILE"
grep -Fqx "PORT_SOCKS5='19080'" "$CONFIG_FILE"
grep -Fqx "NODE_NAME_SOCKS5='Test SOCKS'" "$CONFIG_FILE"
grep -Fqx "SOCKS5_USERNAME='test-user'" "$CONFIG_FILE"
grep -Fqx "SOCKS5_PASSWORD='test-password-123'" "$CONFIG_FILE"

ln -s "$(command -v jq)" "$WORK_DIR/jq"
check_install() { return 0; }
warning() { printf '%s' "$*"; }
info() { printf '%s' "$*"; }
hint() { printf '%s' "$*"; }
IS_BRUTAL=false
PORT_NGINX=19999
export_list install >/dev/null

grep -Fq 'type: socks5' "$WORK_DIR/subscribe/proxies"
grep -Fq 'username: "test-user"' "$WORK_DIR/subscribe/proxies"
grep -Fq 'password: "test-password-123"' "$WORK_DIR/subscribe/proxies"
grep -Fq 'udp: true' "$WORK_DIR/subscribe/proxies"
jq -e '
  .outbounds[] |
  select(.tag == "Test SOCKS socks5") |
  .type == "socks" and .version == "5" and
  .server_port == 19080 and
  .username == "test-user" and .password == "test-password-123"
' "$WORK_DIR/subscribe/sing-box" >/dev/null

for UNSUPPORTED in shadowrocket v2rayn throne; do
  if base64 -d "$WORK_DIR/subscribe/$UNSUPPORTED" 2>/dev/null | grep -qi socks; then
    printf 'SOCKS5 was exported to unsupported format: %s\n' "$UNSUPPORTED" >&2
    exit 1
  fi
done

check_firewall_backend() { printf 'none'; }
reload_or_save_firewall_rules() { return 0; }
if ! sync_firewall_rules; then
  printf 'SOCKS5 firewall synchronization failed\n' >&2
  exit 1
fi
grep -Fqx 'tcp 19080' "$SERVICE_FIREWALL_STATE_FILE"
if grep -Fqx 'udp 19080' "$SERVICE_FIREWALL_STATE_FILE"; then
  printf 'SOCKS5 fixed TCP port was incorrectly opened for UDP\n' >&2
  exit 1
fi
grep -Fq '动态 UDP 中继端口' "$ROOT_DIR/README.md"

grep -Fq -- '--SOCKS5' "$ROOT_DIR/src/vps/90_main.sh"
grep -Fq -- '--SOCKS5_USERNAME' "$ROOT_DIR/src/vps/90_main.sh"
grep -Fq 'docker_bool "$SOCKS5"' "$ROOT_DIR/src/docker/80_overrides.sh"

printf 'SOCKS5 tests passed\n'
