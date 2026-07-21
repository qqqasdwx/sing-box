#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

WORK_DIR="$TEST_DIR/work"
TEMP_DIR="$TEST_DIR/tmp"
TEST_CANDIDATE_DIR="$TEST_DIR/candidate"
mkdir -p "$WORK_DIR" "$TEMP_DIR" "$TEST_CANDIDATE_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/20_helpers.sh"

ROUTING_CHECK_CALLED="$TEST_DIR/sing-box-check-called"
export ROUTING_CHECK_CALLED
cat > "$WORK_DIR/sing-box" << 'EOF'
#!/bin/sh
touch "$ROUTING_CHECK_CALLED"
exit 0
EOF
chmod +x "$WORK_DIR/sing-box"

cat > "$TEST_CANDIDATE_DIR/03_routing.json" << 'EOF'
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "direct", "tag": "ipv6-out"}
  ],
  "endpoints": [
    {"type": "wireguard", "tag": "wireguard-out"}
  ],
  "route": {
    "rules": [
      {"action": "route", "outbound": "direct"},
      {"action": "route", "outbound": "wireguard-out"},
      {
        "type": "logical",
        "mode": "or",
        "rules": [
          {"ip_is_private": true},
          {"rule_set": ["geosite-google"], "outbound": "ipv6-out"}
        ]
      }
    ]
  }
}
EOF
routing_validate_candidate "$TEST_CANDIDATE_DIR"
[ -e "$ROUTING_CHECK_CALLED" ]

jq '.route.rules += [{"action":"route","outbound":"missing-out"}]' \
  "$TEST_CANDIDATE_DIR/03_routing.json" > "$TEST_CANDIDATE_DIR/03_routing.invalid.json"
mv "$TEST_CANDIDATE_DIR/03_routing.invalid.json" "$TEST_CANDIDATE_DIR/03_routing.json"
rm -f "$ROUTING_CHECK_CALLED"

if routing_validate_candidate "$TEST_CANDIDATE_DIR" 2> "$TEST_DIR/error"; then
  printf 'undefined outbound tag unexpectedly passed validation\n' >&2
  exit 1
fi
grep -Fq 'Undefined route outbound/endpoint tag(s): missing-out' "$TEST_DIR/error"
[ ! -e "$ROUTING_CHECK_CALLED" ]

jq 'del(.route.rules[-1]) | .route.final = "missing-final"' \
  "$TEST_CANDIDATE_DIR/03_routing.json" > "$TEST_CANDIDATE_DIR/03_routing.invalid.json"
mv "$TEST_CANDIDATE_DIR/03_routing.invalid.json" "$TEST_CANDIDATE_DIR/03_routing.json"

if routing_validate_candidate "$TEST_CANDIDATE_DIR" 2> "$TEST_DIR/error"; then
  printf 'undefined final outbound tag unexpectedly passed validation\n' >&2
  exit 1
fi
grep -Fq 'Undefined route outbound/endpoint tag(s): missing-final' "$TEST_DIR/error"
[ ! -e "$ROUTING_CHECK_CALLED" ]

jq '.route.final = ""' \
  "$TEST_CANDIDATE_DIR/03_routing.json" > "$TEST_CANDIDATE_DIR/03_routing.invalid.json"
mv "$TEST_CANDIDATE_DIR/03_routing.invalid.json" "$TEST_CANDIDATE_DIR/03_routing.json"

if routing_validate_candidate "$TEST_CANDIDATE_DIR" 2> "$TEST_DIR/error"; then
  printf 'empty final outbound tag unexpectedly passed validation\n' >&2
  exit 1
fi
grep -Fq 'Undefined route outbound/endpoint tag(s): <empty>' "$TEST_DIR/error"
[ ! -e "$ROUTING_CHECK_CALLED" ]

printf 'routing validation tests passed\n'
