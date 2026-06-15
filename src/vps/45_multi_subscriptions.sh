json_string() {
  jq_exec -Rn --arg v "$1" '$v'
}

multi_write_default_config() {
  local CONFIG_PATH=${1:-"${WORK_DIR}/config.json"}
  mkdir -p "$(dirname "$CONFIG_PATH")"
  cat > "$CONFIG_PATH" <<'EOF'
{
  "_comment": "Experimental multi-subscription JSON config. Strict JSON. Fields starting with _ are ignored by the installer.",
  "global": {
    "_comment": "language: c/e. server_ip can be empty for auto-detect.",
    "language": "c",
    "server_ip": "",
    "nginx_port": 8899,
    "tls_server": "addons.mozilla.org",
    "dns_strategy": "prefer_ipv4",
    "cdn": "skk.moe",
    "argo": false,
    "argo_domain": "",
    "argo_auth": ""
  },
  "subscriptions": [],
  "_example_subscriptions": [
    {
      "name": "订阅 A",
      "uuid": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "nodes": [
        {
          "protocol": "hysteria2",
          "port": 8801,
          "name": "A-HY2-1",
          "up_mbps": 200,
          "down_mbps": 1000
        },
        {
          "protocol": "hysteria2",
          "port": 8802,
          "name": "A-HY2-2"
        },
        {
          "protocol": "vless-reality",
          "port": 8803,
          "name": "A-Reality"
        }
      ]
    }
  ]
}
EOF
}

multi_protocol_index_by_code() {
  printf '%s' "$(( $(asc "$1") - 98 ))"
}

multi_protocol_node_index_by_code() {
  printf '%s' "$(( $(multi_protocol_index_by_code "$1") + 11 ))"
}

multi_protocol_code() {
  case "${1,,}" in
    xtls-reality|vless-reality|reality|xtls ) printf '%s' b ;;
    hysteria2|hy2 ) printf '%s' c ;;
    tuic|tuic-v5 ) printf '%s' d ;;
    shadowtls|shadow-tls ) printf '%s' e ;;
    shadowsocks|ss ) printf '%s' f ;;
    trojan ) printf '%s' g ;;
    vmess-ws|vmess+ws|vmess_ws|vmess ) printf '%s' h ;;
    vless-ws|vless-ws-tls|vless+ws|vless_ws|vless ) printf '%s' i ;;
    h2-reality|vless-h2-reality|h2 ) printf '%s' j ;;
    grpc-reality|vless-grpc-reality|grpc ) printf '%s' k ;;
    anytls|any-tls ) printf '%s' l ;;
    naive|naiveproxy|naive-proxy ) printf '%s' m ;;
    [b-m] ) printf '%s' "${1,,}" ;;
    * ) return 1 ;;
  esac
}

multi_json_get() {
  local FILTER=$1 DEFAULT=${2-}
  jq_exec -er "$FILTER // empty" "$MULTI_CONFIG_FILE" 2>/dev/null || printf '%s' "$DEFAULT"
}

multi_json_bool() {
  local FILTER=$1
  jq_exec -er "$FILTER == true or $FILTER == \"true\" or $FILTER == 1 or $FILTER == \"1\" or ($FILTER | ascii_downcase? // \"\") == \"yes\"" "$MULTI_CONFIG_FILE" >/dev/null 2>&1
}

