#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_FILE='/etc/aethercloud-v6.env'
readonly RUNNER='/usr/local/sbin/aethercloud-v6'
readonly UNINSTALLER='/usr/local/sbin/aethercloud-v6-uninstall'
readonly UNIT_FILE='/etc/systemd/system/aethercloud-v6.service'
readonly DEFAULT_IMAGE='ghcr.io/qqqasdwx/sing-box:aethercloud'
readonly SOURCE_BASE="${AETHERCLOUD_SOURCE_BASE:-https://raw.githubusercontent.com/qqqasdwx/sing-box/aethercloud}"

SCRIPT_DIR=''
SOURCE_DIR=''
SOURCE_TEMP=''
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  if ! SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); then
    SCRIPT_DIR=''
  fi
fi

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [ -z "$SOURCE_TEMP" ] || rm -rf "$SOURCE_TEMP"
}

trap cleanup EXIT

download_file() {
  local url=$1 output=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 -o "$output" "$url" ||
      fatal "failed to download $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=20 -O "$output" "$url" ||
      fatal "failed to download $url"
  else
    fatal 'curl or wget is required for remote installation'
  fi
  [ -s "$output" ] || fatal "downloaded file is empty: $url"
}

source_files_available() {
  local file
  [ -n "$SCRIPT_DIR" ] || return 1
  for file in aethercloud-v6 aethercloud-v6.service aethercloud-v6.env.example uninstall.sh; do
    [ -r "$SCRIPT_DIR/$file" ] || return 1
  done
}

prepare_source_dir() {
  local file
  if source_files_available; then
    SOURCE_DIR=$SCRIPT_DIR
    return
  fi

  SOURCE_TEMP=$(mktemp -d) || fatal 'unable to create a temporary directory'
  SOURCE_DIR=$SOURCE_TEMP
  for file in aethercloud-v6 aethercloud-v6.service aethercloud-v6.env.example uninstall.sh; do
    download_file "$SOURCE_BASE/$file" "$SOURCE_DIR/$file"
  done
}

json_escape() {
  local value=$1 character escaped='' code index
  for ((index = 0; index < ${#value}; index++)); do
    character=${value:index:1}
    case "$character" in
      $'"') escaped+='\"' ;;
      $'\\') escaped="${escaped}\\\\" ;;
      $'\b' ) escaped+='\b' ;;
      $'\f' ) escaped+='\f' ;;
      $'\n' ) escaped+='\n' ;;
      $'\r' ) escaped+='\r' ;;
      $'\t' ) escaped+='\t' ;;
      * )
        printf -v code '%d' "'$character"
        if [ "$code" -lt 32 ]; then
          printf -v character '\\u%04x' "$code"
        fi
        escaped+=$character
        ;;
    esac
  done
  printf '%s' "$escaped"
}

print_sing_box_outbound() {
  local server username password
  server=$(json_escape "${AETHERCLOUD_CONTAINER_IPV6:-fd53:ac::2}")
  username=$(json_escape "${AETHERCLOUD_SOCKS_USERNAME:-aethercloud}")
  password=$(json_escape "${AETHERCLOUD_SOCKS_PASSWORD:-}")

  printf '\n可复制到 sing-box custom/04_outbounds.json 的出站配置：\n\n'
  printf '{\n'
  printf '  "type": "socks",\n'
  printf '  "tag": "aethercloud",\n'
  printf '  "server": "%s",\n' "$server"
  printf '  "server_port": 1080,\n'
  printf '  "version": "5",\n'
  printf '  "username": "%s",\n' "$username"
  printf '  "password": "%s"\n' "$password"
  printf '}\n'
}

wait_for_gateway() {
  local container=${AETHERCLOUD_CONTAINER:-aethercloud-v6}
  local health='' attempt

  for ((attempt = 0; attempt < 90; attempt++)); do
    health=$(docker inspect -f \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "$container" 2>/dev/null || true)
    [ "$health" = healthy ] && return 0
    systemctl is-active --quiet aethercloud-v6.service || break
    sleep 1
  done

  systemctl status aethercloud-v6.service --no-pager --full >&2 || true
  docker logs --tail 100 "$container" >&2 2>/dev/null || true
  fatal "AetherCloud gateway did not become healthy (last status: ${health:-absent})"
}

[ "${EUID:-$(id -u)}" -eq 0 ] || fatal 'run this installer as root'
command -v docker >/dev/null 2>&1 || fatal 'Docker is required'
command -v systemctl >/dev/null 2>&1 || fatal 'systemd is required'
docker info >/dev/null 2>&1 || fatal 'Docker is not running'
prepare_source_dir
bash -n "$SOURCE_DIR/aethercloud-v6" "$SOURCE_DIR/uninstall.sh" ||
  fatal 'downloaded scripts failed syntax validation'

requested_image=${AETHERCLOUD_IMAGE:-$DEFAULT_IMAGE}
case "$requested_image" in
  *[!a-zA-Z0-9./:@_-]*) fatal 'AETHERCLOUD_IMAGE contains unsupported characters' ;;
esac

install -m 0755 "$SOURCE_DIR/aethercloud-v6" "$RUNNER"
install -m 0755 "$SOURCE_DIR/uninstall.sh" "$UNINSTALLER"
install -m 0644 "$SOURCE_DIR/aethercloud-v6.service" "$UNIT_FILE"

if [ ! -e "$CONFIG_FILE" ]; then
  password=$(tr -d '-' < /proc/sys/kernel/random/uuid)
  sed \
    -e "s#ghcr.io/qqqasdwx/sing-box:aethercloud#$requested_image#" \
    -e "s/replace-with-a-random-password/$password/" \
    "$SOURCE_DIR/aethercloud-v6.env.example" > "$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"
  printf 'Created %s with a random SOCKS5 password.\n' "$CONFIG_FILE"
else
  printf 'Preserved existing configuration: %s\n' "$CONFIG_FILE"
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"
if [ "${AETHERCLOUD_SKIP_PULL:-false}" != true ]; then
  docker pull "${AETHERCLOUD_IMAGE:-$DEFAULT_IMAGE}"
fi

systemctl daemon-reload
systemctl enable aethercloud-v6.service >/dev/null
systemctl restart aethercloud-v6.service
wait_for_gateway
printf 'AetherCloud gateway installed. Run: aethercloud-v6 status\n'
print_sing_box_outbound
