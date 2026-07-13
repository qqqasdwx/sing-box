#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR='/opt/aethercloud-v6'
readonly ENV_FILE="${INSTALL_DIR}/.env"
readonly COMPOSE_FILE="${INSTALL_DIR}/compose.yml"
readonly LEGACY_CONFIG_FILE='/etc/aethercloud-v6.env'
readonly LEGACY_RUNNER='/usr/local/sbin/aethercloud-v6'
readonly LEGACY_UNINSTALLER='/usr/local/sbin/aethercloud-v6-uninstall'
readonly LEGACY_UNIT_FILE='/etc/systemd/system/aethercloud-v6.service'
readonly DEFAULT_IMAGE='ghcr.io/qqqasdwx/sing-box:aethercloud'
readonly SOURCE_BASE="${AETHERCLOUD_SOURCE_BASE:-https://raw.githubusercontent.com/qqqasdwx/sing-box/aethercloud}"

SCRIPT_DIR=''
SOURCE_DIR=''
SOURCE_TEMP=''
LEGACY_CONFIG_PRESENT=false
[ -e "$LEGACY_CONFIG_FILE" ] && LEGACY_CONFIG_PRESENT=true
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
  [ -n "$SCRIPT_DIR" ] &&
    [ -r "$SCRIPT_DIR/compose.yml" ] &&
    [ -r "$SCRIPT_DIR/aethercloud-v6.env.example" ]
}

prepare_source_dir() {
  if source_files_available; then
    SOURCE_DIR=$SCRIPT_DIR
    return
  fi

  SOURCE_TEMP=$(mktemp -d) || fatal 'unable to create a temporary directory'
  SOURCE_DIR=$SOURCE_TEMP
  download_file "$SOURCE_BASE/compose.yml" "$SOURCE_DIR/compose.yml"
  download_file "$SOURCE_BASE/aethercloud-v6.env.example" \
    "$SOURCE_DIR/aethercloud-v6.env.example"
}

detect_parent() {
  ip -4 route show default | awk '{print $5; exit}'
}

detect_router_mac() {
  local parent=$1 gateway mac
  gateway=$(ip -6 route show default dev "$parent" 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}')
  [ -n "$gateway" ] || fatal "no IPv6 default gateway on $parent"

  if command -v ping >/dev/null 2>&1; then
    ping -6 -c 1 -W 2 -I "$parent" "$gateway" >/dev/null 2>&1 || true
  fi
  mac=$(ip -6 neigh show to "$gateway" dev "$parent" 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "lladdr") {print $(i + 1); exit}}')
  [ -n "$mac" ] || fatal "unable to resolve the router MAC for $gateway"
  printf '%s\n' "$mac"
}

detect_vm_uuid() {
  [ -r /sys/class/dmi/id/product_uuid ] || fatal 'unable to detect the VM UUID'
  tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_uuid | tr -d '[:space:]'
}

set_env_value() {
  local key=$1 value=$2 temporary
  case "$value" in
    *"'"*|*$'\n'*|*$'\r'*) fatal "unsupported character in $key" ;;
  esac
  temporary=$(mktemp "${INSTALL_DIR}/.env.XXXXXX") || fatal 'unable to update .env'
  awk -v key="$key" -v value="$value" '
    BEGIN { replacement = key "=\047" value "\047" }
    $0 ~ ("^" key "=") {
      if (!updated) print replacement
      updated = 1
      next
    }
    { print }
    END { if (!updated) print replacement }
  ' "$ENV_FILE" > "$temporary"
  chmod 0600 "$temporary"
  mv "$temporary" "$ENV_FILE"
}

compose() {
  docker compose --project-directory "$INSTALL_DIR" \
    --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

remove_unmanaged_network() {
  local network=$1 compose_label
  docker network inspect "$network" >/dev/null 2>&1 || return 0
  compose_label=$(docker network inspect -f \
    '{{index .Labels "com.docker.compose.network"}}' "$network" 2>/dev/null || true)
  [ -n "$compose_label" ] || docker network rm "$network" >/dev/null
}

migrate_legacy_runtime() {
  local container=${AETHERCLOUD_CONTAINER:-aethercloud-v6}
  local compose_project=''

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now aethercloud-v6.service >/dev/null 2>&1 || true
  fi

  compose_project=$(docker inspect -f \
    '{{index .Config.Labels "com.docker.compose.project"}}' \
    "$container" 2>/dev/null || true)
  if docker inspect "$container" >/dev/null 2>&1 && [ -z "$compose_project" ]; then
    docker rm -f "$container" >/dev/null
  fi
  remove_unmanaged_network "${AETHERCLOUD_DOCKER_NETWORK:-aethercloud-v6-net}"
  rm -f "$LEGACY_UNIT_FILE" "$LEGACY_RUNNER" "$LEGACY_UNINSTALLER"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

json_escape() {
  local value=$1 character escaped='' code index
  for ((index = 0; index < ${#value}; index++)); do
    character=${value:index:1}
    case "$character" in
      $'"') escaped+='\"' ;;
      $'\\') escaped="${escaped}\\\\" ;;
      $'\b') escaped+='\b' ;;
      $'\f') escaped+='\f' ;;
      $'\n') escaped+='\n' ;;
      $'\r') escaped+='\r' ;;
      $'\t') escaped+='\t' ;;
      *)
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
    sleep 1
  done
  compose ps >&2 || true
  compose logs --tail 100 >&2 || true
  fatal "AetherCloud gateway did not become healthy (last status: ${health:-absent})"
}

