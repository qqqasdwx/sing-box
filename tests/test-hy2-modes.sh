#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

L=E
E=()
C=()
E[179]='Hysteria2 Realm and port hopping cannot be enabled together.'
C[179]="${E[179]}"

# shellcheck disable=SC1091
source "$ROOT_DIR/src/vps/20_helpers.sh"

unset IS_HY2_REALM IS_HOPPING HY2_PORT_HOPPING_RANGE PORT_HOPPING_START PORT_HOPPING_END
if hy2_realm_hopping_conflict; then
  printf 'empty Hysteria2 options were reported as conflicting\n' >&2
  exit 1
fi

IS_HY2_REALM=is_hy2_realm
if hy2_realm_hopping_conflict; then
  printf 'Realm without port hopping was reported as conflicting\n' >&2
  exit 1
fi

HY2_PORT_HOPPING_RANGE=50000:51000
hy2_realm_hopping_conflict
if (validate_hy2_mode_selection) >/dev/null 2>&1; then
  printf 'Realm and port hopping were accepted together\n' >&2
  exit 1
fi

unset HY2_PORT_HOPPING_RANGE
IS_HOPPING=is_hopping
hy2_realm_hopping_conflict

if grep -Eq "HY2_PORT_HOPPING_RANGE=.*50000:51000" "$ROOT_DIR/src/vps/50_runtime.sh"; then
  printf 'menu quick install still enables port hopping by default\n' >&2
  exit 1
fi

printf 'Hysteria2 mode validation tests passed\n'
