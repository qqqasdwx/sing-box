#!/usr/bin/env bash
set -Eeuo pipefail

readonly API_BASE='https://billing.aethercloud.io/api/dynamicv6/vm'
readonly WAN_INTERFACE='wan0'
readonly ROUTE_TABLE='16000'
readonly RULE_PREF='16000'
readonly MTU='1280'
readonly STATE_DIR='/run/aethercloud'
readonly POLL_INTERVAL='120'

SOCKD_PID=''
CURRENT_CIDR=''
CURRENT_GATEWAY=''

log() {
  printf '[aethercloud] %s\n' "$*"
}

fatal() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  trap - EXIT INT TERM
  if [ -n "$SOCKD_PID" ]; then
    kill "$SOCKD_PID" >/dev/null 2>&1 || true
    wait "$SOCKD_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

for command in curl ip jq sockd; do
  command -v "$command" >/dev/null 2>&1 || fatal "missing command: $command"
done

[ -n "${AETHERCLOUD_ROUTER_MAC:-}" ] || fatal 'AETHERCLOUD_ROUTER_MAC is required'
[ -n "${SOCKS_USERNAME:-}" ] || fatal 'SOCKS_USERNAME is required'
[ -n "${SOCKS_PASSWORD:-}" ] || fatal 'SOCKS_PASSWORD is required'

case "$SOCKS_USERNAME" in
  *[!a-zA-Z0-9_-]*|'') fatal 'SOCKS_USERNAME contains unsupported characters' ;;
esac

VM_UUID=${DYNAMICV6_VM_UUID:-}
if [ -z "$VM_UUID" ] && [ -r /sys/class/dmi/id/product_uuid ]; then
  VM_UUID=$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_uuid | tr -d '[:space:]')
fi
[ -n "$VM_UUID" ] || fatal 'unable to detect VM UUID'

if id "$SOCKS_USERNAME" >/dev/null 2>&1; then
  printf '%s:%s\n' "$SOCKS_USERNAME" "$SOCKS_PASSWORD" | chpasswd
else
  adduser -D -H -s /sbin/nologin "$SOCKS_USERNAME"
  printf '%s:%s\n' "$SOCKS_USERNAME" "$SOCKS_PASSWORD" | chpasswd
fi

mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

wait_for_wan() {
  for _ in $(seq 1 60); do
    if ip link show dev "$WAN_INTERFACE" >/dev/null 2>&1 &&
      [ -e "$STATE_DIR/host-ready" ]; then
      ip link set dev "$WAN_INTERFACE" mtu "$MTU"
      ip link set dev "$WAN_INTERFACE" up
      return 0
    fi
    sleep 1
  done
  fatal "$WAN_INTERFACE was not attached within 60 seconds"
}

api_request() {
  local action=$1
  local payload
  payload=$(jq -nc --arg id "$VM_UUID" '{vm_uuid:$id}')
  curl -4 -fsS \
    --connect-timeout 6 \
    --max-time 20 \
    --retry 2 \
    --retry-delay 1 \
    --retry-connrefused \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "$API_BASE/$action"
}

first_lease() {
  jq -ce '
    def normalized:
      if . == null then []
      elif type == "array" then .
      elif type == "object" then [.]
      elif type == "string" then
        (try fromjson catch null)
        | if type == "array" then . elif type == "object" then [.] else [] end
      else [] end;
    ((.leases | normalized) + (.lease | normalized))
    | map(select((.ipv6_cidr? | type) == "string" and (.ipv6_cidr | length > 0)))
    | first
  '
}

gateway_from_prefix() {
  local prefix=$1
  case "$prefix" in
    *::/80) printf '%s::3\n' "${prefix%::/80}" ;;
    *) return 1 ;;
  esac
}

read_lease() {
  local response action active lease cidr gateway prefix

  response=$(api_request status) || return 1
  action='status'
  active=$(jq -r '.active // false' <<< "$response")
  if [ "$active" != true ]; then
    response=$(api_request allocate) || return 1
    action='allocate'
  fi

  lease=$(first_lease <<< "$response") || return 1
  cidr=$(jq -r '.ipv6_cidr // empty' <<< "$lease")
  gateway=$(jq -r '.gateway // empty' <<< "$lease")
  prefix=$(jq -r '.prefix // empty' <<< "$lease")

  if [ -z "$gateway" ]; then
    gateway=$(gateway_from_prefix "$prefix") || return 1
  fi

  printf '%s|%s|%s\n' "$cidr" "$gateway" "$action"
}