multi_validate_uuid() {
  local VALUE=$1 LABEL=$2
  [[ "${VALUE,,}" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || error " ${LABEL} must be a UUID. "
}

multi_config_has_subscriptions() {
  jq_exec -e '.subscriptions | type == "array" and length > 0' "$MULTI_CONFIG_FILE" >/dev/null 2>&1
}

multi_port_owned_by_current_install() {
  local PORT=$1
  [ -s "${WORK_DIR}/nginx.conf" ] && awk '
    /listen[[:space:]]+[0-9]+[[:space:]]*;/ && $2 !~ /^\[/ {
      gsub(/;/, "", $2)
      if ($2 == port) found=1
    }
    END { exit found ? 0 : 1 }
  ' port="$PORT" "${WORK_DIR}/nginx.conf" && return 0

  compgen -G "${WORK_DIR}/conf/*_inbounds.json" >/dev/null || return 1
  awk -F '[:,]' '
    /"listen_port"/ {
      gsub(/[[:space:]]/, "", $2)
      if ($2 == port) found=1
    }
    END { exit found ? 0 : 1 }
  ' port="$PORT" "${WORK_DIR}"/conf/*_inbounds.json
}

multi_assert_unique_port() {
  local PORT=$1 LABEL=$2 EXISTING
  valid_listen_port "$PORT" || error " ${LABEL} port must be ${MIN_PORT}-${MAX_PORT}. "
  for EXISTING in "${MULTI_USED_PORTS[@]}"; do
    [ "$EXISTING" = "$PORT" ] && error " ${LABEL} conflicts on port ${PORT}. "
  done
  if ss -nltup 2>/dev/null | grep -q ":$PORT" && ! multi_port_owned_by_current_install "$PORT"; then
    error " ${LABEL} port ${PORT} is already in use. "
  fi
  MULTI_USED_PORTS+=("$PORT")
}

multi_default_node_name() {
  local SUB_NAME=$1 CODE=$2 NODE_INDEX=$3 IDX
  IDX=$(multi_protocol_index_by_code "$CODE")
  printf '%s-%02d %s' "$SUB_NAME" "$((NODE_INDEX + 1))" "${NODE_TAG[IDX]}"
}

multi_node_uid() {
  local SUB_INDEX=$1 NODE_INDEX=$2 CODE=$3
  printf 's%02d_n%02d_%s' "$((SUB_INDEX + 1))" "$((NODE_INDEX + 1))" "$CODE"
}

multi_default_ws_path() {
  local SUB_UUID=$1 NODE_INDEX=$2 KIND=$3
  printf '%s-%02d-%s' "$SUB_UUID" "$((NODE_INDEX + 1))" "$KIND"
}

multi_generated_secret() {
  local KEY=$1 VALUE
  if ! declare -p MULTI_GENERATED_SECRETS >/dev/null 2>&1 || [[ "$(declare -p MULTI_GENERATED_SECRETS 2>/dev/null)" != declare\ -A* ]]; then
    declare -gA MULTI_GENERATED_SECRETS
  fi
  VALUE=${MULTI_GENERATED_SECRETS[$KEY]:-}
  if [ -z "$VALUE" ]; then
    VALUE=$(openssl rand -base64 16)
    MULTI_GENERATED_SECRETS[$KEY]=$VALUE
  fi
  printf '%s' "$VALUE"
}

multi_reset_node_context() {
  unset CHOOSE_PROTOCOLS INSTALL_PROTOCOLS START_PORT UUID UUID_CONFIRM NODE_NAME NODE_NAME_CONFIRM
  unset PORT_XTLS_REALITY PORT_HYSTERIA2 PORT_TUIC PORT_SHADOWTLS PORT_SHADOWSOCKS PORT_TROJAN
  unset PORT_VMESS_WS PORT_VLESS_WS PORT_H2_REALITY PORT_GRPC_REALITY PORT_ANYTLS PORT_NAIVE
  unset REALITY_PRIVATE REALITY_PUBLIC TUIC_PASSWORD TUIC_CONGESTION_CONTROL SHADOWTLS_PASSWORD SHADOWTLS_METHOD
  unset SHADOWSOCKS_PASSWORD SHADOWSOCKS_METHOD TROJAN_PASSWORD VMESS_WS_PATH VLESS_WS_PATH
  unset WS_SERVER_IP WS_SERVER_IP_SHOW VMESS_HOST_DOMAIN VLESS_HOST_DOMAIN CDN CDN_PORT
  unset HY2_UP HY2_DOWN HY2_REALM_ID IS_HY2_REALM IS_HY2_WARP IS_HOPPING HY2_PORT_HOPPING_RANGE PORT_HOPPING_START PORT_HOPPING_END
  unset MULTI_CURRENT_CODE MULTI_CURRENT_NODE_IDX MULTI_CURRENT_PORT MULTI_CURRENT_NODE_NAME MULTI_CURRENT_NODE_UID MULTI_CURRENT_TAG MULTI_CURRENT_WS_PATH
}

multi_apply_node_context() {
  local SUB_INDEX=$1 NODE_INDEX=$2 SUB_UUID=$3 SUB_NAME=$4
  local PREFIX=".subscriptions[$SUB_INDEX].nodes[$NODE_INDEX]"
  local PROTOCOL CODE NODE_IDX PORT NODE_UUID NODE_NAME_VALUE NODE_UID
  local NODE_CDN NODE_CDN_PORT WS_DOMAIN NODE_PASSWORD

  PROTOCOL=$(multi_json_get "${PREFIX}.protocol")
  CODE=$(multi_protocol_code "$PROTOCOL") || error " Unsupported protocol: ${PROTOCOL}. "
  NODE_IDX=$(multi_protocol_node_index_by_code "$CODE")
  NODE_UID=$(multi_node_uid "$SUB_INDEX" "$NODE_INDEX" "$CODE")
  CHOOSE_PROTOCOLS="$CODE"
  INSTALL_PROTOCOLS=("$CODE")

  NODE_UUID=$(multi_json_get "${PREFIX}.uuid" "$SUB_UUID")
  multi_validate_uuid "$NODE_UUID" "subscriptions[$SUB_INDEX].nodes[$NODE_INDEX].uuid"
  UUID_CONFIRM="$NODE_UUID"
  UUID[$NODE_IDX]="$NODE_UUID"

  NODE_NAME_VALUE=$(multi_json_get "${PREFIX}.name")
  NODE_NAME_VALUE=${NODE_NAME_VALUE:-$(multi_default_node_name "$SUB_NAME" "$CODE" "$NODE_INDEX")}
  NODE_NAME_CONFIRM="$NODE_NAME_VALUE"
  NODE_NAME[$NODE_IDX]="$NODE_NAME_VALUE"

  PORT=$(multi_json_get "${PREFIX}.port")
  [ -n "$PORT" ] || error " subscriptions[$SUB_INDEX].nodes[$NODE_INDEX].port is required. "
  [ "${MULTI_SKIP_PORT_CHECK:-}" = true ] || multi_assert_unique_port "$PORT" "${SUB_NAME}/${PROTOCOL}"
  START_PORT="$PORT"
  printf -v "$(protocol_port_var "$CODE")" '%s' "$PORT"

  case "$CODE" in
    b|j|k )
      local REALITY_PRIVATE_VALUE
      REALITY_PRIVATE_VALUE=$(multi_json_get "${PREFIX}.reality_private" "$(multi_json_get ".global.reality_private")")
      [ -n "$REALITY_PRIVATE_VALUE" ] && REALITY_PRIVATE[$NODE_IDX]="$REALITY_PRIVATE_VALUE"
      ;;
    c )
      HY2_UP=$(multi_json_get "${PREFIX}.up_mbps" "$(multi_json_get ".global.hy2.up_mbps" 200)")
      HY2_DOWN=$(multi_json_get "${PREFIX}.down_mbps" "$(multi_json_get ".global.hy2.down_mbps" 1000)")
      HY2_REALM_ID=$(multi_json_get "${PREFIX}.realm_id" "$NODE_UUID")
      if multi_json_bool "${PREFIX}.realm"; then
        IS_HY2_REALM=is_hy2_realm
      fi
      if multi_json_bool "${PREFIX}.warp"; then
        IS_HY2_WARP=is_hy2_warp
        IS_HY2_REALM=is_hy2_realm
      fi
      ;;
    d )
      TUIC_PASSWORD=$(multi_json_get "${PREFIX}.password" "$NODE_UUID")
      TUIC_CONGESTION_CONTROL=$(multi_json_get "${PREFIX}.congestion_control" bbr)
      ;;
    e )
      NODE_PASSWORD=$(multi_json_get "${PREFIX}.password")
      SHADOWTLS_PASSWORD=${NODE_PASSWORD:-$(multi_generated_secret "$NODE_UID:shadowtls_password")}
      SHADOWTLS_METHOD=$(multi_json_get "${PREFIX}.method" "2022-blake3-aes-128-gcm")
      ;;
    f )
      NODE_PASSWORD=$(multi_json_get "${PREFIX}.password")
      SHADOWSOCKS_PASSWORD=${NODE_PASSWORD:-$(multi_generated_secret "$NODE_UID:shadowsocks_password")}
      SHADOWSOCKS_METHOD=$(multi_json_get "${PREFIX}.method" "2022-blake3-aes-128-gcm")
      ;;
    g )
      TROJAN_PASSWORD=$(multi_json_get "${PREFIX}.password" "$NODE_UUID")
      ;;
    h )
      WS_DOMAIN=$(multi_json_get "${PREFIX}.host" "$MULTI_ARGO_DOMAIN")
      [ -z "$WS_DOMAIN" ] && [ "$IS_ARGO" != 'is_argo' ] && error " vmess-ws requires node.host when global.argo is false. "
      VMESS_HOST_DOMAIN="$WS_DOMAIN"
      WS_SERVER_IP[$NODE_IDX]="$SERVER_IP"
      NODE_CDN=$(multi_json_get "${PREFIX}.cdn" "$MULTI_CDN")
      NODE_CDN_PORT=$(multi_json_get "${PREFIX}.cdn_port" 80)
      CDN="$NODE_CDN"
      CDN[$NODE_IDX]="$NODE_CDN"
      CDN_PORT="$NODE_CDN_PORT"
      CDN_PORT[$NODE_IDX]="$NODE_CDN_PORT"
      VMESS_WS_PATH=$(multi_json_get "${PREFIX}.path" "$(multi_default_ws_path "$SUB_UUID" "$NODE_INDEX" vmess)")
      VMESS_WS_PATH=${VMESS_WS_PATH#/}
      MULTI_CURRENT_WS_PATH="$VMESS_WS_PATH"
      ;;
    i )
      WS_DOMAIN=$(multi_json_get "${PREFIX}.host" "$MULTI_ARGO_DOMAIN")
      [ -z "$WS_DOMAIN" ] && [ "$IS_ARGO" != 'is_argo' ] && error " vless-ws requires node.host when global.argo is false. "
      VLESS_HOST_DOMAIN="$WS_DOMAIN"
      WS_SERVER_IP[$NODE_IDX]="$SERVER_IP"
      NODE_CDN=$(multi_json_get "${PREFIX}.cdn" "$MULTI_CDN")
      NODE_CDN_PORT=$(multi_json_get "${PREFIX}.cdn_port" 443)
      CDN="$NODE_CDN"
      CDN[$NODE_IDX]="$NODE_CDN"
      CDN_PORT="$NODE_CDN_PORT"
      CDN_PORT[$NODE_IDX]="$NODE_CDN_PORT"
      VLESS_WS_PATH=$(multi_json_get "${PREFIX}.path" "$(multi_default_ws_path "$SUB_UUID" "$NODE_INDEX" vless)")
      VLESS_WS_PATH=${VLESS_WS_PATH#/}
      MULTI_CURRENT_WS_PATH="$VLESS_WS_PATH"
      ;;
    l|m )
      ;;
  esac

  MULTI_CURRENT_CODE="$CODE"
  MULTI_CURRENT_NODE_IDX="$NODE_IDX"
  MULTI_CURRENT_PORT="$PORT"
  MULTI_CURRENT_NODE_NAME="$NODE_NAME_VALUE"
  MULTI_CURRENT_NODE_UID="$NODE_UID"
  MULTI_CURRENT_TAG="${NODE_NAME_VALUE} ${NODE_TAG[$(multi_protocol_index_by_code "$CODE")]}"
}

