# Docker runtime glue. Keep protocol behavior in the shared VPS modules.

docker_bool() {
  case "${1,,}" in
    1|true|yes|y|on ) return 0 ;;
    * ) return 1 ;;
  esac
}

docker_false() {
  case "${1,,}" in
    0|false|no|n|off ) return 0 ;;
    * ) return 1 ;;
  esac
}

docker_protocols_from_env() {
  [ -n "$CHOOSE_PROTOCOLS" ] && return

  local SELECTED=''
  docker_bool "$XTLS_REALITY" && SELECTED+='b'
  docker_bool "$HYSTERIA2" && SELECTED+='c'
  docker_bool "$TUIC" && SELECTED+='d'
  docker_bool "$SHADOWTLS" && SELECTED+='e'
  docker_bool "$SHADOWSOCKS" && SELECTED+='f'
  docker_bool "$TROJAN" && SELECTED+='g'
  docker_bool "$VMESS_WS" && SELECTED+='h'
  docker_bool "$VLESS_WS" && SELECTED+='i'
  docker_bool "$H2_REALITY" && SELECTED+='j'
  docker_bool "$GRPC_REALITY" && SELECTED+='k'
  docker_bool "$ANYTLS" && SELECTED+='l'
  docker_bool "$NAIVE" && SELECTED+='m'

  CHOOSE_PROTOCOLS=${SELECTED:-a}
}

docker_pick_free_port() {
  local PORT=${1:-20000}
  while ss -nltup 2>/dev/null | grep -q ":$PORT "; do
    PORT=$((PORT + 1))
  done
  echo "$PORT"
}

docker_prepare_env() {
  L=${LANGUAGE:-${L:-C}}
  [[ "${L^^}" =~ ^C ]] && L=C || L=E

  SYSTEM='Alpine'
  SYS='Alpine Docker'
  int=0
  PACKAGE_UPDATE=("apk update -f")
  PACKAGE_INSTALL=("apk add --no-cache")
  PACKAGE_UNINSTALL=("apk del -f")
  ARGO_DAEMON_FILE='/etc/services.d/argo/run'
  SINGBOX_DAEMON_FILE='/etc/services.d/sing-box/run'
  IS_PREFER_GO=true
  NONINTERACTIVE_INSTALL=noninteractive_install

  START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
  if ! [[ "$START_PORT" =~ ^[1-9][0-9]{2,4}$ && "$START_PORT" -ge "$MIN_PORT" && "$START_PORT" -le "$MAX_PORT" ]]; then
    error " START_PORT must be ${MIN_PORT}-${MAX_PORT}. "
  fi

  docker_protocols_from_env
  normalize_install_protocols
  resolve_protocol_ports
  CDN=${CDN:-"${CDN_DOMAIN[0]}"}
  UUID_CONFIRM=${UUID_CONFIRM:-"$UUID"}
  NODE_NAME_CONFIRM=${NODE_NAME_CONFIRM:-"$NODE_NAME"}
  apply_custom_node_names
  normalize_log_level
  normalize_ntp_config
  normalize_finger_print
  TLS_SERVER_DEFAULT=${TLS_SERVER:-"$TLS_SERVER_DEFAULT"}

  docker_false "$SUBSCRIBE" && IS_SUB=no_sub || IS_SUB=is_sub
  docker_false "$ARGO" && IS_ARGO=no_argo || IS_ARGO=is_argo
  normalize_ws_domain_mode

  docker_bool "$HY2_REALM" && IS_HY2_REALM=is_hy2_realm
  docker_bool "$REALM" && IS_HY2_REALM=is_hy2_realm
  IS_HOPPING=${IS_HOPPING:-no_hopping}

  if [[ "$IS_SUB" = 'is_sub' || "$IS_ARGO" = 'is_argo' ]]; then
    PORT_NGINX=${PORT_NGINX:-$(default_service_port)}
  fi
  validate_nginx_port

  if [ "$IS_ARGO" = 'is_argo' ] && [ -n "$ARGO_DOMAIN" ] && [ -z "$ARGO_AUTH" ]; then
    error " ARGO_DOMAIN requires ARGO_AUTH. Leave both empty for Quick Tunnel. "
  fi

  if [ "$IS_ARGO" != 'is_argo' ] && [[ "${CHOOSE_PROTOCOLS,,}" =~ h ]] && [ -z "$VMESS_HOST_DOMAIN" ]; then
    error " VMESS_WS without Argo requires VMESS_HOST_DOMAIN. "
  fi

  if [ "$IS_ARGO" != 'is_argo' ] && [[ "${CHOOSE_PROTOCOLS,,}" =~ i ]] && [ -z "$VLESS_HOST_DOMAIN" ]; then
    error " VLESS_WS without Argo requires VLESS_HOST_DOMAIN. "
  fi
}

