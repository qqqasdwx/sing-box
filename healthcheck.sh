#!/bin/sh
set -eu

test -s /run/aethercloud/ipv6_cidr
test -s /run/aethercloud/sockd-supervisor.pid
pid=$(cat /run/aethercloud/sockd-supervisor.pid)
kill -0 "$pid"
ip link show dev wan0 >/dev/null 2>&1
ip -6 route show table 16000 | grep -q '^default '
