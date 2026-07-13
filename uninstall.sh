#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR='/opt/aethercloud-v6'
readonly ENV_FILE="${INSTALL_DIR}/.env"
readonly COMPOSE_FILE="${INSTALL_DIR}/compose.yml"
readonly LEGACY_ENV_FILE='/etc/aethercloud-v6.env'
readonly LEGACY_RUNNER='/usr/local/sbin/aethercloud-v6'
readonly LEGACY_UNINSTALLER='/usr/local/sbin/aethercloud-v6-uninstall'
readonly LEGACY_UNIT_FILE='/etc/systemd/system/aethercloud-v6.service'

[ "${EUID:-$(id -u)}" -eq 0 ] || {
  printf 'Run this uninstaller as root.\n' >&2
  exit 1
}

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now aethercloud-v6.service >/dev/null 2>&1 || true
fi

if [ -x "$LEGACY_RUNNER" ]; then
  "$LEGACY_RUNNER" stop >/dev/null 2>&1 || true
  "$LEGACY_RUNNER" remove-network >/dev/null 2>&1 || true
fi

if [ -r "$COMPOSE_FILE" ] && [ -r "$ENV_FILE" ]; then
  docker compose --project-directory "$INSTALL_DIR" \
    --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down --remove-orphans
else
  docker rm -f aethercloud-v6 >/dev/null 2>&1 || true
  docker network rm aethercloud-v6-wan aethercloud-v6-net >/dev/null 2>&1 || true
fi

rm -f "$COMPOSE_FILE" "$LEGACY_UNIT_FILE" "$LEGACY_RUNNER" "$LEGACY_UNINSTALLER"
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

if [ -e "$ENV_FILE" ]; then
  printf 'AetherCloud gateway removed. Configuration remains at %s.\n' "$ENV_FILE"
elif [ -e "$LEGACY_ENV_FILE" ]; then
  printf 'AetherCloud gateway removed. Configuration remains at %s.\n' \
    "$LEGACY_ENV_FILE"
else
  printf 'AetherCloud gateway removed.\n'
fi