docker_download_assets() {
  mkdir -p "$TEMP_DIR" "$WORK_DIR"/{cert,conf,custom,state,subscribe,logs}
  check_cdn
  check_arch

  local ONLINE SB_DIR SB_BIN
  ONLINE=$(get_sing_box_version)
  SB_DIR="$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH"
  SB_BIN="$SB_DIR/sing-box"

  info " Downloading sing-box v${ONLINE} "
  wget --no-check-certificate --continue \
    "${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz" \
    -qO- | tar xz -C "$TEMP_DIR"
  [ -x "$SB_BIN" ] || failure_error " sing-box download failed. " "Version: ${ONLINE:-unknown}
Architecture: ${SING_BOX_ARCH:-unknown}
Expected file: ${SB_BIN}"
  mv "$SB_BIN" "$TEMP_DIR/sing-box"
  chmod +x "$TEMP_DIR/sing-box"
  rm -rf "$SB_DIR"

  info " Downloading jq, qrencode, cloudflared, and subscription templates "
  wget --no-check-certificate --continue -qO "$TEMP_DIR/jq" \
    "${GH_PROXY}https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$JQ_ARCH" && chmod +x "$TEMP_DIR/jq"
  wget --no-check-certificate --continue -qO "$TEMP_DIR/qrencode" \
    "${GH_PROXY}https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-$QRENCODE_ARCH" && chmod +x "$TEMP_DIR/qrencode"
  wget --no-check-certificate --continue -qO "$TEMP_DIR/cloudflared" \
    "${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH" && chmod +x "$TEMP_DIR/cloudflared"
  wget --no-check-certificate --continue -qO "$TEMP_DIR/clash" "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/clash"
  wget --no-check-certificate --continue -qO "$TEMP_DIR/clash2" "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/clash2"
  wget --no-check-certificate --continue -qO "$TEMP_DIR/sing-box-template" "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/sing-box"

  [ -x "$TEMP_DIR/jq" ] &&
    [ -x "$TEMP_DIR/qrencode" ] &&
    [ -x "$TEMP_DIR/cloudflared" ] &&
    [ -s "$TEMP_DIR/clash" ] &&
    [ -s "$TEMP_DIR/clash2" ] &&
    [ -s "$TEMP_DIR/sing-box-template" ] || failure_error " Dependency download failed. " "Expected files:
$TEMP_DIR/jq
$TEMP_DIR/qrencode
$TEMP_DIR/cloudflared
$TEMP_DIR/clash
$TEMP_DIR/clash2
$TEMP_DIR/sing-box-template
Architecture: jq=${JQ_ARCH:-unknown}, qrencode=${QRENCODE_ARCH:-unknown}, cloudflared=${ARGO_ARCH:-unknown}"
}

check_install() {
  [ -x "${WORK_DIR}/sing-box" ] && STATUS[0]=$(text 27) || STATUS[0]=$(text 26)
  pgrep -f "${WORK_DIR}/sing-box run" >/dev/null 2>&1 && STATUS[0]=$(text 28)

  if [ "$IS_ARGO" = 'is_argo' ]; then
    STATUS[1]=$(text 27)
    pgrep -f "${WORK_DIR}/cloudflared" >/dev/null 2>&1 && STATUS[1]=$(text 28)
  else
    STATUS[1]=$(text 26)
  fi

  if command -v nginx >/dev/null 2>&1 && [ -s "${WORK_DIR}/nginx.conf" ]; then
    STATUS[2]=$(text 27)
    pgrep -f "nginx.*${WORK_DIR}/nginx.conf" >/dev/null 2>&1 && STATUS[2]=$(text 28)
  elif command -v nginx >/dev/null 2>&1; then
    STATUS[2]=$(text 27)
  else
    STATUS[2]=$(text 26)
  fi

  if ls ${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json >/dev/null 2>&1; then
    check_port_hopping_nat
    [ -n "$PORT_HOPPING_END" ] && IS_HOPPING=is_hopping || IS_HOPPING=no_hopping
  fi
}

cmd_systemctl() {
  case "$1:$2" in
    status:sing-box ) pgrep -f "${WORK_DIR}/sing-box run" >/dev/null ;;
    status:argo ) pgrep -f "${WORK_DIR}/cloudflared" >/dev/null ;;
    status:nginx ) pgrep -f "nginx.*${WORK_DIR}/nginx.conf" >/dev/null ;;
    restart:sing-box ) pkill -f "${WORK_DIR}/sing-box run" 2>/dev/null || true ;;
    restart:argo ) pkill -f "${WORK_DIR}/cloudflared" 2>/dev/null || true ;;
    restart:nginx ) nginx -s reload -c "${WORK_DIR}/nginx.conf" >/dev/null 2>&1 || true ;;
    * ) return 0 ;;
  esac
}

