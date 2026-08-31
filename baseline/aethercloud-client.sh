#!/usr/bin/env bash
set -euo pipefail

API_BASE="${DYNAMICV6_API_BASE:-https://aethercloud.io/api/dynamicv6/vm}"
IFACE=""
VM_UUID="${DYNAMICV6_VM_UUID:-}"
CURL_CONNECT_TIMEOUT="${DYNAMICV6_CONNECT_TIMEOUT:-6}"
CURL_MAX_TIME="${DYNAMICV6_MAX_TIME:-20}"
CURL_RETRY="${DYNAMICV6_RETRY:-2}"
VERBOSE="${DYNAMICV6_VERBOSE:-0}"
SELECT_MODE="${DYNAMICV6_SELECT_MODE:-auto}" # auto|prompt|all|first
AUTO_TIMER="${DYNAMICV6_AUTO_TIMER:-1}"
CLIENT_BIN_PATH="${DYNAMICV6_CLIENT_BIN_PATH:-/usr/local/bin/dynamicv6-client.sh}"
SCRIPT_URL="https://aethercloud.io/dynamicv6/client.sh"
PREFERRED_HOST="${DYNAMICV6_PREFERRED_HOST:-}"
DNS_SERVERS_RAW="${DYNAMICV6_DNS_SERVERS:-}"
ROUTE_POLICY="${DYNAMICV6_ROUTE_POLICY:-add}" # add|preserve|replace
POLICY_RULE_PREF_BASE="${DYNAMICV6_POLICY_RULE_PREF_BASE:-16000}"
POLICY_TABLE_BASE="${DYNAMICV6_POLICY_TABLE_BASE:-16000}"
STATE_DIR="${DYNAMICV6_STATE_DIR:-/var/lib/dynamicv6}"

if [[ "${1:-}" == "--persist" || "${1:-}" == "--run" ]]; then
  IFACE="${2:-}"
else
  IFACE="${1:-}"
fi

log() {
  if [[ "$VERBOSE" == "1" ]]; then
    echo "[dynamicv6] $*"
  fi
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

detect_iface() {
  local iface

  iface="$(ip -o route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
  if [[ -n "$iface" ]]; then
    echo "${iface%%@*}"
    return 0
  fi

  iface="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -n "$iface" ]]; then
    echo "${iface%%@*}"
    return 0
  fi

  iface="$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}' || true)"
  if [[ -n "$iface" ]]; then
    echo "${iface%%@*}"
    return 0
  fi

  return 1
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$EUID" -ne 0 ]]; then
    echo "missing command: jq (run as root to auto-install, or install jq manually)" >&2
    return 1
  fi

  echo "[dynamicv6] jq not found, trying to install..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y jq >/dev/null 2>&1 || apt-get install -y --no-install-recommends jq >/dev/null 2>&1 || return 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y jq >/dev/null 2>&1 || return 1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y jq >/dev/null 2>&1 || return 1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq >/dev/null 2>&1 || return 1
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install jq >/dev/null 2>&1 || return 1
  else
    return 1
  fi

  command -v jq >/dev/null 2>&1
}

ensure_python3() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$EUID" -ne 0 ]]; then
    echo "missing command: python3 (run as root to auto-install, or install python3 manually)" >&2
    return 1
  fi

  echo "[dynamicv6] python3 not found, trying to install..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y python3-minimal >/dev/null 2>&1 || apt-get install -y --no-install-recommends python3 >/dev/null 2>&1 || return 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 >/dev/null 2>&1 || return 1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 >/dev/null 2>&1 || return 1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 >/dev/null 2>&1 || return 1
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install python3 >/dev/null 2>&1 || return 1
  else
    return 1
  fi

  command -v python3 >/dev/null 2>&1
}

detect_vm_uuid() {
  if [[ -n "$VM_UUID" ]]; then
    echo "$VM_UUID"
    return
  fi

  if [[ -r /sys/class/dmi/id/product_uuid ]]; then
    local u
    u="$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_uuid | tr -d '[:space:]')"
    if [[ -n "$u" ]]; then
      echo "$u"
      return
    fi
  fi

  if command -v dmidecode >/dev/null 2>&1; then
    local u
    if command -v timeout >/dev/null 2>&1; then
      u="$(timeout 3s dmidecode -s system-uuid 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    else
      u="$(dmidecode -s system-uuid 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    fi
    if [[ -n "$u" && "$u" != "notsettable" ]]; then
      echo "$u"
      return
    fi
  fi

  return 1
}

gateway_addr_for_prefix() {
  local prefix="$1"
  python3 - "$prefix" <<'PY'
from ipaddress import IPv6Network, IPv6Address
import sys

prefix = (sys.argv[1] or "").strip()
if not prefix:
    raise SystemExit(1)

net = IPv6Network(prefix, strict=False)
if net.prefixlen != 80:
    raise SystemExit(1)

addr = IPv6Address(int(net.network_address) + 3)
print(str(addr))
PY
}

synthesize_cidr_gateway_pairs() {
  local -n cidr_prefix_pairs_ref=$1
  local -n out_pairs_ref=$2
  out_pairs_ref=()

  local pair cidr prefix gw
  for pair in "${cidr_prefix_pairs_ref[@]}"; do
    cidr="${pair%%|*}"
    prefix="${pair#*|}"
    [[ -z "$cidr" || -z "$prefix" ]] && continue
    gw="$(gateway_addr_for_prefix "$prefix" 2>/dev/null || true)"
    [[ -z "$gw" ]] && continue
    out_pairs_ref+=("${cidr}|${gw}")
  done
}

need_cmd curl
if ! ensure_jq; then
  echo "failed to install jq automatically, please install jq and re-run." >&2
  exit 1
fi
if ! ensure_python3; then
  echo "failed to install python3 automatically, please install python3 and re-run." >&2
  exit 1
fi
need_cmd ip

if [[ -z "$IFACE" ]]; then
  IFACE="$(detect_iface || true)"
fi
if [[ -z "$IFACE" ]]; then
  echo "unable to detect network interface, please pass it explicitly (e.g. eth0/ens3)" >&2
  exit 1
fi

dns_servers=()
parse_dns_servers() {
  dns_servers=()
  local raw="${DNS_SERVERS_RAW//,/ }"
  local item
  for item in $raw; do
    item="$(echo "$item" | xargs)"
    [[ -z "$item" ]] && continue
    dns_servers+=("$item")
  done
}

