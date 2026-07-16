#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

jq_exec() {
  jq "$@"
}

source "$ROOT_DIR/src/vps/45_v2rayn.sh"

REALM_URL='realm://public@realm.hy2.io:443/00000000-0000-0000-0000-000000000000?stun=stun.nextcloud.com:3478&stun=stun.sip.us:3478&stun=turn.cloudflare.com:3478&stun=global.stun.twilio.com:3478'

check_case() {
  local realm_url="$1"
  local hopping_ports="$2"
  local output

  output=$(build_v2rayn_hysteria2_json \
    'test hysteria2' \
    '2001:db8::10' \
    443 \
    '00000000-0000-0000-0000-000000000000' \
    'example.com' \
    $'line1\r\nline2\r\n' \
    200 \
    1000 \
    "$realm_url" \
    "$hopping_ports")

  jq -e '
    .ConfigType == 7 and
    .ConfigVersion == 4 and
    .Address == "2001:db8::10" and
    .Port == 443 and
    .AllowInsecure == "false" and
    .ProtoExtraObj.UpMbps == 200 and
    .ProtoExtraObj.DownMbps == 1000 and
    (has("Finalmask") | not) and
    (.ProtoExtraObj | has("Finalmask") | not)
  ' <<< "$output" >/dev/null

  if [ -n "$realm_url" ]; then
    jq -e --arg realm_url "$realm_url" '.ProtoExtraObj.Hy2RealmUrl == $realm_url' <<< "$output" >/dev/null
  else
    jq -e '(.ProtoExtraObj | has("Hy2RealmUrl") | not)' <<< "$output" >/dev/null
  fi

  if [ -n "$hopping_ports" ]; then
    jq -e --arg ports "$hopping_ports" '
      .ProtoExtraObj.Ports == $ports and .ProtoExtraObj.HopInterval == "30s"
    ' <<< "$output" >/dev/null
  else
    jq -e '
      (.ProtoExtraObj | has("Ports") | not) and
      (.ProtoExtraObj | has("HopInterval") | not)
    ' <<< "$output" >/dev/null
  fi
}

check_case '' ''
check_case "$REALM_URL" ''
check_case '' '50000-51000'
check_case "$REALM_URL" '50000-51000'

printf 'v2rayN Hysteria2 JSON tests passed\n'
