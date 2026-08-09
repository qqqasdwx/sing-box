#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

L=E
E=()
C=()
E[3]='Too many invalid attempts'
C[3]="${E[3]}"
E[10]='Enter server address'
C[10]="${E[10]}"
E[47]='No server address'
C[47]="${E[47]}"
E[133]='Invalid server address'
C[133]="${E[133]}"

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/20_helpers.sh"

for ADDRESS in \
  192.0.2.1 \
  255.255.255.255 \
  2001:db8::1 \
  ::1 \
  2001:db8:0:1:2:3:4:5 \
  ::ffff:192.0.2.1 \
  ddns.example.com \
  node.xn--fiqs8s; do
  valid_server_address "$ADDRESS" || {
    printf 'valid server address was rejected: %s\n' "$ADDRESS" >&2
    exit 1
  }
done

for ADDRESS in \
  999.999.999.999 \
  192.0.2.1. \
  2001:db8:::1 \
  1:2:3:4:5:6:7:8:9 \
  1:2:3:4:5:6:7::8 \
  ::ffff:999.0.0.1 \
  localhost \
  123.456 \
  -bad.example.com \
  bad-.example.com \
  bad..example.com; do
  if valid_server_address "$ADDRESS"; then
    printf 'invalid server address was accepted: %s\n' "$ADDRESS" >&2
    exit 1
  fi
done

NONINTERACTIVE_INSTALL=noninteractive_install
SERVER_IP=ddns.example.com
SERVER_IP_DEFAULT=192.0.2.1
input_server_address
[ "$SERVER_IP" = ddns.example.com ]
[ "$WS_SERVER_IP_SHOW" = ddns.example.com ]

if (
  SERVER_IP=999.999.999.999
  input_server_address
) >/dev/null 2>&1; then
  printf 'non-interactive install accepted an invalid server address\n' >&2
  exit 1
fi

ss() {
  cat <<'EOF'
udp UNCONN 0 0 0.0.0.0:5353 0.0.0.0:*
tcp LISTEN 0 4096 *:11111 *:*
tcp LISTEN 0 4096 [::]:443 [::]:*
EOF
}

is_port_in_use 11111
is_port_in_use 443
is_port_in_use 5353
if is_port_in_use 1111; then
  printf 'port 1111 was confused with listening port 11111\n' >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$ROOT_DIR/src/docker/80_overrides.sh"
[ "$(docker_pick_free_port 1111)" = 1111 ]
[ "$(docker_pick_free_port 11111)" = 11112 ]

printf 'server address and exact port tests passed\n'
