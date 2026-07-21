#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

WORK_DIR="$TEST_DIR/work"
mkdir -p "$WORK_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/30_system.sh"

file_hash() {
  sha256sum "$1" | awk '{print $1}'
}

certificate_sni() {
  openssl x509 -noout -ext subjectAltName -in "$1" 2>/dev/null |
    awk -F 'DNS:' '/DNS:/{gsub(/,.*/, "", $2); print $2}'
}

ssl_certificate 'addons.mozilla.org'
OLD_KEY_HASH=$(file_hash "$WORK_DIR/cert/private.key")
OLD_CERT_HASH=$(file_hash "$WORK_DIR/cert/cert.pem")
OLD_CERT_200_HASH=$(file_hash "$WORK_DIR/cert/cert_200.pem")

ssl_certificate 'addons.mozilla.org' reuse_existing
[ "$(file_hash "$WORK_DIR/cert/private.key")" = "$OLD_KEY_HASH" ]
[ "$(file_hash "$WORK_DIR/cert/cert.pem")" = "$OLD_CERT_HASH" ]
[ "$(file_hash "$WORK_DIR/cert/cert_200.pem")" = "$OLD_CERT_200_HASH" ]

rm -f "$WORK_DIR/cert/cert_200.pem"
ssl_certificate 'addons.mozilla.org' reuse_existing
[ "$(file_hash "$WORK_DIR/cert/private.key")" = "$OLD_KEY_HASH" ]
[ "$(file_hash "$WORK_DIR/cert/cert.pem")" = "$OLD_CERT_HASH" ]
certificate_identity_valid \
  "$WORK_DIR/cert/cert_200.pem" \
  "$WORK_DIR/cert/private.key" \
  'addons.mozilla.org'

ssl_certificate 'example.com' reuse_existing
[ "$(file_hash "$WORK_DIR/cert/private.key")" != "$OLD_KEY_HASH" ]
[ "$(file_hash "$WORK_DIR/cert/cert.pem")" != "$OLD_CERT_HASH" ]
[ "$(certificate_sni "$WORK_DIR/cert/cert.pem")" = 'example.com' ]
certificate_identity_valid \
  "$WORK_DIR/cert/cert.pem" \
  "$WORK_DIR/cert/private.key" \
  'example.com'

CERT_BEFORE_KEY_MISMATCH=$(file_hash "$WORK_DIR/cert/cert.pem")
openssl ecparam -genkey -name prime256v1 -out "$WORK_DIR/cert/private.key"
ssl_certificate 'example.com' reuse_existing
[ "$(file_hash "$WORK_DIR/cert/cert.pem")" != "$CERT_BEFORE_KEY_MISMATCH" ]
certificate_identity_valid \
  "$WORK_DIR/cert/cert.pem" \
  "$WORK_DIR/cert/private.key" \
  'example.com'

printf 'certificate reuse tests passed\n'