[ "${EUID:-$(id -u)}" -eq 0 ] || fatal 'run this installer as root'
for command in docker ip awk; do
  command -v "$command" >/dev/null 2>&1 || fatal "$command is required"
done
docker info >/dev/null 2>&1 || fatal 'Docker is not running'
docker compose version >/dev/null 2>&1 || fatal 'Docker Compose v2 is required'
prepare_source_dir

image_override=${AETHERCLOUD_IMAGE:-}
parent_override=${AETHERCLOUD_PARENT:-}
router_mac_override=${AETHERCLOUD_ROUTER_MAC:-}
vm_uuid_override=${DYNAMICV6_VM_UUID:-}
mkdir -p "$INSTALL_DIR"
install -m 0644 "$SOURCE_DIR/compose.yml" "$COMPOSE_FILE"

if [ ! -e "$ENV_FILE" ]; then
  if [ -e "$LEGACY_CONFIG_FILE" ]; then
    install -m 0600 "$LEGACY_CONFIG_FILE" "$ENV_FILE"
    printf 'Migrated existing configuration to %s\n' "$ENV_FILE"
  else
    password=$(tr -d '-' < /proc/sys/kernel/random/uuid)
    sed \
      -e "s/replace-with-a-random-password/$password/" \
      "$SOURCE_DIR/aethercloud-v6.env.example" > "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    printf 'Created %s with a random SOCKS5 password.\n' "$ENV_FILE"
  fi
else
  printf 'Preserved existing configuration: %s\n' "$ENV_FILE"
fi

# shellcheck disable=SC1090
. "$ENV_FILE"
AETHERCLOUD_IMAGE=${image_override:-${AETHERCLOUD_IMAGE:-$DEFAULT_IMAGE}}
AETHERCLOUD_PARENT=${parent_override:-$(detect_parent)}
[ -n "$AETHERCLOUD_PARENT" ] || fatal 'unable to detect the parent interface'
ip link show dev "$AETHERCLOUD_PARENT" >/dev/null 2>&1 ||
  fatal "parent interface does not exist: $AETHERCLOUD_PARENT"
AETHERCLOUD_ROUTER_MAC=${router_mac_override:-$(detect_router_mac "$AETHERCLOUD_PARENT")}
DYNAMICV6_VM_UUID=${vm_uuid_override:-$(detect_vm_uuid)}
AETHERCLOUD_SOCKS_PASSWORD=${AETHERCLOUD_SOCKS_PASSWORD:-}
[ -n "$AETHERCLOUD_SOCKS_PASSWORD" ] || fatal 'AETHERCLOUD_SOCKS_PASSWORD is required'
case "$AETHERCLOUD_IMAGE" in
  *[!a-zA-Z0-9./:@_-]*) fatal 'AETHERCLOUD_IMAGE contains unsupported characters' ;;
esac

set_env_value AETHERCLOUD_IMAGE "$AETHERCLOUD_IMAGE"
set_env_value AETHERCLOUD_PARENT "$AETHERCLOUD_PARENT"
set_env_value AETHERCLOUD_ROUTER_MAC "$AETHERCLOUD_ROUTER_MAC"
set_env_value DYNAMICV6_VM_UUID "$DYNAMICV6_VM_UUID"

# Reload the normalized values written above.
# shellcheck disable=SC1090
. "$ENV_FILE"
migrate_legacy_runtime
if [ "${AETHERCLOUD_SKIP_PULL:-false}" != true ]; then
  compose pull
fi
compose up -d --remove-orphans --force-recreate
wait_for_gateway
[ "$LEGACY_CONFIG_PRESENT" = false ] || rm -f "$LEGACY_CONFIG_FILE"

printf 'AetherCloud gateway is healthy. Compose directory: %s\n' "$INSTALL_DIR"
print_sing_box_outbound
