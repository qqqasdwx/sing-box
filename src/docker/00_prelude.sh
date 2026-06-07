#!/usr/bin/env bash

# Docker keeps only container-specific defaults here. Protocol generation,
# subscriptions, Argo parsing, and node export are shared with the VPS script.
VERSION='v1.3.14 (2026.05.29)'

GITHUB_PROXY=('https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/')

TEMP_DIR='/tmp/sing-box'
WORK_DIR='/sing-box'
FIREWALL_STATE_DIR="${WORK_DIR}/firewall"
SERVICE_FIREWALL_STATE_FILE="${FIREWALL_STATE_DIR}/service_ports.list"
START_PORT_DEFAULT='8881'
LOG_LEVEL_DEFAULT='error'
NTP_ENABLED_DEFAULT='true'
NTP_SERVER_DEFAULT='time.apple.com'
NTP_SERVER_PORT_DEFAULT='123'
NTP_INTERVAL_DEFAULT='60m'
MIN_PORT=100
MAX_PORT=65520
MIN_HOPPING_PORT=10000
MAX_HOPPING_PORT=65535
TLS_SERVER_DEFAULT=addons.mozilla.org
PROTOCOL_LIST=("XTLS + reality" "hysteria2" "tuic" "ShadowTLS" "shadowsocks" "trojan" "vmess + ws" "vless + ws + tls" "H2 + reality" "gRPC + reality" "AnyTLS" "naive")
NODE_TAG=("xtls-reality" "hysteria2" "tuic" "ShadowTLS" "shadowsocks" "trojan" "vmess-ws" "vless-ws-tls" "h2-reality" "grpc-reality" "anytls" "naive")
CONSECUTIVE_PORTS=${#PROTOCOL_LIST[@]}
CDN_DOMAIN=("skk.moe" "ip.sb" "time.is" "cfip.xxxxxxxx.tk" "bestcf.top" "cdn.2020111.xyz" "xn--b6gac.eu.org" "cf.090227.xyz")
SUBSCRIBE_TEMPLATE="https://raw.githubusercontent.com/fscarmen/client_template/main"
DEFAULT_NEWEST_VERSION='1.13.0-rc.4'
STEP_NUM=0
TOTAL_STEPS=''

export DEBIAN_FRONTEND=noninteractive

cleanup_temp() {
  rm -rf "$TEMP_DIR"
}

trap cleanup_temp EXIT
trap 'cleanup_temp; printf "\n"; exit 1' INT QUIT TERM

mkdir -p "$TEMP_DIR"
