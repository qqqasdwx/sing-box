#!/bin/sh
set -eu

test -s /run/aethercloud/ipv6_cidr
test -s /run/aethercloud/sockd-supervisor.pid
test -s /run/aethercloud/control_interface
test -s /run/aethercloud/wan_interface
pid=$(cat /run/aethercloud/sockd-supervisor.pid)
wan_interface=$(cat /run/aethercloud/wan_interface)
kill -0 "$pid"
ip link show dev "$wan_interface" >/dev/null 2>&1
ip -6 route show table 16000 | grep -q '^default '
