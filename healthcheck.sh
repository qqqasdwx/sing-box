#!/bin/sh
set -eu

active_file=/run/aethercloud/active-leases.json
persistent_file=/var/lib/aethercloud/leases.json
missing_grace=${AETHERCLOUD_MISSING_GRACE:-3}

test -s "$active_file"
test -s "$persistent_file"
test -s /run/aethercloud/control_interface
test -s /run/aethercloud/wan_interface
wan_interface=$(cat /run/aethercloud/wan_interface)
ip link show dev "$wan_interface" >/dev/null 2>&1
jq -e '.version == 1 and (.slots | type == "array" and length > 0)' \
  "$active_file" >/dev/null
jq -e --slurpfile active "$active_file" --argjson grace "$missing_grace" '
  ([.slots[] | select(.missing_count < $grace) | .slot] | sort) as $expected
  | ([$active[0].slots[].slot] | sort) as $actual
  | ($expected | length) > 0 and $expected == $actual
' "$persistent_file" >/dev/null

jq -r '.slots[] | [.pid, .route_table, .socks_port, (.ipv6_cidr | split("/")[0])] | @tsv' \
  "$active_file" |
  while IFS="$(printf '\t')" read -r pid route_table socks_port source; do
    kill -0 "$pid"
    ss -H -lnt "sport = :$socks_port" | grep -q LISTEN
    ip -6 route show table "$route_table" | grep -q '^default '
    ip -6 rule show from "$source" | grep -q "lookup $route_table"
  done
