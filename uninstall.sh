#!/usr/bin/env bash
set -Eeuo pipefail

[ "${EUID:-$(id -u)}" -eq 0 ] || {
  printf 'Run this uninstaller as root.\n' >&2
  exit 1
}

systemctl disable --now aethercloud-v6.service >/dev/null 2>&1 || true
/usr/local/sbin/aethercloud-v6 stop >/dev/null 2>&1 || true
/usr/local/sbin/aethercloud-v6 remove-network >/dev/null 2>&1 || true
rm -f /etc/systemd/system/aethercloud-v6.service
rm -f /usr/local/sbin/aethercloud-v6
systemctl daemon-reload

printf 'AetherCloud gateway removed. Configuration remains at /etc/aethercloud-v6.env.\n'
