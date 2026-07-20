#!/usr/bin/env bash
set -Eeuo pipefail

readonly API_BASE='https://billing.aethercloud.io/api/dynamicv6/vm'
readonly BASE_ROUTE_TABLE='16000'
readonly BASE_RULE_PREF='16000'
readonly BASE_SOCKS_PORT='1080'
readonly MTU='1280'
readonly RUNTIME_DIR='/run/aethercloud'
readonly DATA_DIR='/var/lib/aethercloud'
readonly SLOTS_FILE="$DATA_DIR/leases.json"
readonly ACTIVE_FILE="$RUNTIME_DIR/active-leases.json"
readonly POLL_INTERVAL='120'
readonly MAX_LEASES="${AETHERCLOUD_MAX_LEASES:-16}"
readonly MISSING_GRACE="${AETHERCLOUD_MISSING_GRACE:-3}"
readonly CONTROL_IPV4="${AETHERCLOUD_CONTROL_IPV4:-172.30.53.2}"
readonly WAN_BOOTSTRAP_IPV6="${AETHERCLOUD_WAN_BOOTSTRAP_IPV6:-fd53:ac:ffff::2}"

CONTROL_INTERFACE=''
WAN_INTERFACE=''

declare -a SLOT_WG=()
declare -a SLOT_PREFIX=()
declare -a SLOT_CIDR=()
declare -a SLOT_GATEWAY=()
declare -a SLOT_MISSES=()
declare -a SLOT_PRESENT=()
declare -a LEASE_WG=()
declare -a LEASE_PREFIX=()
declare -a LEASE_CIDR=()
declare -a LEASE_GATEWAY=()
declare -a LEASE_SLOT=()
declare -A CLAIMED_SLOTS=()
declare -A SOCKD_PIDS=()
declare -A ACTIVE_CIDRS=()
declare -A ACTIVE_GATEWAYS=()

log() {
  printf '[aethercloud] %s\n' "$*"
}

fatal() {
  log "ERROR: $*"
  exit 1
}

valid_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

slot_port() {
  printf '%s\n' "$((BASE_SOCKS_PORT + $1))"
}

slot_table() {
  printf '%s\n' "$((BASE_ROUTE_TABLE + $1))"
}

slot_rule_pref() {
  printf '%s\n' "$((BASE_RULE_PREF + $1))"
}

stop_sockd() {
  local slot=$1 pid=${SOCKD_PIDS[$1]:-}
  [ -n "$pid" ] || return 0
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  unset 'SOCKD_PIDS[$slot]'
}