add_port_hopping_nat() {
  warning " Docker does not manage host NAT for HY2 port hopping. Publish or redirect ${1}-${2}/udp to ${3}/udp on the host. "
}

del_port_hopping_nat() {
  return 0
}

check_port_hopping_nat() {
  if [[ "$HY2_PORT_HOPPING_RANGE" =~ ^[0-9]+:[0-9]+$ ]]; then
    PORT_HOPPING_START=${HY2_PORT_HOPPING_RANGE%:*}
    PORT_HOPPING_END=${HY2_PORT_HOPPING_RANGE#*:}
  else
    unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
  fi
}

sync_firewall_rules() {
  return 0
}

docker_prepare_argo() {
  [ "$IS_ARGO" = 'is_argo' ] || return
  [ -n "$ARGO_RUNS" ] || input_argo_auth is_install

  if [ -z "$ARGO_RUNS" ]; then
    error " Invalid ARGO_AUTH. Use Argo Json, Argo Tunnel Token, or a Cloudflare API Token with Tunnel and DNS permissions. "
  fi

  if [[ "$ARGO_RUNS" == *"--url "* ]]; then
    ARGO_TYPE=is_quicktunnel_argo
    if [[ "$ARGO_RUNS" != *"--metrics"* ]]; then
      METRICS_PORT=${ARGO_METRICS_PORT:-$(docker_pick_free_port "$((PORT_NGINX + 1))")}
      ARGO_RUNS="${ARGO_RUNS/ --url / --metrics 127.0.0.1:$METRICS_PORT --url }"
    fi
  fi
}

docker_copy_assets() {
  cp -f "$TEMP_DIR/sing-box" "$TEMP_DIR/jq" "$TEMP_DIR/qrencode" "$WORK_DIR/"
  [ -x "$TEMP_DIR/cloudflared" ] && cp -f "$TEMP_DIR/cloudflared" "$WORK_DIR/"
  [ -s "$TEMP_DIR/tunnel.json" ] && cp -f "$TEMP_DIR/tunnel.json" "$WORK_DIR/"
  [ -s "$TEMP_DIR/tunnel.yml" ] && cp -f "$TEMP_DIR/tunnel.yml" "$WORK_DIR/"
  echo "${L^^}" > "${WORK_DIR}/language"
}

docker_start_quicktunnel_for_export() {
  [ "$IS_ARGO" = 'is_argo' ] || return
  [ "$ARGO_TYPE" = 'is_quicktunnel_argo' ] || return

  nohup $ARGO_RUNS >> "${WORK_DIR}/logs/argo.log" 2>&1 &
  fetch_quicktunnel_domain
}

docker_write_services() {
  rm -rf /etc/services.d/sing-box /etc/services.d/nginx /etc/services.d/argo

  mkdir -p /etc/services.d/sing-box
  cat > /etc/services.d/sing-box/run << EOF
#!/usr/bin/env sh
exec ${WORK_DIR}/sing-box run -C ${WORK_DIR}/conf/
EOF
  chmod +x /etc/services.d/sing-box/run

  if [ -n "$PORT_NGINX" ]; then
    mkdir -p /etc/services.d/nginx
    cat > /etc/services.d/nginx/run << EOF
#!/usr/bin/env sh
exec /usr/sbin/nginx -c ${WORK_DIR}/nginx.conf -g 'daemon off;'
EOF
    chmod +x /etc/services.d/nginx/run
  fi

  if [ "$IS_ARGO" = 'is_argo' ] && [ "$ARGO_TYPE" != 'is_quicktunnel_argo' ] && [ -n "$ARGO_RUNS" ]; then
    mkdir -p /etc/services.d/argo
    cat > /etc/services.d/argo/run << EOF
#!/usr/bin/env sh
exec ${ARGO_RUNS}
EOF
    chmod +x /etc/services.d/argo/run
  fi
}

docker_install() {
  docker_prepare_env
  docker_download_assets
  check_brutal
  check_system_ip

  rm -f "${WORK_DIR}"/conf/* "${WORK_DIR}"/subscribe/* "${WORK_DIR}/list"
  sing-box_variables
  docker_prepare_argo
  ssl_certificate "$TLS_SERVER_DEFAULT"
  sing-box_json
  docker_copy_assets
  routing_publish || failure_error " Routing configuration check failed. " "Custom directory: ${CUSTOM_DIR}"
  [ -n "$PORT_NGINX" ] && export_nginx_conf_file
  docker_start_quicktunnel_for_export
  export_list install
  docker_write_services
}

docker_update_sing_box() {
  docker_prepare_env
  check_cdn
  check_arch

  local ONLINE LOCAL SB_DIR SB_BIN
  ONLINE=$(get_sing_box_version)
  LOCAL=$("${WORK_DIR}/sing-box" version 2>/dev/null | awk '/version/{print $NF}')
  local WAS_RUNNING=no

  if [ ! -x "${WORK_DIR}/sing-box" ]; then
    error " Sing-box is not installed. "
  fi

  pgrep -f "${WORK_DIR}/sing-box run" >/dev/null 2>&1 && WAS_RUNNING=yes

  if [ -z "$ONLINE" ]; then
    warning " Unable to fetch latest sing-box version. "
    return 1
  fi

  if [ "$ONLINE" = "$LOCAL" ]; then
    info " Sing-box v${ONLINE} is already current. "
    return 0
  fi

  SB_DIR="$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH"
  SB_BIN="$SB_DIR/sing-box"
  wget --no-check-certificate --continue \
    "${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz" \
    -qO- | tar xz -C "$TEMP_DIR"
  [ -x "$SB_BIN" ] || failure_error " sing-box download failed. " "Version: ${ONLINE:-unknown}
Architecture: ${SING_BOX_ARCH:-unknown}
Expected file: ${SB_BIN}"

  local CHECK_OUTPUT
  CHECK_OUTPUT=$("$SB_BIN" check -C "${WORK_DIR}/conf" 2>&1) ||
    failure_error " $(text 54) " "Version: ${ONLINE:-unknown}
Config: ${WORK_DIR}/conf
Output:
${CHECK_OUTPUT:-No output}"

  cp -f "${WORK_DIR}/sing-box" "$TEMP_DIR/sing-box.bak"
  mv "$SB_BIN" "${WORK_DIR}/sing-box"
  chmod +x "${WORK_DIR}/sing-box"
  rm -rf "$SB_DIR"

  if [ "$WAS_RUNNING" != yes ]; then
    rm -f "$TEMP_DIR/sing-box.bak"
    info " Sing-box updated from v${LOCAL:-unknown} to v${ONLINE}. "
    return 0
  fi

  pkill -f "${WORK_DIR}/sing-box run" 2>/dev/null || true
  sleep 3
  if pgrep -f "${WORK_DIR}/sing-box run" >/dev/null 2>&1; then
    rm -f "$TEMP_DIR/sing-box.bak"
    info " Sing-box updated from v${LOCAL:-unknown} to v${ONLINE}. "
    return 0
  fi

  warning " New sing-box v${ONLINE} did not restart; restoring v${LOCAL:-unknown}. "
  cp -f "$TEMP_DIR/sing-box.bak" "${WORK_DIR}/sing-box"
  chmod +x "${WORK_DIR}/sing-box"
  pkill -f "${WORK_DIR}/sing-box run" 2>/dev/null || true
  sleep 3

  if pgrep -f "${WORK_DIR}/sing-box run" >/dev/null 2>&1; then
    info " Restored old sing-box v${LOCAL:-unknown}. "
  else
    error " Failed to restart sing-box after rollback. "
  fi
}