multi_patch_shadowtls_inbound() {
  local FILE=$1 NODE_UID=$2 TMP_FILE
  TMP_FILE="${FILE}.tmp"
  jq_exec --arg tag "${NODE_UID}_shadowtls-in" '
    .inbounds |= map(
      if .type == "shadowtls" then .detour = $tag
      elif .type == "shadowsocks" and .tag == "shadowtls-in" then .tag = $tag
      else . end
    )
  ' "$FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$FILE"
}

multi_patch_shadowtls_subscription() {
  local FILE=$1 NODE_UID=$2 TMP_FILE
  [ -s "$FILE" ] || return
  TMP_FILE="${FILE}.tmp"
  jq_exec --arg old "shadowtls-out" --arg new "${NODE_UID}_shadowtls-out" '
    .outbounds |= map(
      (if .detour? == $old then .detour = $new else . end)
      | (if .tag? == $old then .tag = $new else . end)
    )
  ' "$FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$FILE"
}

multi_register_nginx_ws_location() {
  local CODE=$1 PATH_VALUE=$2 PORT=$3
  [ "$IS_ARGO" = 'is_argo' ] || return 0
  [ -n "$PATH_VALUE" ] || return 0

  if [ "$CODE" = h ]; then
    MULTI_NGINX_WS_LOCATIONS+="
    # multi-subscription vmess websocket
    location /${PATH_VALUE} {
      if (\$http_upgrade != \"websocket\") {
         return 404;
      }
      proxy_pass                          http://127.0.0.1:${PORT};
      proxy_http_version                  1.1;
      proxy_set_header Upgrade            \$http_upgrade;
      proxy_set_header Connection         \"upgrade\";
      proxy_set_header X-Real-IP          \$remote_addr;
      proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
      proxy_set_header Host               \$host;
      proxy_redirect                      off;
    }
"
  elif [ "$CODE" = i ]; then
    MULTI_NGINX_WS_LOCATIONS+="
    # multi-subscription vless websocket
    location /${PATH_VALUE} {
      if (\$http_upgrade != \"websocket\") {
         return 404;
      }
      proxy_http_version                  1.1;
      proxy_pass                          https://127.0.0.1:${PORT};
      proxy_ssl_protocols                 TLSv1.3;
      proxy_set_header Upgrade            \$http_upgrade;
      proxy_set_header Connection         \"upgrade\";
      proxy_set_header X-Real-IP          \$remote_addr;
      proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
      proxy_set_header Host               \$host;
      proxy_redirect                      off;
    }
"
  fi
  return 0
}

multi_move_generated_inbound() {
  local SAVE_PREFIX=$1 CODE=$2 NODE_IDX=$3 NODE_UID=$4 IDX SRC DST
  IDX=$(multi_protocol_index_by_code "$CODE")
  SRC="${WORK_DIR}/conf/${NODE_IDX}_${NODE_TAG[IDX]}_inbounds.json"
  [ -s "$SRC" ] || error " Failed to generate ${NODE_TAG[IDX]} inbound. "
  [ "$CODE" = e ] && multi_patch_shadowtls_inbound "$SRC" "$NODE_UID"
  DST="${WORK_DIR}/conf/${SAVE_PREFIX}_${NODE_UID}_${NODE_TAG[IDX]}_inbounds.json"
  mv "$SRC" "$DST"
  multi_register_nginx_ws_location "$CODE" "$MULTI_CURRENT_WS_PATH" "$MULTI_CURRENT_PORT"
}