sockd_is_running() {
  local slot=$1 pid=${SOCKD_PIDS[$1]:-} port
  [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1 || return 1
  port=$(slot_port "$slot")
  ss -H -lnt "sport = :$port" 2>/dev/null | grep LISTEN >/dev/null
}

cleanup() {
  local slot
  trap - EXIT INT TERM
  for slot in "${!SOCKD_PIDS[@]}"; do
    stop_sockd "$slot"
  done
}

trap cleanup EXIT INT TERM

find_interface_by_address() {
  local target=${1%/*} path interface address
  for path in /sys/class/net/*; do
    interface=${path##*/}
    [ "$interface" = lo ] && continue
    while read -r address; do
      [ "${address%/*}" = "$target" ] && {
        printf '%s\n' "$interface"
        return 0
      }
    done < <(ip -o addr show dev "$interface" 2>/dev/null | awk '{print $4}')
  done
  return 1
}

wait_for_wan() {
  local control_interface wan_interface
  for _ in $(seq 1 60); do
    if control_interface=$(find_interface_by_address "$CONTROL_IPV4") &&
      wan_interface=$(find_interface_by_address "$WAN_BOOTSTRAP_IPV6") &&
      [ "$control_interface" != "$wan_interface" ]; then
      CONTROL_INTERFACE=$control_interface
      WAN_INTERFACE=$wan_interface
      ip link set dev "$WAN_INTERFACE" mtu "$MTU"
      ip link set dev "$WAN_INTERFACE" up
      printf '%s\n' "$CONTROL_INTERFACE" > "$RUNTIME_DIR/control_interface"
      printf '%s\n' "$WAN_INTERFACE" > "$RUNTIME_DIR/wan_interface"
      log "interfaces ready: control=$CONTROL_INTERFACE wan=$WAN_INTERFACE"
      return 0
    fi
    sleep 1
  done
  fatal 'unable to find the Docker ipvlan interface within 60 seconds'
}

api_request() {
  local action=$1 payload
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

normalize_leases() {
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
    | map({
        wg_interface: (if (.wg_interface? | type) == "string" then .wg_interface else "" end),
        prefix: (if (.prefix? | type) == "string" then .prefix else "" end),
        ipv6_cidr,
        gateway: (if (.gateway? | type) == "string" then .gateway else "" end)
      })
    | map(
        if (.gateway | length) == 0 and (.prefix | endswith("::/80")) then
          .gateway = ((.prefix | rtrimstr("::/80")) + "::3")
        else . end
      )
    | if any(.[]; (.gateway | length) == 0) then
        error("lease has no usable gateway or /80 prefix")
      else . end
    | unique_by(.ipv6_cidr)
    | sort_by(.wg_interface, .prefix, .ipv6_cidr)
  '
}

read_leases() {
  local response action active leases count

  response=$(api_request status) || return 1
  action='status'
  active=$(jq -r '.active // false' <<< "$response")
  if [ "$active" != true ]; then
    response=$(api_request allocate) || return 1
    action='allocate'
  fi

  leases=$(normalize_leases <<< "$response") || return 1
  count=$(jq 'length' <<< "$leases")
  [ "$count" -gt 0 ] || return 1
  if [ "$count" -gt "$MAX_LEASES" ]; then
    log "API returned $count leases; refusing to exceed limit $MAX_LEASES" >&2
    return 1
  fi

  jq -nc --arg action "$action" --argjson leases "$leases" \
    '{action:$action, leases:$leases}'
}

load_slots() {
  local record slot wg prefix cidr gateway misses
  [ -s "$SLOTS_FILE" ] || return 0

  if ! jq -e --argjson maximum "$MAX_LEASES" '
    .version == 1
    and (.slots | type == "array")
    and all(.slots[];
      (.slot | type == "number")
      and (.slot | floor == .)
      and .slot >= 0 and .slot < $maximum
      and (.wg_interface | type == "string")
      and (.prefix | type == "string")
      and (.ipv6_cidr | type == "string" and length > 0)
      and (.gateway | type == "string" and length > 0)
      and (.missing_count | type == "number" and floor == . and . >= 0))
    and (([.slots[].slot] | length) == ([.slots[].slot] | unique | length))
  ' "$SLOTS_FILE" >/dev/null 2>&1; then
    log "ignoring invalid persistent slot state: $SLOTS_FILE"
    return 0
  fi

  while IFS= read -r record; do
    slot=$(jq -r '.slot' <<< "$record")
    wg=$(jq -r '.wg_interface' <<< "$record")
    prefix=$(jq -r '.prefix' <<< "$record")
    cidr=$(jq -r '.ipv6_cidr' <<< "$record")
    gateway=$(jq -r '.gateway' <<< "$record")
    misses=$(jq -r '.missing_count' <<< "$record")
    SLOT_WG[slot]=$wg
    SLOT_PREFIX[slot]=$prefix
    SLOT_CIDR[slot]=$cidr
    SLOT_GATEWAY[slot]=$gateway
    SLOT_MISSES[slot]=$misses
  done < <(jq -c '.slots[]' "$SLOTS_FILE")
}

load_current_leases() {
  local leases=$1 record wg prefix cidr gateway
  LEASE_WG=()
  LEASE_PREFIX=()
  LEASE_CIDR=()
  LEASE_GATEWAY=()
  LEASE_SLOT=()

  while IFS= read -r record; do
    wg=$(jq -r '.wg_interface' <<< "$record")
    prefix=$(jq -r '.prefix' <<< "$record")
    cidr=$(jq -r '.ipv6_cidr' <<< "$record")
    gateway=$(jq -r '.gateway' <<< "$record")
    LEASE_WG+=("$wg")
    LEASE_PREFIX+=("$prefix")
    LEASE_CIDR+=("$cidr")
    LEASE_GATEWAY+=("$gateway")
  done < <(jq -c '.[]' <<< "$leases")
}

assign_lease_to_slot() {
  local lease=$1 slot=$2
  LEASE_SLOT[lease]=$slot
  CLAIMED_SLOTS[$slot]=1
  SLOT_PRESENT[slot]=1
}

match_existing_slots() {
  local mode=$1 lease slot lease_value slot_value
  for ((lease = 0; lease < ${#LEASE_CIDR[@]}; lease++)); do
    [ -z "${LEASE_SLOT[$lease]:-}" ] || continue
    for ((slot = 0; slot < MAX_LEASES; slot++)); do
      [ -n "${SLOT_CIDR[$slot]:-}" ] || continue
      [ -z "${CLAIMED_SLOTS[$slot]:-}" ] || continue
      case "$mode" in
        identity)
          [ -n "${LEASE_WG[$lease]}" ] || continue
          [ -n "${LEASE_PREFIX[$lease]}" ] || continue
          lease_value="${LEASE_WG[$lease]}|${LEASE_PREFIX[$lease]}"
          slot_value="${SLOT_WG[$slot]:-}|${SLOT_PREFIX[$slot]:-}"
          ;;
        wg)
          lease_value=${LEASE_WG[$lease]}
          slot_value=${SLOT_WG[$slot]:-}
          ;;
        prefix)
          lease_value=${LEASE_PREFIX[$lease]}
          slot_value=${SLOT_PREFIX[$slot]:-}
          ;;
        cidr)
          lease_value=${LEASE_CIDR[$lease]}
          slot_value=${SLOT_CIDR[$slot]:-}
          ;;
        *) return 1 ;;
      esac
      [ -n "$lease_value" ] || continue
      if [ "$lease_value" = "$slot_value" ]; then
        assign_lease_to_slot "$lease" "$slot"
        break
      fi
    done
  done
}

