#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly INSTALL_DIR
readonly CONFIG_FILE='/etc/aethercloud-v6.env'
readonly RUNNER='/usr/local/sbin/aethercloud-v6'
readonly UNIT_FILE='/etc/systemd/system/aethercloud-v6.service'
readonly DEFAULT_IMAGE='ghcr.io/qqqasdwx/sing-box:aethercloud'

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[ "${EUID:-$(id -u)}" -eq 0 ] || fatal 'run this installer as root'
command -v docker >/dev/null 2>&1 || fatal 'Docker is required'
command -v systemctl >/dev/null 2>&1 || fatal 'systemd is required'
docker info >/dev/null 2>&1 || fatal 'Docker is not running'

requested_image=${AETHERCLOUD_IMAGE:-$DEFAULT_IMAGE}
case "$requested_image" in
  *[!a-zA-Z0-9./:@_-]*) fatal 'AETHERCLOUD_IMAGE contains unsupported characters' ;;
esac

install -m 0755 "$INSTALL_DIR/aethercloud-v6" "$RUNNER"
install -m 0644 "$INSTALL_DIR/aethercloud-v6.service" "$UNIT_FILE"

if [ ! -e "$CONFIG_FILE" ]; then
  password=$(tr -d '-' < /proc/sys/kernel/random/uuid)
  sed \
    -e "s#ghcr.io/qqqasdwx/sing-box:aethercloud#$requested_image#" \
    -e "s/replace-with-a-random-password/$password/" \
    "$INSTALL_DIR/aethercloud-v6.env.example" > "$CONFIG_FILE"
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
systemctl enable --now aethercloud-v6.service
printf 'AetherCloud gateway installed. Run: aethercloud-v6 status\n'
