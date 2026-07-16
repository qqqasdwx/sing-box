#!/usr/bin/env bash

# 当前脚本版本号
VERSION='v1.3.16 (2026.07.16)'

# Github 反代加速代理
GITHUB_PROXY=('https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/')

# 各变量默认值
TEMP_DIR='/tmp/sing-box'
WORK_DIR='/etc/sing-box'
CUSTOM_DIR="${WORK_DIR}/custom"
STATE_DIR="${WORK_DIR}/state"
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
FINGER_PRINT_DEFAULT='chrome'
STEP_NUM=0      # 当前步骤编号（安装流程中动态递增）
TOTAL_STEPS=''  # 总步骤数（协议确定后动态计算）

export DEBIAN_FRONTEND=noninteractive

cleanup_temp() {
  rm -rf "$TEMP_DIR"
}

trap cleanup_temp EXIT
trap 'cleanup_temp; printf "\n"; exit 1' INT QUIT TERM

mkdir -p "$TEMP_DIR"