find_available_slot() {
  local slot misses
  for ((slot = 0; slot < MAX_LEASES; slot++)); do
    [ -z "${CLAIMED_SLOTS[$slot]:-}" ] || continue
    [ -z "${SLOT_CIDR[$slot]:-}" ] && {
      printf '%s\n' "$slot"
      return 0
    }
  done
  for ((slot = 0; slot < MAX_LEASES; slot++)); do
    [ -z "${CLAIMED_SLOTS[$slot]:-}" ] || continue
    misses=${SLOT_MISSES[$slot]:-0}
    if [ "$misses" -ge "$MISSING_GRACE" ]; then
      printf '%s\n' "$slot"
      return 0
    fi
  done
  return 1
}

assign_slots() {
  local lease slot misses
  CLAIMED_SLOTS=()
  SLOT_PRESENT=()
  LEASE_SLOT=()

  match_existing_slots identity
  match_existing_slots wg
  match_existing_slots prefix
  match_existing_slots cidr

  # With no stable API identifier left, pair recent unmatched slots and leases
  # deterministically. This preserves ports for a likely provider-side rotation.
  for ((lease = 0; lease < ${#LEASE_CIDR[@]}; lease++)); do
    [ -z "${LEASE_SLOT[$lease]:-}" ] || continue
    for ((slot = 0; slot < MAX_LEASES; slot++)); do
      [ -n "${SLOT_CIDR[$slot]:-}" ] || continue
      [ -z "${CLAIMED_SLOTS[$slot]:-}" ] || continue
      misses=${SLOT_MISSES[$slot]:-0}
      [ "$misses" -lt "$MISSING_GRACE" ] || continue
      assign_lease_to_slot "$lease" "$slot"
      break
    done
  done

  for ((lease = 0; lease < ${#LEASE_CIDR[@]}; lease++)); do
    if [ -z "${LEASE_SLOT[$lease]:-}" ]; then
      slot=$(find_available_slot) || {
        log "no free slot for lease ${LEASE_CIDR[$lease]}"
        continue
      }
      assign_lease_to_slot "$lease" "$slot"
    fi
    slot=${LEASE_SLOT[$lease]}
    SLOT_WG[slot]=${LEASE_WG[$lease]}
    SLOT_PREFIX[slot]=${LEASE_PREFIX[$lease]}
    SLOT_CIDR[slot]=${LEASE_CIDR[$lease]}
    SLOT_GATEWAY[slot]=${LEASE_GATEWAY[$lease]}
    SLOT_MISSES[slot]=0
  done

  for ((slot = 0; slot < MAX_LEASES; slot++)); do
    [ -n "${SLOT_CIDR[$slot]:-}" ] || continue
    [ -z "${SLOT_PRESENT[$slot]:-}" ] || continue
    misses=${SLOT_MISSES[$slot]:-0}
    SLOT_MISSES[slot]=$((misses + 1))
  done
}

save_slots() {
  local records temporary slot port table pref
  records=$(mktemp "$DATA_DIR/.leases.records.XXXXXX") || return 1
  temporary=$(mktemp "$DATA_DIR/.leases.json.XXXXXX") || {
    rm -f "$records"
    return 1
  }

  for ((slot = 0; slot < MAX_LEASES; slot++)); do
    [ -n "${SLOT_CIDR[$slot]:-}" ] || continue
    port=$(slot_port "$slot")
    table=$(slot_table "$slot")
    pref=$(slot_rule_pref "$slot")
    jq -nc \
      --argjson slot "$slot" \
      --arg wg_interface "${SLOT_WG[$slot]:-}" \
      --arg prefix "${SLOT_PREFIX[$slot]:-}" \
      --arg ipv6_cidr "${SLOT_CIDR[$slot]}" \
      --arg gateway "${SLOT_GATEWAY[$slot]}" \
      --argjson missing_count "${SLOT_MISSES[$slot]:-0}" \
      --argjson socks_port "$port" \
      --argjson route_table "$table" \
      --argjson rule_pref "$pref" \
      '{slot:$slot, wg_interface:$wg_interface, prefix:$prefix,
        ipv6_cidr:$ipv6_cidr, gateway:$gateway,
        missing_count:$missing_count, socks_port:$socks_port,
        route_table:$route_table, rule_pref:$rule_pref}' >> "$records" || {
      rm -f "$records" "$temporary"
      return 1
    }
  done

  jq -s '{version:1, slots:.}' "$records" > "$temporary" || {
    rm -f "$records" "$temporary"
    return 1
  }
  chmod 0600 "$temporary"
  mv "$temporary" "$SLOTS_FILE"
  rm -f "$records"
}

lease_is_configured() {
  local slot=$1 cidr=$2 gateway=$3 table pref source
  table=$(slot_table "$slot")
  pref=$(slot_rule_pref "$slot")
  source=${cidr%/*}

  ip -6 -j addr show dev "$WAN_INTERFACE" |
    jq -e --arg cidr "$cidr" '
      any(.[].addr_info[]?;
        (.local + "/" + (.prefixlen | tostring)) == $cidr)
    ' >/dev/null || return 1
  ip -6 -j route show table "$table" |
    jq -e --arg gateway "$gateway" --arg interface "$WAN_INTERFACE" '
      any(.[]; .dst == "default" and .gateway == $gateway and .dev == $interface)
    ' >/dev/null || return 1
  ip -6 -j rule show |
    jq -e --arg source "$source" --argjson pref "$pref" --arg table "$table" '
      any(.[]; .src == $source and .priority == $pref and (.table | tostring) == $table)
    ' >/dev/null || return 1
}

configure_slot() {
  local slot=$1 cidr=$2 gateway=$3 table pref ip_address
  table=$(slot_table "$slot")
  pref=$(slot_rule_pref "$slot")
  ip_address=${cidr%/*}

  ip link set dev "$WAN_INTERFACE" mtu "$MTU" || return 1
  ip link set dev "$WAN_INTERFACE" up || return 1
  ip -6 addr replace "$cidr" nodad dev "$WAN_INTERFACE" || return 1
  while ip -6 rule del pref "$pref" >/dev/null 2>&1; do :; done
  ip -6 route flush table "$table" 2>/dev/null || true
  ip -6 route replace "$gateway/128" dev "$WAN_INTERFACE" table "$table" || return 1
  ip -6 route replace default via "$gateway" dev "$WAN_INTERFACE" \
    onlink src "$ip_address" mtu "$MTU" table "$table" || return 1
  ip -6 rule add pref "$pref" from "$cidr" table "$table" || return 1
  lease_is_configured "$slot" "$cidr" "$gateway"
}

address_is_active_elsewhere() {
  local excluded_slot=$1 cidr=$2 slot
  for slot in "${!ACTIVE_CIDRS[@]}"; do
    [ "$slot" = "$excluded_slot" ] && continue
    [ "${ACTIVE_CIDRS[$slot]}" = "$cidr" ] && return 0
  done
  return 1
}

remove_managed_address() {
  local slot=$1 cidr=$2
  [ -n "$cidr" ] || return 0
  address_is_active_elsewhere "$slot" "$cidr" && return 0
  ip -6 addr del "$cidr" dev "$WAN_INTERFACE" >/dev/null 2>&1 || true
}

clear_slot_routes() {
  local slot=$1 table pref
  table=$(slot_table "$slot")
  pref=$(slot_rule_pref "$slot")
  while ip -6 rule del pref "$pref" >/dev/null 2>&1; do :; done
  ip -6 route flush table "$table" 2>/dev/null || true
}

deconfigure_slot() {
  local slot=$1 cidr=${ACTIVE_CIDRS[$1]:-}
  stop_sockd "$slot"
  clear_slot_routes "$slot"
  unset 'ACTIVE_CIDRS[$slot]' 'ACTIVE_GATEWAYS[$slot]'
  remove_managed_address "$slot" "$cidr"
}

start_sockd() {
  local slot=$1 cidr=$2 port directory config pid external_ip
  port=$(slot_port "$slot")
  directory="$RUNTIME_DIR/slots/$slot"
  config="$directory/sockd.conf"
  external_ip=${cidr%/*}

  stop_sockd "$slot"
  mkdir -p "$directory"
  sed \
    -e "s/@AETHERCLOUD_INTERNAL_IPV4@/$CONTROL_IPV4/" \
    -e "s/@AETHERCLOUD_IPV6@/$external_ip/" \
    -e "s/@AETHERCLOUD_PORT@/$port/g" \
    /etc/sockd.conf.template > "$config" || return 1
  chmod 0600 "$config"

  sockd -f "$config" -p "$directory/sockd.pid" &
  pid=$!
  SOCKD_PIDS[$slot]=$pid
  sleep 1
  if ! sockd_is_running "$slot"; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
    unset 'SOCKD_PIDS[$slot]'
    return 1
  fi
}

activate_slot() {
  local slot=$1 cidr=$2 gateway=$3
  local old_cidr=${ACTIVE_CIDRS[$1]:-} old_gateway=${ACTIVE_GATEWAYS[$1]:-}

  if ! configure_slot "$slot" "$cidr" "$gateway"; then
    log "slot $slot network update failed for $cidr"
    clear_slot_routes "$slot"
    if [ "$cidr" != "$old_cidr" ]; then
      remove_managed_address "$slot" "$cidr"
    fi
    if [ -n "$old_cidr" ]; then
      if ! configure_slot "$slot" "$old_cidr" "$old_gateway" >/dev/null 2>&1; then
        deconfigure_slot "$slot"
      fi
    fi
    return 1
  fi

  if ! start_sockd "$slot" "$cidr"; then
    log "slot $slot Dante update failed for $cidr"
    if [ -n "$old_cidr" ]; then
      if configure_slot "$slot" "$old_cidr" "$old_gateway" >/dev/null 2>&1 &&
        start_sockd "$slot" "$old_cidr"; then
        [ "$cidr" = "$old_cidr" ] || remove_managed_address "$slot" "$cidr"
        log "slot $slot restored previous lease $old_cidr"
      else
        deconfigure_slot "$slot"
        [ "$cidr" = "$old_cidr" ] || remove_managed_address "$slot" "$cidr"
      fi
    else
      deconfigure_slot "$slot"
      remove_managed_address "$slot" "$cidr"
    fi
    return 1
  fi

  ACTIVE_CIDRS[$slot]=$cidr
  ACTIVE_GATEWAYS[$slot]=$gateway
  if [ -n "$old_cidr" ] && [ "$old_cidr" != "$cidr" ]; then
    remove_managed_address "$slot" "$old_cidr"
  fi
  log "slot $slot ready: $cidr via $gateway, socks=$(slot_port "$slot"), mtu=$MTU"
}

reconcile_runtime() {
  local lease slot cidr gateway pid misses

  for ((lease = 0; lease < ${#LEASE_CIDR[@]}; lease++)); do
    slot=${LEASE_SLOT[$lease]:-}
    [ -n "$slot" ] || continue
    cidr=${SLOT_CIDR[$slot]}
    gateway=${SLOT_GATEWAY[$slot]}
    pid=${SOCKD_PIDS[$slot]:-}

    if [ "${ACTIVE_CIDRS[$slot]:-}" != "$cidr" ] ||
      [ "${ACTIVE_GATEWAYS[$slot]:-}" != "$gateway" ] ||
      ! lease_is_configured "$slot" "$cidr" "$gateway"; then
      activate_slot "$slot" "$cidr" "$gateway" || true
    elif [ -z "$pid" ] || ! sockd_is_running "$slot"; then
      if start_sockd "$slot" "$cidr"; then
        log "slot $slot Dante restarted"
      else
        log "slot $slot Dante restart failed"
        deconfigure_slot "$slot"
      fi
    fi
  done

  for ((slot = 0; slot < MAX_LEASES; slot++)); do
    [ -n "${SLOT_CIDR[$slot]:-}" ] || continue
    [ -z "${SLOT_PRESENT[$slot]:-}" ] || continue
    misses=${SLOT_MISSES[$slot]:-0}
    if [ "$misses" -ge "$MISSING_GRACE" ]; then
      log "slot $slot lease missing for $misses refreshes; disabling"
      [ -z "${ACTIVE_CIDRS[$slot]:-}" ] || deconfigure_slot "$slot"
    elif [ -z "${ACTIVE_CIDRS[$slot]:-}" ]; then
      cidr=${SLOT_CIDR[$slot]}
      gateway=${SLOT_GATEWAY[$slot]}
      if activate_slot "$slot" "$cidr" "$gateway"; then
        log "slot $slot restored from persistent state during missing grace"
      else
        log "slot $slot could not be restored during missing grace"
      fi
    else
      log "slot $slot lease temporarily missing ($misses/$MISSING_GRACE); keeping it"
    fi
  done
}

write_active_state() {
  local records temporary slot pid port table
  records=$(mktemp "$RUNTIME_DIR/.active.records.XXXXXX") || return 1
  temporary=$(mktemp "$RUNTIME_DIR/.active.json.XXXXXX") || {
    rm -f "$records"
    return 1
  }

  for slot in "${!ACTIVE_CIDRS[@]}"; do
    pid=${SOCKD_PIDS[$slot]:-}
    if [ -z "$pid" ] || ! sockd_is_running "$slot"; then
      continue
    fi
    port=$(slot_port "$slot")
    table=$(slot_table "$slot")
    jq -nc \
      --argjson slot "$slot" \
      --argjson socks_port "$port" \
      --argjson route_table "$table" \
      --argjson pid "$pid" \
      --arg ipv6_cidr "${ACTIVE_CIDRS[$slot]}" \
      --arg gateway "${ACTIVE_GATEWAYS[$slot]}" \
      --arg wg_interface "${SLOT_WG[$slot]:-}" \
      --argjson missing_count "${SLOT_MISSES[$slot]:-0}" \
      '{slot:$slot, socks_port:$socks_port, route_table:$route_table,
        pid:$pid, ipv6_cidr:$ipv6_cidr, gateway:$gateway,
        wg_interface:$wg_interface, missing_count:$missing_count}' >> "$records" || {
      rm -f "$records" "$temporary"
      return 1
    }
  done

  jq -s 'sort_by(.slot) | {version:1, slots:.}' "$records" > "$temporary" || {
    rm -f "$records" "$temporary"
    return 1
  }
  chmod 0600 "$temporary"
  mv "$temporary" "$ACTIVE_FILE"
  rm -f "$records"
}

validate_environment() {
  local command
  for command in curl ip jq sockd ss; do
    command -v "$command" >/dev/null 2>&1 || fatal "missing command: $command"
  done

  valid_positive_integer "$MAX_LEASES" || fatal 'AETHERCLOUD_MAX_LEASES must be a positive integer'
  valid_positive_integer "$MISSING_GRACE" || fatal 'AETHERCLOUD_MISSING_GRACE must be a positive integer'
  [ "$MAX_LEASES" -le 64 ] || fatal 'AETHERCLOUD_MAX_LEASES must not exceed 64'
  [ $((BASE_SOCKS_PORT + MAX_LEASES - 1)) -le 65535 ] || fatal 'SOCKS port range is invalid'

  [ -n "${SOCKS_USERNAME:-}" ] || fatal 'SOCKS_USERNAME is required'
  [ -n "${SOCKS_PASSWORD:-}" ] || fatal 'SOCKS_PASSWORD is required'
  case "$SOCKS_USERNAME" in
    *[!a-zA-Z0-9_-]*|'') fatal 'SOCKS_USERNAME contains unsupported characters' ;;
  esac
}

initialize_user() {
  if id "$SOCKS_USERNAME" >/dev/null 2>&1; then
    printf '%s:%s\n' "$SOCKS_USERNAME" "$SOCKS_PASSWORD" | chpasswd
  else
    adduser -D -H -s /sbin/nologin "$SOCKS_USERNAME"
    printf '%s:%s\n' "$SOCKS_USERNAME" "$SOCKS_PASSWORD" | chpasswd
  fi
}

detect_vm_uuid() {
  VM_UUID=${DYNAMICV6_VM_UUID:-}
  if [ -z "$VM_UUID" ] && [ -r /sys/class/dmi/id/product_uuid ]; then
    VM_UUID=$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_uuid | tr -d '[:space:]')
  fi
  [ -n "$VM_UUID" ] || fatal 'unable to detect VM UUID'
}

main() {
  local result leases action
  validate_environment
  detect_vm_uuid
  initialize_user

  mkdir -p "$RUNTIME_DIR" "$RUNTIME_DIR/slots" "$DATA_DIR"
  chmod 0700 "$RUNTIME_DIR" "$DATA_DIR"
  load_slots
  wait_for_wan

  while true; do
    if result=$(read_leases); then
      leases=$(jq -c '.leases' <<< "$result")
      action=$(jq -r '.action' <<< "$result")
      load_current_leases "$leases"
      assign_slots
      reconcile_runtime
      save_slots || log 'failed to persist lease slots'
      write_active_state || log 'failed to publish active lease state'
      log "lease refresh complete: count=${#LEASE_CIDR[@]}, api=$action"
    else
      log 'lease refresh failed; keeping the current configuration'
      write_active_state || true
      if [ "${#ACTIVE_CIDRS[@]}" -eq 0 ]; then
        sleep 10
        continue
      fi
    fi

    sleep "$POLL_INTERVAL" &
    wait $! || exit 0
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