persist_netplan() {
  local primary_gw="$1"
  shift
  local cidrs_json="$1"
  shift
  local gateways_json="$1"
  shift
  local pairs_json="$1"
  shift
  local native_default_gateway="${1:-}"
  shift || true
  local native_default_metric="${1:-1024}"
  shift || true
  local native_default_src="${1:-}"
  shift || true
  local native_default_onlink="${1:-0}"
  shift || true
  local cidrs=()
  local gateways=()
  local cidr_gateway_pairs=()
  local file="/etc/netplan/99-dynamicv6.yaml"
  local err_file

  if [[ "$EUID" -ne 0 ]]; then
    echo "persist mode requires root" >&2
    return 1
  fi
  if ! command -v netplan >/dev/null 2>&1; then
    echo "netplan not found, skip persistent write" >&2
    return 1
  fi

  mapfile -t cidrs < <(printf '%s' "$cidrs_json" | jq -r '.[]?')
  mapfile -t gateways < <(printf '%s' "$gateways_json" | jq -r '.[]?')
  mapfile -t cidr_gateway_pairs < <(printf '%s' "$pairs_json" | jq -r '.[]?')

  if [[ "${#cidrs[@]}" -eq 0 ]]; then
    echo "no ipv6 addresses to persist" >&2
    return 1
  fi

  cat >"$file" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      addresses:
EOF
  for cidr in "${cidrs[@]}"; do
    cat >>"$file" <<EOF
        - ${cidr}
EOF
  done

  # Keep this file private; netplan warns when config is world-readable.
  chmod 600 "$file" >/dev/null 2>&1 || true

  if [[ "${#dns_servers[@]}" -gt 0 ]]; then
    cat >>"$file" <<EOF
      nameservers:
        addresses:
EOF
    local dns
    for dns in "${dns_servers[@]}"; do
      cat >>"$file" <<EOF
          - ${dns}
EOF
    done
  fi

  if [[ "${#gateways[@]}" -gt 0 || "${#cidr_gateway_pairs[@]}" -gt 0 ]]; then
    cat >>"$file" <<EOF
      routes:
EOF

    local metric=2048
    local gw pair cidr table pref

    for gw in "${gateways[@]}"; do
      [[ -z "$gw" ]] && continue
      cat >>"$file" <<EOF
        - to: ${gw}/128
          scope: link
EOF
    done

    if [[ "$ROUTE_POLICY" == "replace" && -n "$primary_gw" ]]; then
      cat >>"$file" <<EOF
        - to: ::/0
          via: ${primary_gw}
          metric: 1024
          on-link: true
EOF
    elif [[ "$ROUTE_POLICY" == "add" || "$ROUTE_POLICY" != "preserve" ]]; then
      if [[ "$ROUTE_POLICY" == "add" && -n "$native_default_gateway" ]]; then
        cat >>"$file" <<EOF
        - to: ::/0
          via: ${native_default_gateway}
          metric: ${native_default_metric:-1024}
EOF
        if [[ "$native_default_onlink" == "1" ]]; then
          cat >>"$file" <<EOF
          on-link: true
EOF
        fi
        if [[ -n "$native_default_src" ]]; then
          cat >>"$file" <<EOF
          from: ${native_default_src}
EOF
        fi
      fi
      for gw in "${gateways[@]}"; do
        [[ -z "$gw" ]] && continue
        cat >>"$file" <<EOF
        - to: ::/0
          via: ${gw}
          metric: ${metric}
          on-link: true
EOF
        metric=$((metric + 1))
      done
    fi

    if [[ "${#cidr_gateway_pairs[@]}" -gt 0 ]]; then
      local idx=0
      for pair in "${cidr_gateway_pairs[@]}"; do
        cidr="${pair%%|*}"
        gw="${pair#*|}"
        [[ -n "$cidr" && -n "$gw" ]] || continue
        table=$((POLICY_TABLE_BASE + idx))
        cat >>"$file" <<EOF
        - to: ${gw}/128
          scope: link
          table: ${table}
        - to: ::/0
          via: ${gw}
          table: ${table}
          on-link: true
EOF
        idx=$((idx + 1))
      done

      cat >>"$file" <<EOF
      routing-policy:
EOF

      idx=0
      for pair in "${cidr_gateway_pairs[@]}"; do
        cidr="${pair%%|*}"
        gw="${pair#*|}"
        [[ -n "$cidr" && -n "$gw" ]] || continue
        table=$((POLICY_TABLE_BASE + idx))
        pref=$((POLICY_RULE_PREF_BASE + idx))
        cat >>"$file" <<EOF
        - from: ${cidr}
          table: ${table}
          priority: ${pref}
EOF
        idx=$((idx + 1))
      done
    fi
  fi

  err_file="$(mktemp /tmp/dynamicv6-netplan.XXXXXX)"
  if ! netplan generate >"$err_file" 2>&1; then
    echo "netplan generate failed: $(cat "$err_file" 2>/dev/null || true)" >&2
    rm -f "$err_file"
    return 1
  fi
  if ! netplan apply >"$err_file" 2>&1; then
    echo "netplan apply failed: $(cat "$err_file" 2>/dev/null || true)" >&2
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"

  log "persistent netplan written: ${file}"
  return 0
}

persist_ifupdown() {
  local primary_gw="$1"
  shift
  local cidrs_json="$1"
  shift
  local gateways_json="$1"
  shift
  local pairs_json="$1"
  shift
  local native_default_gateway="${1:-}"
  shift || true
  local native_default_metric="${1:-1024}"
  shift || true
  local native_default_src="${1:-}"
  shift || true
  local native_default_onlink="${1:-0}"
  shift || true
  local cidrs=()
  local gateways=()
  local cidr_gateway_pairs=()
  local primary="${cidrs[0]:-}"
  local ip_addr="${primary%/*}"
  local prefix_len="${primary#*/}"
  local file="/etc/network/interfaces.d/99-dynamicv6-${IFACE}.cfg"

  if [[ "$EUID" -ne 0 ]]; then
    echo "persist mode requires root" >&2
    return 1
  fi

  mapfile -t cidrs < <(printf '%s' "$cidrs_json" | jq -r '.[]?')
  mapfile -t gateways < <(printf '%s' "$gateways_json" | jq -r '.[]?')
  mapfile -t cidr_gateway_pairs < <(printf '%s' "$pairs_json" | jq -r '.[]?')
  primary="${cidrs[0]:-}"
  ip_addr="${primary%/*}"
  prefix_len="${primary#*/}"

  if [[ "${#cidrs[@]}" -eq 0 || -z "$primary" ]]; then
    echo "no ipv6 addresses to persist" >&2
    return 1
  fi

  mkdir -p /etc/network/interfaces.d
  cat >"$file" <<EOF
auto ${IFACE}
iface ${IFACE} inet6 static
    address ${ip_addr}
    netmask ${prefix_len}
EOF

  if [[ -n "$primary_gw" && "$ROUTE_POLICY" == "replace" ]]; then
    cat >>"$file" <<EOF
    gateway ${primary_gw}
EOF
  fi

  if [[ "${#dns_servers[@]}" -gt 0 ]]; then
    cat >>"$file" <<EOF
    dns-nameservers ${dns_servers[*]}
EOF
  fi

  local extra
  for extra in "${cidrs[@]:1}"; do
    cat >>"$file" <<EOF
    up ip -6 addr add ${extra} dev ${IFACE} || true
    down ip -6 addr del ${extra} dev ${IFACE} || true
EOF
  done

  if [[ -f /etc/network/interfaces ]] && ! grep -Eq '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces; then
    printf '\nsource-directory /etc/network/interfaces.d\n' >>/etc/network/interfaces
  fi

  local gw pair cidr table pref metric
  for gw in "${gateways[@]}"; do
    [[ -n "$gw" ]] || continue
    cat >>"$file" <<EOF
    up ip -6 route replace ${gw}/128 dev ${IFACE} metric 1023 || true
EOF
  done

  if [[ "$ROUTE_POLICY" == "add" || "$ROUTE_POLICY" != "preserve" ]]; then
    if [[ "$ROUTE_POLICY" == "add" && -n "$native_default_gateway" ]]; then
      if [[ -n "$native_default_src" && "$native_default_onlink" == "1" ]]; then
        cat >>"$file" <<EOF
    up ip -6 route replace default via ${native_default_gateway} dev ${IFACE} metric ${native_default_metric:-1024} src ${native_default_src} onlink || true
EOF
      elif [[ -n "$native_default_src" ]]; then
        cat >>"$file" <<EOF
    up ip -6 route replace default via ${native_default_gateway} dev ${IFACE} metric ${native_default_metric:-1024} src ${native_default_src} || true
EOF
      elif [[ "$native_default_onlink" == "1" ]]; then
        cat >>"$file" <<EOF
    up ip -6 route replace default via ${native_default_gateway} dev ${IFACE} metric ${native_default_metric:-1024} onlink || true
EOF
      else
        cat >>"$file" <<EOF
    up ip -6 route replace default via ${native_default_gateway} dev ${IFACE} metric ${native_default_metric:-1024} || true
EOF
      fi
    fi
    metric=2048
    for gw in "${gateways[@]}"; do
      [[ -n "$gw" ]] || continue
      cat >>"$file" <<EOF
    up ip -6 route add default via ${gw} dev ${IFACE} metric ${metric} || true
EOF
      metric=$((metric + 1))
    done
  fi

  local idx=0
  for pair in "${cidr_gateway_pairs[@]}"; do
    cidr="${pair%%|*}"
    gw="${pair#*|}"
    [[ -n "$cidr" && -n "$gw" ]] || continue
    table=$((POLICY_TABLE_BASE + idx))
    pref=$((POLICY_RULE_PREF_BASE + idx))
    cat >>"$file" <<EOF
    up ip -6 route replace ${gw}/128 dev ${IFACE} table ${table} || true
    up ip -6 route replace default via ${gw} dev ${IFACE} table ${table} || true
    up ip -6 rule add pref ${pref} from ${cidr} table ${table} || true
EOF
    idx=$((idx + 1))
  done

  log "persistent ifupdown config written: ${file}"
  return 0
}

