#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
cleanup() {
  local _status=$?
  rm -rf "$TEST_DIR"
  exit "$_status"
}
trap cleanup EXIT

source "$ROOT_DIR/src/vps/25_subscriptions.sh"

write_clash_provider_config \
  "$TEST_DIR/clash" \
  'Test Node' \
  'https://example.com/subscription/proxies' \
  jq

write_clash_inline_config \
  "$TEST_DIR/clash2" \
  $'proxies:\n  - {name: "Test Node", type: socks5, server: 127.0.0.1, port: 1080}' \
  jq \
  'Test Node'

write_sing_box_client_config \
  "$TEST_DIR/sing-box.json" \
  '{"type":"socks","tag":"Test Node","server":"127.0.0.1","server_port":1080},' \
  '"Test Node",' \
  jq

grep -Fq 'https://example.com/subscription/proxies' "$TEST_DIR/clash"
grep -Fq 'MATCH,Test Node' "$TEST_DIR/clash"
grep -Fq 'name: PROXY' "$TEST_DIR/clash2"
grep -Fq '"Test Node"' "$TEST_DIR/clash2"
jq -e '
  .inbounds[0].type == "tun" and
  .inbounds[1].type == "mixed" and
  .outbounds[0].tag == "Test Node" and
  .outbounds[1].type == "selector" and
  .outbounds[2].type == "urltest" and
  .route.final == "proxy"
' "$TEST_DIR/sing-box.json" >/dev/null

E=()
C=()
L=C
TEMP_DIR="$TEST_DIR"
WORK_DIR="$TEST_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/20_helpers.sh"

wget() {
  printf 'Reality key conversion attempted a network request\n' >&2
  return 1
}

PUBLIC_KEY=$(reality_public_from_private 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]]

GH_PROXY='https://proxy.example'
check_cdn
[ "$GH_PROXY" = 'https://proxy.example/' ]

printf '%s\n' 'map $http_user_agent $path1 {' > "$WORK_DIR/nginx.conf"
installed_subscription_enabled

LEGACY_CONFIG="$TEST_DIR/legacy-config.conf"
printf '%s\n' \
  "NTP_ENABLED='true'" \
  "NTP_SERVER='time.apple.com'" \
  "NTP_SERVER_PORT='123'" \
  "NTP_INTERVAL='60m'" > "$LEGACY_CONFIG"
for LEGACY_NTP_VAR in NTP_ENABLED NTP_SERVER NTP_SERVER_PORT NTP_INTERVAL; do
  config_state_comment_line "$LEGACY_CONFIG" "$LEGACY_NTP_VAR"
  if grep -Eq "^[[:space:]]*${LEGACY_NTP_VAR}[[:space:]]*=" "$LEGACY_CONFIG"; then
    printf 'Legacy NTP option remained active: %s\n' "$LEGACY_NTP_VAR" >&2
    exit 1
  fi
done

FORBIDDEN='Linux-NetSpeed|fscarmen/(argox|sba|client_template)|tcp\.hy2|api\.qrserver\.com|cloudflare\.now\.cc|chika0801/sing-box-examples|hub\.glowp\.xyz|proxy\.vvvv\.ee'
if rg -n "$FORBIDDEN" "$ROOT_DIR/src" "$ROOT_DIR/Dockerfile"; then
  printf 'Removed third-party dependency was reintroduced\n' >&2
  exit 1
fi

if sed -n '/^check_install() {/,/^}/p' "$ROOT_DIR/src/vps/30_system.sh" | grep -Fq 'cloudflare/cloudflared/releases'; then
  printf 'check_install must not download cloudflared before Argo is selected\n' >&2
  exit 1
fi

grep -Fq 'prepare_cloudflared_asset &' "$ROOT_DIR/src/vps/50_runtime.sh"
if rg -n 'qrencode[[:space:]]+-t|libqrencode-tools' "$ROOT_DIR/src" "$ROOT_DIR/Dockerfile"; then
  printf 'QR generation dependency was reintroduced\n' >&2
  exit 1
fi

if rg -n 'normalize_ntp_config|NTP_[A-Z_]+_DEFAULT|"ntp"' "$ROOT_DIR/src"; then
  printf 'sing-box NTP configuration was reintroduced\n' >&2
  exit 1
fi
if rg -n 'NTP_ENABLED|NTP_SERVER|NTP_INTERVAL' \
  "$ROOT_DIR/README.md" "$ROOT_DIR/config.conf" "$ROOT_DIR/docker-compose.example.yml"; then
  printf 'Removed NTP options were reintroduced in user configuration\n' >&2
  exit 1
fi
grep -Fq 'rm -f "${WORK_DIR}/conf/06_ntp.json"' "$ROOT_DIR/src/vps/40_config.sh"
grep -Fq 'config_state_comment_line "$_tmp" NTP_ENABLED' "$ROOT_DIR/src/vps/20_helpers.sh"

grep -Fq 'ARG S6_OVERLAY_VERSION=3.2.3.2' "$ROOT_DIR/Dockerfile"
grep -Fq 'sha256sum -c' "$ROOT_DIR/Dockerfile"
if grep -Fq 's6-overlay/releases/latest' "$ROOT_DIR/Dockerfile"; then
  printf 's6-overlay must use a pinned release\n' >&2
  exit 1
fi

printf 'local asset tests passed\n'