multi_prepare_base_config() {
  mkdir -p "${WORK_DIR}/conf" "${WORK_DIR}/logs" "${WORK_DIR}/subscribe"
  rm -rf "${WORK_DIR}"/conf/* "${WORK_DIR}"/subscribe/* "${WORK_DIR}/list"

  cat > "${WORK_DIR}/conf/00_log.json" << EOF
{
    "log":{
        "disabled":false,
        "level":"error",
        "output":"${WORK_DIR}/logs/box.log",
        "timestamp":true
    }
}
EOF

  cat > "${WORK_DIR}/conf/01_outbounds.json" << EOF
{
    "outbounds":[
        {
            "type":"direct",
            "tag":"direct"
        }
    ]
}
EOF

  cat > "${WORK_DIR}/conf/02_endpoints.json" << EOF
{
    "endpoints":[
        {
            "type":"wireguard",
            "tag":"warp-ep",
            "mtu":1400,
            "address":[
                "172.16.0.2/32",
                "2606:4700:110:8a36:df92:102a:9602:fa18/128"
            ],
            "private_key":"YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
            "peers": [
              {
                "address": "engage.cloudflareclient.com",
                "port":2408,
                "public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                "allowed_ips": [
                  "0.0.0.0/0",
                  "::/0"
                ],
                "reserved":[
                    78,
                    135,
                    76
                ]
              }
            ]
        }
    ]
}
EOF

  cat > "${WORK_DIR}/conf/03_route.json" << EOF
{
    "route":{
        "default_http_client": "http-client-direct",
        "rule_set":[
            {
                "tag":"geosite-openai",
                "type":"remote",
                "format":"binary",
                "url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"
            }
        ],
        "rules":[
            {
                "action": "sniff"
            },
            {
                "action": "resolve",
                "domain":[
                    "api.openai.com"
                ],
                "strategy": "prefer_ipv4"
            },
            {
                "action": "resolve",
                "rule_set":[
                    "geosite-openai"
                ],
                "strategy": "prefer_ipv6"
            },
            {
                "domain":[
                    "api.openai.com"
                ],
                "rule_set":[
                    "geosite-openai"
                ],
                "outbound":"${CHATGPT_OUT}"
            }
        ]
    }
}
EOF

  cat > "${WORK_DIR}/conf/04_experimental.json" << EOF
{
    "experimental": {
        "cache_file": {
            "enabled": true,
            "path": "${WORK_DIR}/cache.db"
        }
    }
}
EOF

  cat > "${WORK_DIR}/conf/05_dns.json" << EOF
{
    "dns":{
        "servers":[
            {
                "type":"local",
                "prefer_go": ${IS_PREFER_GO}
            }
        ],
        "strategy": "${STRATEGY}"
    }
}
EOF

  cat > "${WORK_DIR}/conf/06_ntp.json" << EOF
{
    "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
    }
}
EOF

  cat > "${WORK_DIR}/conf/07_http_clients.json" << EOF
{
    "http_clients": [
        {
            "tag": "http-client-direct"
        }
    ]
}
EOF
}

multi_init_globals() {
  MULTI_CONFIG_FILE=$1
  [ -s "$MULTI_CONFIG_FILE" ] || error " JSON config file not found: ${MULTI_CONFIG_FILE}. "
  jq_exec -e '. | type == "object" and (.subscriptions | type == "array")' "$MULTI_CONFIG_FILE" >/dev/null || error " JSON config requires subscriptions array. "

  NONINTERACTIVE_INSTALL=noninteractive_install
  IS_MULTI_SUBSCRIPTIONS=is_multi_subscriptions
  IS_SUB=is_sub
  IS_PREFER_GO=true
  L=$(multi_json_get '.global.language' "${L:-C}")
  L=${L^^}
  SERVER_IP=$(multi_json_get '.global.server_ip' "$SERVER_IP")
  PORT_NGINX=$(multi_json_get '.global.nginx_port' "$PORT_NGINX")
  TLS_SERVER_DEFAULT=$(multi_json_get '.global.tls_server' "$TLS_SERVER_DEFAULT")
  STRATEGY=$(multi_json_get '.global.dns_strategy' prefer_ipv4)
  MULTI_CDN=$(multi_json_get '.global.cdn' "${CDN_DOMAIN[0]}")
  MULTI_ARGO_DOMAIN=$(multi_json_get '.global.argo_domain')
  ARGO_DOMAIN="$MULTI_ARGO_DOMAIN"
  ARGO_AUTH=$(multi_json_get '.global.argo_auth')
  if multi_json_bool '.global.argo'; then
    [ -n "$ARGO_DOMAIN" ] || error " JSON multi-subscriptions with Argo requires global.argo_domain. "
    IS_ARGO=is_argo
  else
    IS_ARGO=no_argo
  fi
  MULTI_IS_ARGO="$IS_ARGO"
}

multi_validate_config() {
  local SUB_COUNT SUB_INDEX NODE_COUNT NODE_INDEX SUB_UUID SUB_NAME EXISTING_SUB
  local EXISTING_TAG EXISTING_PATH

  multi_config_has_subscriptions || error " JSON config has no subscriptions. Edit ${MULTI_CONFIG_FILE} first. "

  MULTI_USED_PORTS=()
  MULTI_USED_SUBS=()
  MULTI_USED_TAGS=()
  MULTI_USED_WS_PATHS=()
  multi_assert_unique_port "$PORT_NGINX" nginx

  SUB_COUNT=$(jq_exec '.subscriptions | length' "$MULTI_CONFIG_FILE")
  for ((SUB_INDEX=0; SUB_INDEX<SUB_COUNT; SUB_INDEX++)); do
    SUB_UUID=$(multi_json_get ".subscriptions[$SUB_INDEX].uuid")
    multi_validate_uuid "$SUB_UUID" "subscriptions[$SUB_INDEX].uuid"
    for EXISTING_SUB in "${MULTI_USED_SUBS[@]}"; do
      [ "$EXISTING_SUB" = "$SUB_UUID" ] && error " Duplicate subscription uuid: ${SUB_UUID}. "
    done
    MULTI_USED_SUBS+=("$SUB_UUID")

    SUB_NAME=$(multi_json_get ".subscriptions[$SUB_INDEX].name" "订阅 $((SUB_INDEX + 1))")
    NODE_COUNT=$(jq_exec ".subscriptions[$SUB_INDEX].nodes | length" "$MULTI_CONFIG_FILE")
    [ "$NODE_COUNT" -gt 0 ] || error " subscriptions[$SUB_INDEX].nodes cannot be empty. "
    for ((NODE_INDEX=0; NODE_INDEX<NODE_COUNT; NODE_INDEX++)); do
      multi_reset_node_context
      multi_apply_node_context "$SUB_INDEX" "$NODE_INDEX" "$SUB_UUID" "$SUB_NAME"

      for EXISTING_TAG in "${MULTI_USED_TAGS[@]}"; do
        [ "$EXISTING_TAG" = "$MULTI_CURRENT_TAG" ] && error " Duplicate node tag: ${MULTI_CURRENT_TAG}. Use unique node names. "
      done
      MULTI_USED_TAGS+=("$MULTI_CURRENT_TAG")

      if [[ "$MULTI_CURRENT_CODE" =~ ^[hi]$ ]]; then
        for EXISTING_PATH in "${MULTI_USED_WS_PATHS[@]}"; do
          [ "$EXISTING_PATH" = "$MULTI_CURRENT_WS_PATH" ] && error " Duplicate websocket path: /${MULTI_CURRENT_WS_PATH}. "
        done
        MULTI_USED_WS_PATHS+=("$MULTI_CURRENT_WS_PATH")
      fi
    done
  done
  multi_reset_node_context
}

multi_prepare_subscription_templates() {
  local ONLINE_WAIT=0
  while [ ! -s "$TEMP_DIR/clash" ] || [ ! -s "$TEMP_DIR/clash2" ] || [ ! -s "$TEMP_DIR/sing-box-template" ]; do
    sleep 1
    ONLINE_WAIT=$((ONLINE_WAIT + 1))
    [ "$ONLINE_WAIT" -gt 120 ] && error " Subscription template download failed. "
  done
  mkdir -p "${TEMP_DIR}/multi-templates"
  cp -f "${TEMP_DIR}"/{clash,clash2,sing-box-template} "${TEMP_DIR}/multi-templates/"
}

multi_restore_templates_for_export() {
  cp -f "${TEMP_DIR}"/multi-templates/{clash,clash2,sing-box-template} "$TEMP_DIR/" 2>/dev/null || true
}

multi_extract_sing_box_outbounds() {
  local FILE=$1 OUT_FILE=$2 TAG_FILE=$3 IDX
  [ -s "$FILE" ] || return
  IDX=$(jq_exec -r '.outbounds | map(.tag == "♻️ 自动选择") | index(true) // 0' "$FILE")
  [ "$IDX" -gt 0 ] || return
  jq_exec -c --argjson idx "$IDX" '.outbounds[0:$idx][]' "$FILE" >> "$OUT_FILE"
  jq_exec -r --argjson idx "$IDX" '.outbounds[0:$idx][] | .tag' "$FILE" >> "$TAG_FILE"
}

multi_collect_node_subscription() {
  local CODE=$1 NODE_UID=$2
  local SUBSCRIBE_ROOT="${WORK_DIR}/subscribe"
  local SING_BOX_SUB="${SUBSCRIBE_ROOT}/sing-box"

  [ "$CODE" = e ] && multi_patch_shadowtls_subscription "$SING_BOX_SUB" "$NODE_UID"

  [ -s "${SUBSCRIBE_ROOT}/proxies" ] && MULTI_SUB_PROXIES+="
$(sed '1d' "${SUBSCRIBE_ROOT}/proxies")"
  [ -s "${SUBSCRIBE_ROOT}/v2rayn" ] && MULTI_SUB_V2RAYN+="
$(base64 -d "${SUBSCRIBE_ROOT}/v2rayn" 2>/dev/null || true)"
  [ -s "${SUBSCRIBE_ROOT}/shadowrocket" ] && MULTI_SUB_SHADOWROCKET+="
$(base64 -d "${SUBSCRIBE_ROOT}/shadowrocket" 2>/dev/null || true)"
  [ -s "${SUBSCRIBE_ROOT}/neko" ] && MULTI_SUB_NEKO+="
$(base64 -d "${SUBSCRIBE_ROOT}/neko" 2>/dev/null || true)"

  multi_extract_sing_box_outbounds "$SING_BOX_SUB" "$MULTI_SUB_OUTBOUNDS_FILE" "$MULTI_SUB_TAGS_FILE"
}

multi_yaml_insert_before() {
  local CONTENT=$1 PATTERN=$2 LINE=$3
  sed "/$PATTERN/i\\
$LINE" <<< "$CONTENT"
}

multi_write_clash2() {
  local SUB_DIR=$1 YAML PROXY_LINE TAG_LINE
  YAML=$(cat "${TEMP_DIR}/multi-templates/clash2")

  while IFS= read -r PROXY_LINE; do
    [ -n "$PROXY_LINE" ] || continue
    YAML=$(multi_yaml_insert_before "$YAML" "proxy-groups:" "  ${PROXY_LINE}")
  done < <(sed '1d' "${SUB_DIR}/proxies" 2>/dev/null)

  while IFS= read -r TAG_LINE; do
    [ -n "$TAG_LINE" ] || continue
    YAML=$(sed -E "/- name: (♻️ 自动选择|📲 电报消息|💬 OpenAi|📹 油管视频|🎥 奈飞视频|📺 巴哈姆特|📺 哔哩哔哩|🌍 国外媒体|🌏 国内媒体|📢 谷歌FCM|Ⓜ️ 微软Bing|Ⓜ️ 微软云盘|Ⓜ️ 微软服务|🍎 苹果服务|🎮 游戏平台|🎶 网易音乐|🎯 全球直连)|^rules:$/i\\
      - ${TAG_LINE}" <<< "$YAML")
  done < "$MULTI_SUB_TAGS_FILE"

  printf '%s\n' "$YAML" > "${SUB_DIR}/clash2"
}

multi_write_sing_box_subscription() {
  local SUB_DIR=$1 OUTBOUNDS_JSON TAGS_JSON TMP_TEMPLATE
  OUTBOUNDS_JSON=$(jq_exec -s -c '.' "$MULTI_SUB_OUTBOUNDS_FILE")
  TAGS_JSON=$(jq_exec -Rn -c '[inputs | select(length > 0)] | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)' < "$MULTI_SUB_TAGS_FILE")
  TMP_TEMPLATE="${TEMP_DIR}/multi-sing-box-template-expanded.json"
  jq_exec --argjson outbounds "$OUTBOUNDS_JSON" --argjson tags "$TAGS_JSON" '
    def expand:
      if type == "array" then
        reduce .[] as $item ([]; . + (
          if $item == "<OUTBOUND_REPLACE>" then $outbounds
          elif $item == "<NODE_REPLACE>" then $tags
          else [$item | expand]
          end
        ))
      elif type == "object" then
        with_entries(.value |= expand)
      else
        .
      end;
    expand
  ' "${TEMP_DIR}/multi-templates/sing-box-template" > "$TMP_TEMPLATE" && mv "$TMP_TEMPLATE" "${SUB_DIR}/sing-box"
}

multi_write_subscription_files() {
  local SUB_UUID=$1 SUB_NAME=$2 SUB_DIR=$3
  mkdir -p "$SUB_DIR"

  printf '%s\n' "$MULTI_SUB_PROXIES" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' > "${SUB_DIR}/proxies"
  printf '%s' "$MULTI_SUB_V2RAYN" | sed '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/d' | sed -E '/^[ ]*#|^[ ]+|^\{|^\}/d' | sed '/^$/d' | base64 -w0 > "${SUB_DIR}/v2rayn"
  printf '%s' "$MULTI_SUB_SHADOWROCKET" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > "${SUB_DIR}/shadowrocket"
  printf '%s' "$MULTI_SUB_NEKO" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > "${SUB_DIR}/neko"

  cat "${TEMP_DIR}/multi-templates/clash" | sed "s#NODE_NAME#${SUB_NAME}#g; s#PROXY_PROVIDERS_URL#${MULTI_SUBSCRIBE_ADDRESS}/${SUB_UUID}/proxies#g" > "${SUB_DIR}/clash"
  multi_write_clash2 "$SUB_DIR"
  multi_write_sing_box_subscription "$SUB_DIR"
}

multi_export_single_subscription() {
  local SUB_INDEX=$1 SUB_UUID=$2 SUB_NAME=$3 SUB_DIR=$4 SAVE_PREFIX=$5
  local NODE_COUNT NODE_INDEX CODE NODE_IDX NODE_UID

  MULTI_SUB_PROXIES='proxies:'
  MULTI_SUB_V2RAYN=''
  MULTI_SUB_SHADOWROCKET=''
  MULTI_SUB_NEKO=''
  MULTI_SUB_OUTBOUNDS_FILE="${TEMP_DIR}/multi-${SUB_UUID}-outbounds.jsonl"
  MULTI_SUB_TAGS_FILE="${TEMP_DIR}/multi-${SUB_UUID}-tags"
  : > "$MULTI_SUB_OUTBOUNDS_FILE"
  : > "$MULTI_SUB_TAGS_FILE"

  NODE_COUNT=$(jq_exec ".subscriptions[$SUB_INDEX].nodes | length" "$MULTI_CONFIG_FILE")
  for ((NODE_INDEX=0; NODE_INDEX<NODE_COUNT; NODE_INDEX++)); do
    multi_reset_node_context
    SERVER_IP="$MULTI_SERVER_IP"
    IS_SUB=is_sub
    IS_ARGO="$MULTI_IS_ARGO"
    ARGO_DOMAIN="$MULTI_ARGO_DOMAIN"
    ARGO_TYPE="$MULTI_ARGO_TYPE"
    PORT_NGINX="$MULTI_PORT_NGINX"
    CDN="$MULTI_CDN"

    MULTI_SKIP_PORT_CHECK=true
    multi_apply_node_context "$SUB_INDEX" "$NODE_INDEX" "$SUB_UUID" "$SUB_NAME"
    unset MULTI_SKIP_PORT_CHECK

    sing-box_json change
    CODE="$MULTI_CURRENT_CODE"
    NODE_IDX="$MULTI_CURRENT_NODE_IDX"
    NODE_UID="$MULTI_CURRENT_NODE_UID"
    multi_move_generated_inbound "$SAVE_PREFIX" "$CODE" "$NODE_IDX" "$NODE_UID"
    cp "${WORK_DIR}"/conf/${SAVE_PREFIX}_${NODE_UID}_*.json "${TEMP_DIR}/multi-inbounds/" 2>/dev/null || true

    rm -f "${WORK_DIR}"/subscribe/{proxies,clash,clash2,shadowrocket,v2rayn,neko,sing-box,qr}
    multi_restore_templates_for_export
    SERVER_IP="$MULTI_SERVER_IP"
    IS_SUB=is_sub
    IS_ARGO="$MULTI_IS_ARGO"
    ARGO_DOMAIN="$MULTI_ARGO_DOMAIN"
    ARGO_TYPE="$MULTI_ARGO_TYPE"
    UUID_CONFIRM="$SUB_UUID"
    NODE_NAME_CONFIRM="$SUB_NAME"
    PORT_NGINX="$MULTI_PORT_NGINX"
    CDN="$MULTI_CDN"
    export_list install >/dev/null
    multi_collect_node_subscription "$CODE" "$NODE_UID"
  done

  multi_write_subscription_files "$SUB_UUID" "$SUB_NAME" "$SUB_DIR"
}

multi_restore_all_inbounds() {
  local FILE BASENAME
  rm -f "${WORK_DIR}"/conf/*_inbounds.json
  for FILE in "${TEMP_DIR}"/multi-inbounds/*.json; do
    [ -s "$FILE" ] || continue
    BASENAME=$(basename "$FILE")
    cp "$FILE" "${WORK_DIR}/conf/${BASENAME}"
  done
}

is_multi_subscription_install() {
  [ -s "${WORK_DIR}/config.json" ] && jq_exec -e '.subscriptions | type == "array" and length > 0' "${WORK_DIR}/config.json" >/dev/null 2>&1
}

require_not_multi_subscription_install() {
  if is_multi_subscription_install; then
    error " Multi-subscription JSON installs are managed by ${WORK_DIR}/config.json. Please edit JSON and reinstall with --json. "
  fi
}

multi_finalize_subscriptions() {
  local BASE_ADDRESS SUB_UUID SUB_DIR SUB_NAME QR_FILE LIST_FILE
  local V2RAYN_ALL='' SHADOWROCKET_ALL='' PROXIES_ALL='proxies:' NEKO_ALL=''
  local SUB_COUNT SUB_INDEX

  if [[ "$SERVER_IP" =~ : ]]; then
    BASE_ADDRESS="http://[${SERVER_IP}]:${PORT_NGINX}"
  else
    BASE_ADDRESS="http://${SERVER_IP}:${PORT_NGINX}"
  fi
  [[ "$ARGO_TYPE" = 'is_token_argo' || "$ARGO_TYPE" = 'is_json_argo' ]] && BASE_ADDRESS="https://$ARGO_DOMAIN"

  SUB_COUNT=$(jq_exec '.subscriptions | length' "$MULTI_CONFIG_FILE")
  for ((SUB_INDEX=0; SUB_INDEX<SUB_COUNT; SUB_INDEX++)); do
    SUB_UUID=$(multi_json_get ".subscriptions[$SUB_INDEX].uuid")
    SUB_NAME=$(multi_json_get ".subscriptions[$SUB_INDEX].name" "订阅 $((SUB_INDEX + 1))")
    SUB_DIR="${WORK_DIR}/subscribe/${SUB_UUID}"
    [ -d "$SUB_DIR" ] || continue

    [ -s "${SUB_DIR}/v2rayn" ] && V2RAYN_ALL+="
*******************************************
${SUB_NAME}
$(base64 -d "${SUB_DIR}/v2rayn" 2>/dev/null || true)
"
    [ -s "${SUB_DIR}/shadowrocket" ] && SHADOWROCKET_ALL+="
*******************************************
${SUB_NAME}
$(base64 -d "${SUB_DIR}/shadowrocket" 2>/dev/null || true)
"
    [ -s "${SUB_DIR}/proxies" ] && PROXIES_ALL+="
$(sed '1d' "${SUB_DIR}/proxies")
"
    [ -s "${SUB_DIR}/neko" ] && NEKO_ALL+="
*******************************************
${SUB_NAME}
$(base64 -d "${SUB_DIR}/neko" 2>/dev/null || true)
"

    QR_FILE="${SUB_DIR}/qr"
    cat > "$QR_FILE" << EOF
$(text 81):
$(text 82) 1:
${BASE_ADDRESS}/${SUB_UUID}/auto

$(text 82) 2:
${BASE_ADDRESS}/${SUB_UUID}/auto2

Index:
${BASE_ADDRESS}/${SUB_UUID}/

V2rayN $(text 80):
${BASE_ADDRESS}/${SUB_UUID}/v2rayn

Clash $(text 80):
${BASE_ADDRESS}/${SUB_UUID}/clash
${BASE_ADDRESS}/${SUB_UUID}/clash2

SFI / SFA / SFM $(text 80):
${BASE_ADDRESS}/${SUB_UUID}/sing-box

ShadowRocket $(text 80):
${BASE_ADDRESS}/${SUB_UUID}/shadowrocket
EOF
    if [ -x "${WORK_DIR}/qrencode" ]; then
      {
        printf '\n%s\n' "$(text 80) QRcode:"
        "${WORK_DIR}/qrencode" "${BASE_ADDRESS}/${SUB_UUID}/auto"
        "${WORK_DIR}/qrencode" "${BASE_ADDRESS}/${SUB_UUID}/auto2"
      } >> "$QR_FILE"
    fi
  done

  LIST_FILE="${WORK_DIR}/list"
  cat > "$LIST_FILE" << EOF
*******************************************
$(warning "Multi subscriptions")

$(hint "Index:")
EOF
  for ((SUB_INDEX=0; SUB_INDEX<SUB_COUNT; SUB_INDEX++)); do
    SUB_UUID=$(multi_json_get ".subscriptions[$SUB_INDEX].uuid")
    SUB_NAME=$(multi_json_get ".subscriptions[$SUB_INDEX].name" "订阅 $((SUB_INDEX + 1))")
    cat >> "$LIST_FILE" << EOF
${SUB_NAME}: ${BASE_ADDRESS}/${SUB_UUID}/
  auto: ${BASE_ADDRESS}/${SUB_UUID}/auto
  auto2: ${BASE_ADDRESS}/${SUB_UUID}/auto2
  v2rayn: ${BASE_ADDRESS}/${SUB_UUID}/v2rayn
  clash: ${BASE_ADDRESS}/${SUB_UUID}/clash
  clash2: ${BASE_ADDRESS}/${SUB_UUID}/clash2
  sing-box: ${BASE_ADDRESS}/${SUB_UUID}/sing-box
  shadowrocket: ${BASE_ADDRESS}/${SUB_UUID}/shadowrocket

EOF
  done

  cat >> "$LIST_FILE" << EOF
*******************************************
$(warning "V2rayN")
$(info "$V2RAYN_ALL")

*******************************************
$(warning "ShadowRocket")
$(hint "$SHADOWROCKET_ALL")

*******************************************
$(warning "Clash Verge")
$(info "$(sed '1d' <<< "$PROXIES_ALL")")

*******************************************
$(warning "Throne")
$(hint "$NEKO_ALL")
EOF

  cat "$LIST_FILE"
}

multi_wait_for_downloads() {
  local ONLINE_WAIT=0
  while [ ! -x "$TEMP_DIR/sing-box" ] && [ ! -x "$WORK_DIR/sing-box" ]; do
    sleep 1
    ONLINE_WAIT=$((ONLINE_WAIT + 1))
    [ "$ONLINE_WAIT" -gt 120 ] && error " sing-box download failed. "
  done
  while [ ! -x "$TEMP_DIR/jq" ] && [ ! -x "$WORK_DIR/jq" ] && ! command -v jq >/dev/null 2>&1; do
    sleep 1
    ONLINE_WAIT=$((ONLINE_WAIT + 1))
    [ "$ONLINE_WAIT" -gt 120 ] && error " jq download failed. "
  done
}

multi_copy_assets() {
  local SB_BIN="${TEMP_DIR}/sing-box"
  local JQ_BIN="${TEMP_DIR}/jq"
  local QRENCODE_BIN="${TEMP_DIR}/qrencode"
  [ -x "$SB_BIN" ] || SB_BIN="${WORK_DIR}/sing-box"
  [ -x "$JQ_BIN" ] || JQ_BIN="${WORK_DIR}/jq"
  [ -x "$QRENCODE_BIN" ] || QRENCODE_BIN="${WORK_DIR}/qrencode"
  [ "$SB_BIN" != "${WORK_DIR}/sing-box" ] && cp "$SB_BIN" "$WORK_DIR"
  [ "$JQ_BIN" != "${WORK_DIR}/jq" ] && cp "$JQ_BIN" "$WORK_DIR"
  [ -x "$QRENCODE_BIN" ] && [ "$QRENCODE_BIN" != "${WORK_DIR}/qrencode" ] && cp "$QRENCODE_BIN" "$WORK_DIR"
  [ -x "${TEMP_DIR}/cloudflared" ] && cp "${TEMP_DIR}/cloudflared" "$WORK_DIR"
}

multi_install_from_json() {
  local CONFIG_PATH=$1
  local RUNTIME_MODE=${2:-vps}
  local SUB_COUNT SUB_INDEX SUB_UUID SUB_NAME SUB_SLUG

  MULTI_CONFIG_FILE=$CONFIG_PATH
  NONINTERACTIVE_INSTALL=noninteractive_install
  L=${L:-C}
  declare -gA MULTI_GENERATED_SECRETS

  if [ "$RUNTIME_MODE" = docker ]; then
    docker_prepare_multi_env
    docker_download_assets
  else
    check_arch
    check_dependencies
    check_install
    multi_wait_for_downloads
  fi
  check_brutal

  multi_init_globals "$MULTI_CONFIG_FILE"
  if ! multi_config_has_subscriptions; then
    mkdir -p "$WORK_DIR"
    [ "$MULTI_CONFIG_FILE" != "${WORK_DIR}/config.json" ] && cp "$MULTI_CONFIG_FILE" "${WORK_DIR}/config.json"
    [ "$RUNTIME_MODE" = docker ] && rm -rf /etc/services.d/sing-box /etc/services.d/nginx /etc/services.d/argo
    [ "$RUNTIME_MODE" = docker ] && info " ${MULTI_CONFIG_FILE} has no subscriptions; edit it and restart the container. " && return 0
    error " JSON config has no subscriptions. Edit ${MULTI_CONFIG_FILE} first. "
  fi

  check_system_ip
  [ -z "$SERVER_IP" ] && SERVER_IP="${WAN4:-$WAN6}"
  [ -z "$SERVER_IP" ] && error " $(text 47) "

  if [ -z "$PORT_NGINX" ]; then
    PORT_NGINX=$START_PORT_DEFAULT
    while ss -nltup 2>/dev/null | grep -q ":$PORT_NGINX"; do
      PORT_NGINX=$((PORT_NGINX + 1))
    done
  fi

  multi_validate_config

  CHATGPT_OUT=warp-ep
  [ "$(check_chatgpt "$(grep -oE '[46]' <<< "${STRATEGY:-prefer_ipv4}")")" = 'unlock' ] && CHATGPT_OUT=direct

  [ "$RUNTIME_MODE" != docker ] && multi_prepare_subscription_templates

  if [ -n "$PORT_NGINX" ] && ! command -v nginx >/dev/null 2>&1; then
    info "\n $(text 7) nginx \n"
    ${PACKAGE_UPDATE[int]} >/dev/null 2>&1
    ${PACKAGE_INSTALL[int]} nginx >/dev/null 2>&1
    cmd_systemctl disable nginx
  fi

  mkdir -p "$WORK_DIR" "$TEMP_DIR/multi-inbounds"
  if [ "$RUNTIME_MODE" != docker ]; then
    [ -s "$SINGBOX_DAEMON_FILE" ] && cmd_systemctl disable sing-box >/dev/null 2>&1 || true
    [ -s "$ARGO_DAEMON_FILE" ] && cmd_systemctl disable argo >/dev/null 2>&1 || true
  fi

  multi_prepare_base_config
  ssl_certificate "$TLS_SERVER_DEFAULT"
  multi_copy_assets
  [ "$MULTI_CONFIG_FILE" != "${WORK_DIR}/config.json" ] && cp "$MULTI_CONFIG_FILE" "${WORK_DIR}/config.json"
  echo "${L^^}" > "${WORK_DIR}/language"
  multi_prepare_subscription_templates

  if [ "$IS_ARGO" = 'is_argo' ]; then
    if [ "$RUNTIME_MODE" = docker ]; then
      docker_prepare_argo
    else
      input_argo_auth is_install
    fi
    [ -n "$ARGO_RUNS" ] || error " Invalid Argo configuration. "
    [ -n "$ARGO_JSON" ] && cp "$TEMP_DIR"/tunnel.* "$WORK_DIR" 2>/dev/null || true
    [ "$RUNTIME_MODE" != docker ] && argo_systemd
  fi

  if [[ "$ARGO_TYPE" = 'is_token_argo' || "$ARGO_TYPE" = 'is_json_argo' ]]; then
    MULTI_SUBSCRIBE_ADDRESS="https://$ARGO_DOMAIN"
  elif [[ "$SERVER_IP" =~ : ]]; then
    MULTI_SUBSCRIBE_ADDRESS="http://[${SERVER_IP}]:${PORT_NGINX}"
  else
    MULTI_SUBSCRIBE_ADDRESS="http://${SERVER_IP}:${PORT_NGINX}"
  fi

  MULTI_SERVER_IP="$SERVER_IP"
  MULTI_PORT_NGINX="$PORT_NGINX"
  MULTI_IS_ARGO="$IS_ARGO"
  MULTI_ARGO_TYPE="$ARGO_TYPE"
  MULTI_ARGO_DOMAIN="$ARGO_DOMAIN"
  MULTI_NGINX_WS_LOCATIONS=''

  SUB_COUNT=$(jq_exec '.subscriptions | length' "$MULTI_CONFIG_FILE")
  for ((SUB_INDEX=0; SUB_INDEX<SUB_COUNT; SUB_INDEX++)); do
    SUB_UUID=$(multi_json_get ".subscriptions[$SUB_INDEX].uuid")
    SUB_NAME=$(multi_json_get ".subscriptions[$SUB_INDEX].name" "订阅 $((SUB_INDEX + 1))")
    SUB_SLUG=$(printf '%02d_%s' "$((SUB_INDEX + 1))" "$SUB_UUID")
    multi_export_single_subscription "$SUB_INDEX" "$SUB_UUID" "$SUB_NAME" "${WORK_DIR}/subscribe/${SUB_UUID}" "$SUB_SLUG"
  done

  multi_restore_all_inbounds
  PORT_NGINX="$MULTI_PORT_NGINX"
  IS_MULTI_SUBSCRIPTIONS=is_multi_subscriptions
  export_nginx_conf_file

  if [ "$RUNTIME_MODE" = docker ]; then
    docker_write_services
    multi_finalize_subscriptions
    return 0
  fi

  sing-box_systemd
  cmd_systemctl enable sing-box
  [ -s "$ARGO_DAEMON_FILE" ] && cmd_systemctl enable argo
  sleep 2
  sync_firewall_rules
  check_install
  multi_finalize_subscriptions
  create_shortcut
}
