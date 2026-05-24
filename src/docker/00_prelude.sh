#!/usr/bin/env bash
# 脚本更新日期 2026.04.23
set -e

WORK_DIR=/sing-box
PORT=$START_PORT
SUBSCRIBE_TEMPLATE="https://raw.githubusercontent.com/fscarmen/client_template/main"

# 自定义字体彩色，read 函数
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }  # 红色
info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

# 判断系统架构，以下载相应的应用
case "$ARCH" in
  arm64 )
    SING_BOX_ARCH=arm64-musl; JQ_ARCH=arm64; QRENCODE_ARCH=arm64; ARGO_ARCH=arm64
    ;;
  amd64 )
    SING_BOX_ARCH=amd64-musl; JQ_ARCH=amd64; QRENCODE_ARCH=amd64; ARGO_ARCH=amd64
    ;;
  armv7 )
    SING_BOX_ARCH=armv7-musl; JQ_ARCH=armhf; QRENCODE_ARCH=arm; ARGO_ARCH=arm
    ;;
esac

# 检查 sing-box 最新版本
check_latest_sing-box() {
  # 检查是否强制指定版本
  local FORCE_VERSION=$(wget --no-check-certificate --tries=2 --timeout=3 -qO- https://raw.githubusercontent.com/fscarmen/sing-box/refs/heads/main/force_version | sed 's/^[vV]//g')

  # 没有强制指定版本时，获取最新版本
  grep -q '.' <<< "$FORCE_VERSION" || local FORCE_VERSION=$(wget --no-check-certificate --tries=2 --timeout=3 -qO- https://api.github.com/repos/SagerNet/sing-box/releases | awk -F '["v-]' '/tag_name/{print $5}' | sort -Vr | sed -n '1p')

  # 获取最终版本号
  local VERSION=$(wget --no-check-certificate --tries=2 --timeout=3 -qO- https://api.github.com/repos/SagerNet/sing-box/releases | awk -F '["v]' -v var="tag_name.*$FORCE_VERSION" '$0 ~ var {print $5; exit}')
  VERSION=${VERSION:-'1.13.0-rc.4'}

  echo "$VERSION"
}