configure_lease() {
  local cidr=$1
  local gateway=$2
  local ip_address=${cidr%/*}

  ip link set dev "$WAN_INTERFACE" mtu "$MTU"
  ip link set dev "$WAN_INTERFACE" up
  ip -6 addr flush dev "$WAN_INTERFACE" scope global
  ip -6 addr add "$cidr" nodad dev "$WAN_INTERFACE"
  ip -6 neigh replace "$gateway" \
    lladdr "$AETHERCLOUD_ROUTER_MAC" nud permanent dev "$WAN_INTERFACE"

  while ip -6 rule del pref "$RULE_PREF" >/dev/null 2>&1; do :; done
  ip -6 route flush table "$ROUTE_TABLE" 2>/dev/null || true
  ip -6 route replace "$gateway/128" dev "$WAN_INTERFACE" table "$ROUTE_TABLE"
  ip -6 route replace default via "$gateway" dev "$WAN_INTERFACE" \
    onlink src "$ip_address" mtu "$MTU" table "$ROUTE_TABLE"
  ip -6 rule add pref "$RULE_PREF" from "$cidr" table "$ROUTE_TABLE"

  printf '%s\n' "$cidr" > "$STATE_DIR/ipv6_cidr"
  printf '%s\n' "$gateway" > "$STATE_DIR/gateway"
}

lease_is_configured() {
  local cidr=$1
  local gateway=$2
  local rule_source=${cidr%/128}

  ip -6 -j addr show dev "$WAN_INTERFACE" |
    jq -e --arg cidr "$cidr" '
      any(.[].addr_info[]?;
        (.local + "/" + (.prefixlen | tostring)) == $cidr)
    ' >/dev/null || return 1
  ip -6 -j route show table "$ROUTE_TABLE" |
    jq -e --arg gateway "$gateway" --arg interface "$WAN_INTERFACE" '
      any(.[]; .dst == "default" and .gateway == $gateway and .dev == $interface)
    ' >/dev/null || return 1
  ip -6 -j rule show |
    jq -e --arg source "$rule_source" --arg table "$ROUTE_TABLE" '
      any(.[]; .src == $source and .table == $table)
    ' >/dev/null || return 1
}

start_sockd() {
  local external_ip=${CURRENT_CIDR%/*}

  if [ -n "$SOCKD_PID" ]; then
    kill "$SOCKD_PID" >/dev/null 2>&1 || true
    wait "$SOCKD_PID" 2>/dev/null || true
  fi

  sed "s/@AETHERCLOUD_IPV6@/$external_ip/" \
    /etc/sockd.conf.template > "$STATE_DIR/sockd.conf"
  chmod 0600 "$STATE_DIR/sockd.conf"

  sockd -f "$STATE_DIR/sockd.conf" -p "$STATE_DIR/sockd.pid" &
  SOCKD_PID=$!
  printf '%s\n' "$SOCKD_PID" > "$STATE_DIR/sockd-supervisor.pid"
  sleep 1
  kill -0 "$SOCKD_PID" >/dev/null 2>&1 || fatal 'Dante failed to start'
}

wait_for_wan

while true; do
  if lease_record=$(read_lease); then
    IFS='|' read -r lease_cidr lease_gateway api_action <<< "$lease_record"
    if [ "$lease_cidr" != "$CURRENT_CIDR" ] ||
      [ "$lease_gateway" != "$CURRENT_GATEWAY" ]; then
      configure_lease "$lease_cidr" "$lease_gateway"
      CURRENT_CIDR=$lease_cidr
      CURRENT_GATEWAY=$lease_gateway
      start_sockd
      log "lease ready: $lease_cidr via $lease_gateway, mtu=$MTU, api=$api_action"
    else
      if ! lease_is_configured "$lease_cidr" "$lease_gateway"; then
        configure_lease "$lease_cidr" "$lease_gateway"
        start_sockd
        log 'lease networking repaired'
      fi
      if [ -z "$SOCKD_PID" ] || ! kill -0 "$SOCKD_PID" >/dev/null 2>&1; then
        start_sockd
        log 'Dante restarted'
      fi
      log "lease refreshed: $lease_cidr"
    fi
  else
    log 'lease refresh failed; keeping the current configuration'
    if [ -z "$CURRENT_CIDR" ]; then
      sleep 10
      continue
    fi
  fi

  sleep "$POLL_INTERVAL" &
  wait $! || exit 0
done