persist_rhel_ifcfg() {
  local gw="$1"
  shift
  local cidrs=("$@")
  local primary="${cidrs[0]:-}"
  local file="/etc/sysconfig/network-scripts/ifcfg-${IFACE}"

  if [[ "$EUID" -ne 0 ]]; then
    echo "persist mode requires root" >&2
    return 1
  fi

  if [[ "${#cidrs[@]}" -eq 0 || -z "$primary" ]]; then
    echo "no ipv6 addresses to persist" >&2
    return 1
  fi

  mkdir -p /etc/sysconfig/network-scripts
  touch "$file"

  # Ensure key IPv6 flags exist and are set.
  if grep -q '^IPV6INIT=' "$file"; then
    sed -i 's/^IPV6INIT=.*/IPV6INIT=yes/' "$file"
  else
    echo 'IPV6INIT=yes' >>"$file"
  fi

  if grep -q '^IPV6_AUTOCONF=' "$file"; then
    sed -i 's/^IPV6_AUTOCONF=.*/IPV6_AUTOCONF=yes/' "$file"
  else
    echo 'IPV6_AUTOCONF=yes' >>"$file"
  fi

  if grep -q '^IPV6ADDR=' "$file"; then
    sed -i "s|^IPV6ADDR=.*|IPV6ADDR=${primary}|" "$file"
  else
    echo "IPV6ADDR=${primary}" >>"$file"
  fi

  if (( ${#cidrs[@]} > 1 )); then
    local secondaries
    secondaries="$(printf '%s ' "${cidrs[@]:1}")"
    secondaries="${secondaries% }"
    if grep -q '^IPV6ADDR_SECONDARIES=' "$file"; then
      sed -i "s|^IPV6ADDR_SECONDARIES=.*|IPV6ADDR_SECONDARIES=\"${secondaries}\"|" "$file"
    else
      echo "IPV6ADDR_SECONDARIES=\"${secondaries}\"" >>"$file"
    fi
  fi

  # Keep existing default route from host system; do not force gateway here.
  if [[ -n "$gw" ]]; then
    :
  fi

  # Optional DNS entries (IPv6-compatible). Keep only first two to match ifcfg style.
  if (( ${#dns_servers[@]} > 0 )); then
    if grep -q '^DNS1=' "$file"; then
      sed -i "s|^DNS1=.*|DNS1=${dns_servers[0]}|" "$file"
    else
      echo "DNS1=${dns_servers[0]}" >>"$file"
    fi
  fi
  if (( ${#dns_servers[@]} > 1 )); then
    if grep -q '^DNS2=' "$file"; then
      sed -i "s|^DNS2=.*|DNS2=${dns_servers[1]}|" "$file"
    else
      echo "DNS2=${dns_servers[1]}" >>"$file"
    fi
  fi

  if command -v nmcli >/dev/null 2>&1; then
    nmcli connection reload >/dev/null 2>&1 || true
  fi

  log "persistent rhel ifcfg written: ${file}"
  return 0
}

apply_runtime_dns() {
  if [[ "${#dns_servers[@]}" -eq 0 ]]; then
    return 0
  fi

  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl dns "$IFACE" "${dns_servers[@]}" >/dev/null 2>&1 || true
    resolvectl domain "$IFACE" "~." >/dev/null 2>&1 || true
    return 0
  fi

  local resolv_conf="/etc/resolv.conf"
  local mode=""
  local changed_mode=0
  local had_immutable=0

  if [[ ! -e "$resolv_conf" ]]; then
    return 0
  fi

  if [[ "$EUID" -eq 0 ]] && command -v lsattr >/dev/null 2>&1 && command -v chattr >/dev/null 2>&1; then
    if lsattr "$resolv_conf" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
      chattr -i "$resolv_conf" 2>/dev/null || true
      if ! lsattr "$resolv_conf" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
        had_immutable=1
      fi
    fi
  fi

  if [[ ! -w "$resolv_conf" ]]; then
    if [[ "$EUID" -eq 0 ]]; then
      mode="$(stat -c '%a' "$resolv_conf" 2>/dev/null || true)"
      if [[ -n "$mode" ]]; then
        chmod u+w "$resolv_conf" 2>/dev/null || true
        if [[ -w "$resolv_conf" ]]; then
          changed_mode=1
        fi
      fi
    fi
  fi

  if [[ -w "$resolv_conf" ]]; then
    local dns
    for dns in "${dns_servers[@]}"; do
      grep -Eq "^[[:space:]]*nameserver[[:space:]]+${dns//:/\\:}([[:space:]]|\$)" "$resolv_conf" 2>/dev/null && continue
      printf 'nameserver %s\n' "$dns" >>"$resolv_conf"
    done
  else
    echo "[dynamicv6] unable to update /etc/resolv.conf; file is not writable" >&2
  fi

  if [[ "$changed_mode" -eq 1 && -n "$mode" ]]; then
    chmod "$mode" "$resolv_conf" 2>/dev/null || true
  fi

  if [[ "$had_immutable" -eq 1 ]] && command -v chattr >/dev/null 2>&1; then
    chattr +i "$resolv_conf" 2>/dev/null || true
  fi
}

get_native_ipv6_source() {
  local native_cidr
  native_cidr="$(ip -6 -o addr show dev "$IFACE" scope global | awk '{print $4}' | grep -v '/128$' | head -n1 || true)"
  if [[ -z "$native_cidr" ]]; then
    return 0
  fi
  echo "${native_cidr%/*}"
}

detect_native_default_from_netplan() {
  local file gateway route_gateway onlink

  for file in /etc/netplan/*.yaml; do
    [[ -f "$file" ]] || continue
    [[ "$file" == "/etc/netplan/99-dynamicv6.yaml" ]] && continue

    gateway="$(awk '/^[[:space:]]*gateway6:[[:space:]]*/ {print $2; exit}' "$file" 2>/dev/null || true)"
    if [[ -n "$gateway" ]]; then
      echo "${gateway}|1024|$(get_native_ipv6_source)|1"
      return 0
    fi

    route_gateway="$(awk '
      /^[[:space:]]*-[[:space:]]*to:[[:space:]]*::\/0([[:space:]]|$)/ {want_via=1; next}
      want_via && /^[[:space:]]*via:[[:space:]]*/ {print $2; exit}
    ' "$file" 2>/dev/null || true)"
    if [[ -n "$route_gateway" ]]; then
      onlink="$(awk '
        /^[[:space:]]*-[[:space:]]*to:[[:space:]]*::\/0([[:space:]]|$)/ {want=1; next}
        want && /^[[:space:]]*on-link:[[:space:]]*true([[:space:]]|$)/ {print "1"; exit}
      ' "$file" 2>/dev/null || true)"
      echo "${route_gateway}|1024|$(get_native_ipv6_source)|${onlink:-0}"
      return 0
    fi
  done

  return 1
}

detect_native_default_from_ifupdown() {
  local file gateway

  for file in /etc/network/interfaces /etc/network/interfaces.d/*; do
    [[ -f "$file" ]] || continue
    [[ "$file" == "/etc/network/interfaces.d/99-dynamicv6-${IFACE}.cfg" ]] && continue
    gateway="$(awk '
      /^[[:space:]]*iface[[:space:]]+[^[:space:]]+[[:space:]]+inet6[[:space:]]+static/ {in_v6=1; next}
      in_v6 && /^[[:space:]]*gateway[[:space:]]+/ {print $2; exit}
      in_v6 && /^[^[:space:]]/ {in_v6=0}
    ' "$file" 2>/dev/null || true)"
    if [[ -n "$gateway" ]]; then
      echo "${gateway}|1024|$(get_native_ipv6_source)|1"
      return 0
    fi
  done

  return 1
}

detect_native_default_from_ifcfg() {
  local file gateway

  for file in /etc/sysconfig/network-scripts/ifcfg-*; do
    [[ -f "$file" ]] || continue
    gateway="$(sed -n 's/^IPV6_DEFAULTGW=//p' "$file" | head -n1 || true)"
    if [[ -n "$gateway" ]]; then
      gateway="${gateway%\"}"
      gateway="${gateway#\"}"
      echo "${gateway}|1024|$(get_native_ipv6_source)|1"
      return 0
    fi
  done

  return 1
}

detect_native_default_from_system_config() {
  detect_native_default_from_netplan && return 0
  detect_native_default_from_ifupdown && return 0
  detect_native_default_from_ifcfg && return 0
  return 1
}

detect_native_main_default_route() {
  local -n route_gateways_ref=$1
  local line via metric src onlink config_record

  config_record="$(detect_native_default_from_system_config || true)"
  if [[ -n "$config_record" ]]; then
    echo "$config_record"
    return 0
  fi

  while read -r line; do
    [[ -z "$line" ]] && continue
    via="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1)}}')"
    metric="$(echo "$line" | sed -n 's/.* metric \([0-9]\+\).*/\1/p')"
    src="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1)}}')"
    onlink="0"
    if echo "$line" | grep -qw onlink; then
      onlink="1"
    fi

    [[ -n "$via" ]] || continue
    if array_contains "$via" "${route_gateways_ref[@]}"; then
      continue
    fi
    if [[ -n "$metric" ]] && (( metric >= 2048 )); then
      continue
    fi

    echo "${via}|${metric:-1024}|${src}|${onlink}"
    return 0
  done < <(ip -6 route show default dev "$IFACE")

  return 1
}

pin_main_default_route_source() {
  local native_src="$1"
  [[ -z "$native_src" ]] && return 0

  while read -r line; do
    [[ -z "$line" ]] && continue

    local via metric onlink_arg
    via="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1)}}')"
    metric="$(echo "$line" | sed -n 's/.* metric \([0-9]\+\).*/\1/p')"
    onlink_arg=""
    if echo "$line" | grep -qw onlink; then
      onlink_arg="onlink"
    fi

    [[ -n "$via" ]] || continue
    if [[ -n "$metric" ]] && (( metric >= 2048 )); then
      continue
    fi

    if [[ -n "$metric" ]]; then
      ip -6 route replace default via "$via" dev "$IFACE" metric "$metric" src "$native_src" $onlink_arg >/dev/null 2>&1 || true
    else
      ip -6 route replace default via "$via" dev "$IFACE" src "$native_src" $onlink_arg >/dev/null 2>&1 || true
    fi
  done < <(ip -6 route show default dev "$IFACE")

  log "main default route source pinned src=$native_src"
}

apply_source_policy_routes() {
  local -n selected_cidrs_ref=$1
  local -n cidr_gateway_pairs_ref=$2

  if [[ "${#selected_cidrs_ref[@]}" -eq 0 || "${#cidr_gateway_pairs_ref[@]}" -eq 0 ]]; then
    return 0
  fi

  local pref_base table_base
  pref_base="$POLICY_RULE_PREF_BASE"
  table_base="$POLICY_TABLE_BASE"
  if ! [[ "$pref_base" =~ ^[0-9]+$ ]]; then
    pref_base=16000
  fi
  if ! [[ "$table_base" =~ ^[0-9]+$ ]]; then
    table_base=16000
  fi

  # Cleanup stale DynamicV6 policy rules/tables from previous runs.
  local i pref table
  for i in $(seq 0 127); do
    pref=$((pref_base + i))
    table=$((table_base + i))
    ip -6 rule del pref "$pref" >/dev/null 2>&1 || true
    ip -6 route flush table "$table" >/dev/null 2>&1 || true
  done

  local idx=0 pair cidr gw
  local -A selected_cidrs_map=()
  for cidr in "${selected_cidrs_ref[@]}"; do
    selected_cidrs_map["$cidr"]=1
  done

  for pair in "${cidr_gateway_pairs_ref[@]}"; do
    cidr="${pair%%|*}"
    gw="${pair#*|}"
    [[ -z "$cidr" || -z "$gw" ]] && continue
    [[ -n "${selected_cidrs_map[$cidr]:-}" ]] || continue
    (( idx < 128 )) || break

    pref=$((pref_base + idx))
    table=$((table_base + idx))

    ip -6 route replace "${gw}/128" dev "$IFACE" table "$table" || true
    ip -6 route replace default via "$gw" dev "$IFACE" onlink table "$table" || true
    ip -6 rule add pref "$pref" from "$cidr" table "$table" >/dev/null 2>&1 || true
    idx=$((idx + 1))
  done

  if (( idx > 0 )); then
    log "source policy routes enabled count=$idx pref_base=$pref_base table_base=$table_base"
  fi
}

verify_and_repair_dynamicv6_routes() {
  local -n current_gateways_ref=$1
  local -n current_cidr_gateway_pairs_ref=$2

  if [[ "${#current_gateways_ref[@]}" -eq 0 ]]; then
    return 0
  fi

  local primary_gw="${current_gateways_ref[0]}"
  local gw expected_metric table pref pair cidr

  for gw in "${current_gateways_ref[@]}"; do
    [[ -n "$gw" ]] || continue
    if ! ip -6 route show dev "$IFACE" metric 1023 | grep -Fq "${gw}/128"; then
      ip -6 route replace "${gw}/128" dev "$IFACE" metric 1023 >/dev/null 2>&1 || true
      log "repaired missing gateway host route iface=$IFACE gw=$gw metric=1023"
    fi
  done

  case "$ROUTE_POLICY" in
    replace)
      if [[ -n "$primary_gw" ]] && ! ip -6 route show default dev "$IFACE" | grep -Fq "default via ${primary_gw} dev ${IFACE} metric 1024"; then
        ip -6 route replace default via "$primary_gw" dev "$IFACE" metric 1024 >/dev/null 2>&1 || true
        log "repaired default route policy=replace iface=$IFACE via=$primary_gw metric=1024"
      fi
      ;;
    add|*)
      if [[ "$ROUTE_POLICY" != "preserve" && -n "${previous_state_native_default_gateway:-}" ]]; then
        local onlink_arg=""
        if [[ "${previous_state_native_default_onlink:-0}" == "1" ]]; then
          onlink_arg="onlink"
        fi

        if ! ip -6 route show default dev "$IFACE" | grep -Fq "default via ${previous_state_native_default_gateway} dev ${IFACE}"; then
          if [[ -n "${previous_state_native_default_src:-}" ]]; then
            ip -6 route replace default via "${previous_state_native_default_gateway}" dev "$IFACE" metric "${previous_state_native_default_metric:-1024}" src "${previous_state_native_default_src}" $onlink_arg >/dev/null 2>&1 || true
          else
            ip -6 route replace default via "${previous_state_native_default_gateway}" dev "$IFACE" metric "${previous_state_native_default_metric:-1024}" $onlink_arg >/dev/null 2>&1 || true
          fi
          log "repaired native main default route iface=$IFACE via=${previous_state_native_default_gateway} metric=${previous_state_native_default_metric:-1024}"
        fi
      fi

      if [[ "$ROUTE_POLICY" != "preserve" ]]; then
        expected_metric=2048
        for gw in "${current_gateways_ref[@]}"; do
          [[ -n "$gw" ]] || continue
          if ! ip -6 route show default dev "$IFACE" | grep -Fq "default via ${gw} dev ${IFACE} metric ${expected_metric}"; then
            ip -6 route replace default via "$gw" dev "$IFACE" metric "$expected_metric" onlink >/dev/null 2>&1 || true
            log "repaired backup default route iface=$IFACE via=$gw metric=$expected_metric"
          fi
          expected_metric=$((expected_metric + 1))
        done
      fi
      ;;
  esac

  local idx=0
  for pair in "${current_cidr_gateway_pairs_ref[@]}"; do
    cidr="${pair%%|*}"
    gw="${pair#*|}"
    [[ -n "$cidr" && -n "$gw" ]] || continue
    table=$((POLICY_TABLE_BASE + idx))
    pref=$((POLICY_RULE_PREF_BASE + idx))

    if ! ip -6 route show table "$table" | grep -Fq "${gw}/128 dev ${IFACE}"; then
      ip -6 route replace "${gw}/128" dev "$IFACE" table "$table" >/dev/null 2>&1 || true
      log "repaired policy gateway route iface=$IFACE table=$table gw=$gw"
    fi

    if ! ip -6 route show table "$table" | grep -Fq "default via ${gw} dev ${IFACE}"; then
      ip -6 route replace default via "$gw" dev "$IFACE" onlink table "$table" >/dev/null 2>&1 || true
      log "repaired policy default route iface=$IFACE table=$table gw=$gw"
    fi

    if ! ip -6 rule show | grep -Fq "from ${cidr} lookup ${table}"; then
      ip -6 rule add pref "$pref" from "$cidr" table "$table" >/dev/null 2>&1 || true
      log "repaired policy rule iface=$IFACE from=$cidr table=$table pref=$pref"
    fi

    idx=$((idx + 1))
  done
}

state_file_path() {
  echo "${STATE_DIR%/}/client-${IFACE}.state"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR" >/dev/null 2>&1 || return 1
}

load_previous_state() {
  local state_file
  state_file="$(state_file_path)"
  previous_state_ipv6_cidrs=()
  previous_state_gateways=()
  previous_state_selected_ipv6_cidrs=()
  previous_state_native_default_gateway=""
  previous_state_native_default_src=""
  previous_state_native_default_metric=""
  previous_state_native_default_onlink="0"

  if [[ ! -f "$state_file" ]]; then
    return 0
  fi

  mapfile -t previous_state_ipv6_cidrs < <(jq -r '.ipv6_cidrs[]? | select(type == "string" and length > 0)' "$state_file" 2>/dev/null || true)
  mapfile -t previous_state_gateways < <(jq -r '.gateways[]? | select(type == "string" and length > 0)' "$state_file" 2>/dev/null || true)
  mapfile -t previous_state_selected_ipv6_cidrs < <(jq -r '.selected_ipv6_cidrs[]? | select(type == "string" and length > 0)' "$state_file" 2>/dev/null || true)
  previous_state_native_default_gateway="$(jq -r '.native_default.gateway // empty' "$state_file" 2>/dev/null || true)"
  previous_state_native_default_src="$(jq -r '.native_default.src // empty' "$state_file" 2>/dev/null || true)"
  previous_state_native_default_metric="$(jq -r '.native_default.metric // empty' "$state_file" 2>/dev/null || true)"
  previous_state_native_default_onlink="$(jq -r '.native_default.onlink // 0' "$state_file" 2>/dev/null || true)"
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

normalize_host_route_dest() {
  local dest="$1"
  if [[ "$dest" == */128 ]]; then
    echo "${dest%/128}"
    return 0
  fi
  echo "$dest"
}

cleanup_stale_dynamicv6_runtime() {
  local -n current_cidrs_ref=$1
  local -n current_gateways_ref=$2
  local cidr gw dest stale_gateway_routes gateway_routes_snapshot

  load_previous_state
  gateway_routes_snapshot="$(ip -6 route show dev "$IFACE" metric 1023 | awk '{print $1}' || true)"

  for cidr in "${previous_state_ipv6_cidrs[@]:-}"; do
    [[ -z "$cidr" ]] && continue
    if ! array_contains "$cidr" "${current_cidrs_ref[@]}"; then
      ip -6 addr del "$cidr" dev "$IFACE" >/dev/null 2>&1 || true
      log "removed stale dynamicv6 addr iface=$IFACE cidr=$cidr"
    fi
  done

  for gw in "${previous_state_gateways[@]:-}"; do
    [[ -z "$gw" ]] && continue
    if ! array_contains "$gw" "${current_gateways_ref[@]}"; then
      ip -6 route del "${gw}/128" dev "$IFACE" metric 1023 >/dev/null 2>&1 || true
      ip -6 route del "${gw}/128" dev "$IFACE" >/dev/null 2>&1 || true
      log "removed stale dynamicv6 gateway route iface=$IFACE gw=$gw"
    fi
  done

  # Fallback cleanup: remove legacy gateway reachability routes that may not
  # exist in local state (for example, rules created before state tracking).
  while read -r dest; do
    [[ -z "$dest" ]] && continue
    [[ "$dest" == "default" ]] && continue
    [[ "$dest" == fe80::* ]] && continue
    [[ "$dest" == */128 ]] || continue

    gw="${dest%/128}"
    if ! array_contains "$gw" "${current_gateways_ref[@]}"; then
      ip -6 route del "$dest" dev "$IFACE" metric 1023 >/dev/null 2>&1 || true
      ip -6 route del "$dest" dev "$IFACE" >/dev/null 2>&1 || true
      log "removed legacy dynamicv6 gateway route iface=$IFACE route=$dest"
    fi
  done < <(ip -6 route show dev "$IFACE" metric 1023 | awk '{print $1}')

  # DynamicV6-managed addresses are /128 on this interface.
  # Keep only the currently selected /128s and remove any other global /128s.
  # Native/provider IPv6 on this stack should remain on wider prefixes (for example /64),
  # so this avoids leaving stale DynamicV6 addresses after switching selection.
  while read -r cidr; do
    [[ -z "$cidr" ]] && continue
    [[ "$cidr" == */128 ]] || continue
    if array_contains "$cidr" "${current_cidrs_ref[@]}"; then
      continue
    fi

    ip -6 addr del "$cidr" dev "$IFACE" >/dev/null 2>&1 || true
    log "removed stale dynamicv6 /128 iface=$IFACE cidr=$cidr"
  done < <(ip -6 -o addr show dev "$IFACE" scope global | awk '{print $4}' | grep '/128$' || true)
}

save_current_state() {
  local -n current_cidrs_ref=$1
  local -n current_gateways_ref=$2
  local state_file tmp_file native_default_record native_gw native_metric native_src native_onlink

  if ! ensure_state_dir; then
    log "state dir unavailable: $STATE_DIR"
    return 0
  fi

  state_file="$(state_file_path)"
  tmp_file="${state_file}.new"
  native_default_record="$(detect_native_main_default_route current_gateways_ref || true)"
  native_gw="${native_default_record%%|*}"
  native_metric="$(echo "$native_default_record" | cut -d'|' -f2)"
  native_src="$(echo "$native_default_record" | cut -d'|' -f3)"
  native_onlink="$(echo "$native_default_record" | cut -d'|' -f4)"

  {
    echo '{'
    echo '  "ipv6_cidrs": ['
    local i
    for i in "${!current_cidrs_ref[@]}"; do
      jq -Rn --arg v "${current_cidrs_ref[$i]}" '$v'
      if (( i + 1 < ${#current_cidrs_ref[@]} )); then
        echo ','
      fi
    done
    echo '  ],'
    echo '  "selected_ipv6_cidrs": ['
    for i in "${!current_cidrs_ref[@]}"; do
      jq -Rn --arg v "${current_cidrs_ref[$i]}" '$v'
      if (( i + 1 < ${#current_cidrs_ref[@]} )); then
        echo ','
      fi
    done
    echo '  ],'
    echo '  "gateways": ['
    for i in "${!current_gateways_ref[@]}"; do
      jq -Rn --arg v "${current_gateways_ref[$i]}" '$v'
      if (( i + 1 < ${#current_gateways_ref[@]} )); then
        echo ','
      fi
    done
    echo '  ],'
    echo '  "native_default": {'
    jq -Rn --arg v "$native_gw" '$v' | awk '{print "    \"gateway\": " $0 ","}'
    jq -Rn --arg v "$native_src" '$v' | awk '{print "    \"src\": " $0 ","}'
    jq -Rn --arg v "$native_metric" '$v' | awk '{print "    \"metric\": " $0 ","}'
    jq -Rn --arg v "${native_onlink:-0}" '$v' | awk '{print "    \"onlink\": " $0}'
    echo '  }'
    echo '}'
  } >"$tmp_file"

  mv -f "$tmp_file" "$state_file"
}

persist_network_config() {
  local primary_gw="$1"
  shift
  local -a cidrs=("$@")
  local cidrs_json gateways_json pairs_json native_default_record native_default_gateway native_default_metric native_default_src native_default_onlink

  cidrs_json="$(printf '%s\n' "${cidrs[@]}" | jq -R . | jq -s .)"
  gateways_json="$(printf '%s\n' "${gateways[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')"
  pairs_json="$(printf '%s\n' "${cidr_gateway_pairs[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')"
  native_default_record="$(detect_native_main_default_route gateways || true)"
  native_default_gateway="${native_default_record%%|*}"
  native_default_metric="$(echo "$native_default_record" | cut -d'|' -f2)"
  native_default_src="$(echo "$native_default_record" | cut -d'|' -f3)"
  native_default_onlink="$(echo "$native_default_record" | cut -d'|' -f4)"

  if command -v netplan >/dev/null 2>&1; then
    persist_netplan "$primary_gw" "$cidrs_json" "$gateways_json" "$pairs_json" "$native_default_gateway" "$native_default_metric" "$native_default_src" "${native_default_onlink:-0}"
    return
  fi

  if [[ -f /etc/network/interfaces || -d /etc/network/interfaces.d ]]; then
    persist_ifupdown "$primary_gw" "$cidrs_json" "$gateways_json" "$pairs_json" "$native_default_gateway" "$native_default_metric" "$native_default_src" "${native_default_onlink:-0}"
    return
  fi

  if [[ -d /etc/sysconfig/network-scripts ]]; then
    persist_rhel_ifcfg "$primary_gw" "${cidrs[@]}"
    return
  fi

  echo "no supported persistent network stack found (netplan/ifupdown/network-scripts)" >&2
  return 1
}

ensure_reconcile_timer() {
  if [[ "$AUTO_TIMER" != "1" ]]; then
    echo "[dynamicv6] timer skipped: DYNAMICV6_AUTO_TIMER=0"
    return 0
  fi
  if [[ "$EUID" -ne 0 ]]; then
    echo "[dynamicv6] timer skipped: requires root"
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[dynamicv6] timer skipped: systemd not available"
    return 0
  fi

  local service="/etc/systemd/system/dynamicv6-client.service"
  local timer="/etc/systemd/system/dynamicv6-client.timer"
  local changed=0

  if ! curl -4 -fsSL --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 \
      "$SCRIPT_URL" -o "$CLIENT_BIN_PATH" 2>/dev/null; then
    echo "[dynamicv6] warn: failed to refresh $CLIENT_BIN_PATH from $SCRIPT_URL" >&2
    if [[ ! -x "$CLIENT_BIN_PATH" ]]; then
      echo "[dynamicv6] warn: no cached script at $CLIENT_BIN_PATH, timer not installed" >&2
      return 0
    fi
    echo "[dynamicv6] using cached $CLIENT_BIN_PATH for timer"
  else
    chmod +x "$CLIENT_BIN_PATH"
  fi

  local new_svc
  new_svc="$(cat <<EOF
[Unit]
Description=DynamicV6 VM Reconcile
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CLIENT_BIN_PATH} ${IFACE}
EOF
)"
  if [[ ! -f "$service" ]] || ! diff <(printf '%s\n' "$new_svc") "$service" >/dev/null 2>&1; then
    printf '%s\n' "$new_svc" >"$service"
    changed=1
  fi

  local new_tmr
  new_tmr='[Unit]
Description=Run DynamicV6 VM Reconcile every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=dynamicv6-client.service
Persistent=true

[Install]
WantedBy=timers.target'
  if [[ ! -f "$timer" ]] || ! diff <(printf '%s\n' "$new_tmr") "$timer" >/dev/null 2>&1; then
    printf '%s\n' "$new_tmr" >"$timer"
    changed=1
  fi

  if [[ "$changed" -eq 1 ]]; then
    systemctl daemon-reload
  fi

  if ! systemctl is-active --quiet dynamicv6-client.timer 2>/dev/null; then
    if ! systemctl enable --now dynamicv6-client.timer >/dev/null 2>&1; then
      echo "[dynamicv6] warn: failed to enable dynamicv6-client.timer" >&2
      return 0
    fi
    echo "[dynamicv6] timer installed: dynamicv6-client.timer (every 2 minutes)"
  fi
}

select_ipv6_cidrs() {
  local -n all_pairs_ref=$1
  local -n out_cidrs_ref=$2
  out_cidrs_ref=()

  if [[ "${#all_pairs_ref[@]}" -eq 1 ]]; then
    out_cidrs_ref+=("${all_pairs_ref[0]#*|}")
    return 0
  fi

  if [[ "$SELECT_MODE" == "first" ]]; then
    out_cidrs_ref+=("${all_pairs_ref[0]#*|}")
    return 0
  fi
  if [[ "$SELECT_MODE" == "all" ]]; then
    local p
    for p in "${all_pairs_ref[@]}"; do
      out_cidrs_ref+=("${p#*|}")
    done
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    # Non-interactive shell: always follow the current lease set.
    # This avoids keeping stale selected_ipv6_cidrs after a pool/prefix rotation.
    for p in "${all_pairs_ref[@]}"; do
      out_cidrs_ref+=("${p#*|}")
    done
    return 0
  fi

  echo "Multiple IPv6 leases detected on this host. Select one/all:"
  local idx=1
  local pair
  for pair in "${all_pairs_ref[@]}"; do
    local wg="${pair%%|*}"
    local cidr="${pair#*|}"
    echo "  ${idx}) [${wg}] ${cidr}"
    idx=$((idx + 1))
  done
  echo "  all) apply all IPv6 addresses"
  echo -n "Choice: "

  local choice
  read -r choice
  choice="$(echo "$choice" | xargs)"

  if [[ "$choice" == "all" || "$choice" == "a" || "$choice" == "*" ]]; then
    for pair in "${all_pairs_ref[@]}"; do
      out_cidrs_ref+=("${pair#*|}")
    done
    return 0
  fi

  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    local sel=$((choice - 1))
    if (( sel >= 0 && sel < ${#all_pairs_ref[@]} )); then
      out_cidrs_ref+=("${all_pairs_ref[$sel]#*|}")
      return 0
    fi
  fi

  echo "invalid choice, fallback to all"
  for pair in "${all_pairs_ref[@]}"; do
    out_cidrs_ref+=("${pair#*|}")
  done
  return 0
}

log "detecting vm_uuid..."
parse_dns_servers
VM_UUID="$(detect_vm_uuid || true)"
if [[ -z "$VM_UUID" ]]; then
  echo "unable to detect vm_uuid, set DYNAMICV6_VM_UUID manually" >&2
  exit 1
fi
log "vm_uuid=$VM_UUID iface=$IFACE"

call_api() {
  local method="$1"
  local url="$2"
  local response=""
  local http_code=""
  local body=""
  local payload=""

  if [[ -n "$PREFERRED_HOST" ]]; then
    payload="{\"vm_uuid\":\"$VM_UUID\",\"preferred_host\":\"$PREFERRED_HOST\"}"
  else
    payload="{\"vm_uuid\":\"$VM_UUID\"}"
  fi

  if ! response="$(
    curl -4 --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      --retry "$CURL_RETRY" \
      --retry-delay 1 \
      --retry-connrefused \
      -sS -X "$method" "$url" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      -w $'\n%{http_code}'
  )"; then
    echo "[dynamicv6] request failed: $method $url" >&2
    echo "[dynamicv6] hint: check VM can reach billing over IPv6/IPv4, or set DYNAMICV6_API_BASE to a reachable endpoint" >&2
    return 1
  fi

  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
    echo "[dynamicv6] invalid http status from API: $http_code" >&2
    return 1
  fi

  if (( http_code >= 400 )); then
    echo "[dynamicv6] API error: HTTP $http_code ($method $url)" >&2
    echo "[dynamicv6] vm_uuid=$VM_UUID" >&2
    if echo "$body" | jq -e . >/dev/null 2>&1; then
      echo "$body" | jq -r '.error // .message // .' >&2
      echo "$body" >&2
    else
      echo "$body" >&2
    fi
    return 22
  fi

  echo "$body"
}

log "requesting lease status..."
status_json="$(call_api POST "$API_BASE/status")"
active="$(echo "$status_json" | jq -r '.active')"
leases_json='[]'

if [[ "$active" == "true" ]]; then
  log "active lease found, refreshing..."
  leases_json="$(echo "$status_json" | jq -c '
    def to_arr:
      if . == null then []
      elif (type == "array") then .
      elif (type == "object") then [.]
      else []
      end;
    ((.leases | to_arr) + (.lease | to_arr))
    | map(select(type == "object"))
    | unique_by(.ipv6_cidr // "")
  ')"
else
  log "no active lease, requesting allocation..."
  alloc_json="$(call_api POST "$API_BASE/allocate")"
  leases_json="$(echo "$alloc_json" | jq -c '
    def to_arr:
      if . == null then []
      elif (type == "array") then .
      elif (type == "object") then [.]
      else []
      end;
    ((.leases | to_arr) + (.lease | to_arr))
    | map(select(type == "object"))
    | unique_by(.ipv6_cidr // "")
  ')"
fi

mapfile -t lease_pairs < <(echo "$leases_json" | jq -r '
  def norm:
    if type == "array" then .
    elif type == "object" then [.]
    elif type == "string" then (try fromjson catch [])
    else []
    end;
  norm[]
  | select((.ipv6_cidr? | type) == "string" and (.ipv6_cidr | length > 0))
  | "\(.wg_interface? // "unknown")|\(.ipv6_cidr)"
')
mapfile -t gateways < <(echo "$leases_json" | jq -r '
  def norm:
    if type == "array" then .
    elif type == "object" then [.]
    elif type == "string" then (try fromjson catch [])
    else []
    end;
  [norm[] | .gateway? // empty]
  | map(select(type=="string" and length>0))
  | unique[]
')
mapfile -t cidr_gateway_pairs < <(echo "$leases_json" | jq -r '
  def norm:
    if type == "array" then .
    elif type == "object" then [.]
    elif type == "string" then (try fromjson catch [])
    else []
    end;
  norm[]
  | select((.ipv6_cidr? | type) == "string" and (.ipv6_cidr | length > 0))
  | select((.gateway? | type) == "string" and (.gateway | length > 0))
  | "\(.ipv6_cidr)|\(.gateway)"
')

if [[ "${#dns_servers[@]}" -eq 0 ]]; then
  mapfile -t dns_servers < <(echo "$leases_json" | jq -r '
    def norm:
      if type == "array" then .
      elif type == "object" then [.]
      elif type == "string" then (try fromjson catch [])
      else []
      end;
    [norm[] | .dns_servers? // []]
    | flatten
    | map(select(type == "string" and length > 0))
    | unique[]
  ')
fi

if [[ "${#lease_pairs[@]}" -eq 0 ]]; then
  echo "[dynamicv6] no ipv6 lease returned from API" >&2
  exit 1
fi

lease_mtu="$(echo "$leases_json" | jq -r '[.[] | .mtu? // 0] | map(select(. > 0)) | first // 0')"
mtu_arg=""
if [[ "$lease_mtu" =~ ^[0-9]+$ ]] && (( lease_mtu > 0 )); then
  mtu_arg="mtu $lease_mtu"
  log "lease mtu=$lease_mtu"
fi

load_previous_state
select_ipv6_cidrs lease_pairs ipv6_cidrs

selected_gateways=()
selected_cidr_gateway_pairs=()

for pair in "${cidr_gateway_pairs[@]}"; do
  cidr="${pair%%|*}"
  gw="${pair#*|}"
  if array_contains "$cidr" "${ipv6_cidrs[@]}"; then
    selected_cidr_gateway_pairs+=("$pair")
    if [[ -n "$gw" ]] && ! array_contains "$gw" "${selected_gateways[@]}"; then
      selected_gateways+=("$gw")
    fi
  fi
done

if [[ "${#selected_gateways[@]}" -gt 0 ]]; then
  gateways=("${selected_gateways[@]}")
fi

if [[ "${#selected_cidr_gateway_pairs[@]}" -gt 0 ]]; then
  cidr_gateway_pairs=("${selected_cidr_gateway_pairs[@]}")
fi

mapfile -t lease_cidr_prefix_pairs < <(echo "$leases_json" | jq -r '
  def norm:
    if type == "array" then .
    elif type == "object" then [.]
    elif type == "string" then (try fromjson catch [])
    else []
    end;
  norm[]
  | select((.ipv6_cidr? | type) == "string" and (.ipv6_cidr | length > 0))
  | select((.prefix? | type) == "string" and (.prefix | length > 0))
  | "\(.ipv6_cidr)|\(.prefix)"
')

if [[ "${#cidr_gateway_pairs[@]}" -eq 0 && "${#lease_cidr_prefix_pairs[@]}" -gt 0 ]]; then
  synthesize_cidr_gateway_pairs lease_cidr_prefix_pairs cidr_gateway_pairs
fi

if [[ "${#gateways[@]}" -eq 0 && "${#cidr_gateway_pairs[@]}" -gt 0 ]]; then
  mapfile -t gateways < <(printf '%s\n' "${cidr_gateway_pairs[@]}" | awk -F'|' '!seen[$2]++ {print $2}')
fi

cleanup_stale_dynamicv6_runtime ipv6_cidrs gateways

for ipv6_cidr in "${ipv6_cidrs[@]}"; do
  log "applying ipv6 $ipv6_cidr on $IFACE..."
  ip -6 addr replace "$ipv6_cidr" dev "$IFACE"
done

if [[ "${#gateways[@]}" -gt 0 ]]; then
  native_ipv6_src="$(get_native_ipv6_source || true)"
  primary_gateway="${gateways[0]}"
  log "setting default ipv6 gateways count=${#gateways[@]} primary=$primary_gateway..."

  # Reconcile legacy gateway host routes in main table first.
  # Keep only current API-returned gateways.
  while read -r dest; do
    [[ -z "$dest" ]] && continue
    [[ "$dest" == "default" ]] && continue
    [[ "$dest" == fe80::* ]] && continue
    gw="$(normalize_host_route_dest "$dest")"
    if ! array_contains "$gw" "${gateways[@]}"; then
      ip -6 route del "$dest" dev "$IFACE" metric 1023 >/dev/null 2>&1 || true
      ip -6 route del "$dest" dev "$IFACE" >/dev/null 2>&1 || true
      log "reconciled stale gateway host route iface=$IFACE route=$dest"
    fi
  done < <(ip -6 route show dev "$IFACE" metric 1023 | awk '{print $1}')

  for gw in "${gateways[@]}"; do
    ip -6 route replace "${gw}/128" dev "$IFACE" metric 1023 || true
  done
  case "$ROUTE_POLICY" in
    replace)
      ip -6 route replace default via "$primary_gateway" dev "$IFACE" metric 1024 $mtu_arg
      ;;
    add)
      # Keep existing default route(s), append DynamicV6 backup defaults.
      # Cleanup previous DynamicV6-added backup defaults (metric >= 2048) first.
      # Do not touch metric 1024 defaults here. Native/provider defaults may also
      # use that metric, so automatic cleanup must stay limited to backup routes.
      while read -r line; do
        [[ -z "$line" ]] && continue
        via="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1)}}')"
        metric="$(echo "$line" | sed -n 's/.* metric \([0-9]\+\).*/\1/p')"
        if [[ -n "$via" && -n "$metric" ]] && (( metric >= 2048 )); then
          ip -6 route del default via "$via" dev "$IFACE" metric "$metric" >/dev/null 2>&1 || true
        fi
      done < <(ip -6 route show default dev "$IFACE")

      metric=2048
      for gw in "${gateways[@]}"; do
        ip -6 route add default via "$gw" dev "$IFACE" metric "$metric" $mtu_arg 2>/dev/null || true
        metric=$((metric + 1))
      done
      pin_main_default_route_source "${native_ipv6_src:-}"
      ;;
    preserve)
      log "preserve route policy: keep existing default route unchanged"
      pin_main_default_route_source "${native_ipv6_src:-}"
      ;;
    *)
      metric=2048
      for gw in "${gateways[@]}"; do
        ip -6 route add default via "$gw" dev "$IFACE" metric "$metric" $mtu_arg 2>/dev/null || true
        metric=$((metric + 1))
      done
      ;;
  esac
fi

apply_source_policy_routes ipv6_cidrs cidr_gateway_pairs
verify_and_repair_dynamicv6_routes gateways cidr_gateway_pairs

apply_runtime_dns
save_current_state ipv6_cidrs gateways

_prev_cidrs="$(printf '%s\n' "${previous_state_ipv6_cidrs[@]:-}")"
_curr_cidrs="$(printf '%s\n' "${ipv6_cidrs[@]:-}")"
if [[ "$_prev_cidrs" != "$_curr_cidrs" ]]; then
  persist_network_config "${primary_gateway:-}" "${ipv6_cidrs[@]}" || true
fi
ensure_reconcile_timer || true

echo "DynamicV6 configured"
echo "vm_uuid=$VM_UUID iface=$IFACE ipv6_count=${#ipv6_cidrs[@]}"
printf '%s\n' "${ipv6_cidrs[@]}"
