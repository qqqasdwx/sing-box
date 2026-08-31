#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../aethercloud-agent.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

MOCK_RESPONSE=''
MOCK_STATUS='200'
MOCK_CURL_FAILURE=false

curl() {
  [ "$MOCK_CURL_FAILURE" = false ] || return 7
  printf '%s\n%s' "$MOCK_RESPONSE" "$MOCK_STATUS"
}

# Used by api_request() from the sourced agent.
# shellcheck disable=SC2034
VM_UUID='00000000-0000-0000-0000-000000000000'
[ "$API_BASE" = 'https://aethercloud.io/api/dynamicv6/vm' ] ||
  fail 'default API endpoint does not match the provider client'
MOCK_RESPONSE='{"active":false}'
[ "$(api_request status)" = "$MOCK_RESPONSE" ] || fail 'valid JSON response was rejected'

MOCK_STATUS='301'
MOCK_RESPONSE='<html><h1>Moved Permanently</h1></html>'
if api_request status >/dev/null 2>&1; then
  fail 'HTTP redirect was accepted as an API response'
fi

MOCK_STATUS='200'
if api_request status >/dev/null 2>&1; then
  fail 'non-JSON success body was accepted as an API response'
fi

MOCK_CURL_FAILURE=true
if api_request status >/dev/null 2>&1; then
  fail 'curl transport failure was accepted as an API response'
fi

printf 'API response tests passed\n'
