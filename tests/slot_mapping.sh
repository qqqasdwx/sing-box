#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../aethercloud-agent.sh
. "$SCRIPT_DIR/../aethercloud-agent.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local expected=$1 actual=$2 message=$3
  [ "$expected" = "$actual" ] ||
    fail "$message (expected=$expected actual=$actual)"
}

reset_slot_state() {
  SLOT_WG=()
  SLOT_PREFIX=()
  SLOT_CIDR=()
  SLOT_GATEWAY=()
  SLOT_MISSES=()
  SLOT_PRESENT=()
  LEASE_WG=()
  LEASE_PREFIX=()
  LEASE_CIDR=()
  LEASE_GATEWAY=()
  LEASE_SLOT=()
  CLAIMED_SLOTS=()
}

lease() {
  jq -nc \
    --arg wg "$1" \
    --arg prefix "$2" \
    --arg cidr "$3" \
    --arg gateway "$4" \
    '{wg_interface:$wg, prefix:$prefix, ipv6_cidr:$cidr, gateway:$gateway}'
}

leases_json() {
  jq -sc '.'
}

wg0=$(lease wg0 '2600:1700:1:a::/80' '2600:1700:1:a::10/128' '2600:1700:1:a::3')
wg1=$(lease wg1 '2600:1700:2:a::/80' '2600:1700:2:a::20/128' '2600:1700:2:a::3')

normalized=$(normalize_leases <<EOF
{"leases":[$wg1,$wg0,$wg1]}
EOF
)
assert_equal '2' "$(jq 'length' <<< "$normalized")" 'normalization should deduplicate leases'
assert_equal 'wg0' "$(jq -r '.[0].wg_interface' <<< "$normalized")" 'normalization should sort leases'

synthesized=$(normalize_leases <<'EOF'
{"lease":{"wg_interface":"wg2","prefix":"2600:1700:3:a::/80","ipv6_cidr":"2600:1700:3:a::30/128","gateway":null}}
EOF
)
assert_equal '2600:1700:3:a::3' "$(jq -r '.[0].gateway' <<< "$synthesized")" \
  'a missing gateway should be synthesized from an /80 prefix'

reset_slot_state
load_current_leases "$normalized"
assign_slots
assert_equal '0' "${LEASE_SLOT[0]}" 'first normalized lease should use slot 0'
assert_equal '1' "${LEASE_SLOT[1]}" 'second normalized lease should use slot 1'

reordered=$(printf '%s\n%s\n' "$wg1" "$wg0" | leases_json)
load_current_leases "$reordered"
assign_slots
assert_equal '1' "${LEASE_SLOT[0]}" 'API reordering must not change wg1 slot'
assert_equal '0' "${LEASE_SLOT[1]}" 'API reordering must not change wg0 slot'

wg1_rotated=$(lease wg1 '2600:1700:2:a::/80' '2600:1700:2:a::99/128' '2600:1700:2:a::3')
rotated=$(printf '%s\n%s\n' "$wg0" "$wg1_rotated" | leases_json)
load_current_leases "$rotated"
assign_slots
assert_equal '1' "${LEASE_SLOT[1]}" 'an address rotation must preserve its slot'
assert_equal '2600:1700:2:a::99/128' "${SLOT_CIDR[1]}" 'rotated address should replace slot address'

only_wg0=$(printf '%s\n' "$wg0" | leases_json)
for expected_misses in 1 2 3; do
  load_current_leases "$only_wg0"
  assign_slots
  assert_equal "$expected_misses" "${SLOT_MISSES[1]}" 'missing count should increase'
done

load_current_leases "$rotated"
assign_slots
assert_equal '1' "${LEASE_SLOT[1]}" 'a returning lease must reclaim its old slot'
assert_equal '0' "${SLOT_MISSES[1]}" 'a returning lease should clear missing count'

replacement=$(lease wg9 '2600:1700:9:a::/80' '2600:1700:9:a::90/128' '2600:1700:9:a::3')
replacement_set=$(printf '%s\n%s\n' "$wg0" "$replacement" | leases_json)
load_current_leases "$replacement_set"
assign_slots
assert_equal '1' "${LEASE_SLOT[1]}" 'one unmatched replacement should inherit the recent missing slot'

third=$(lease wg10 '2600:1700:10:a::/80' '2600:1700:10:a::10/128' '2600:1700:10:a::3')
expanded=$(printf '%s\n%s\n%s\n' "$wg0" "$replacement" "$third" | leases_json)
load_current_leases "$expanded"
assign_slots
assert_equal '2' "${LEASE_SLOT[2]}" 'a new lease should receive the next free slot'

if normalize_leases <<'EOF' >/dev/null 2>&1
{"leases":[{"wg_interface":"wg0","prefix":"bad","ipv6_cidr":"2600::1/128"}]}
EOF
then
  fail 'a lease without a usable gateway should be rejected'
fi

activate_slot() {
  ACTIVE_CIDRS[$1]=$2
  ACTIVE_GATEWAYS[$1]=$3
}

deconfigure_slot() {
  unset 'ACTIVE_CIDRS[$1]' 'ACTIVE_GATEWAYS[$1]'
}

reset_slot_state
SLOT_WG[0]=wg0
SLOT_PREFIX[0]='2600:1700:1:a::/80'
SLOT_CIDR[0]='2600:1700:1:a::10/128'
SLOT_GATEWAY[0]='2600:1700:1:a::3'
SLOT_MISSES[0]=1
ACTIVE_CIDRS=()
ACTIVE_GATEWAYS=()
reconcile_runtime
assert_equal '2600:1700:1:a::10/128' "${ACTIVE_CIDRS[0]}" \
  'a missing lease should be restored from persistent state during grace'

SLOT_MISSES[0]=$MISSING_GRACE
reconcile_runtime
assert_equal '' "${ACTIVE_CIDRS[0]:-}" \
  'a missing lease should be disabled after the grace limit'

printf 'slot mapping tests passed\n'
