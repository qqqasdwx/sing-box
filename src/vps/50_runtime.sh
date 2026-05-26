# 安装 sing-box 全家桶
install_sing-box() {
  sing-box_variables
  if [ -n "$PORT_NGINX" ] && ! command -v nginx >/dev/null 2>&1; then
    info "\n $(text 7) nginx \n"
    ${PACKAGE_UPDATE[int]} >/dev/null 2>&1
    ${PACKAGE_INSTALL[int]} nginx >/dev/null 2>&1
    cmd_systemctl disable nginx
  fi
  [ ! -d ${WORK_DIR}/logs ] && mkdir -p ${WORK_DIR}/logs
  [ ! -d ${TEMP_DIR} ] && mkdir -p $TEMP_DIR
  ssl_certificate $TLS_SERVER_DEFAULT
  hint "\n $(text 2) " && wait
  sing-box_json
  echo "${L^^}" > ${WORK_DIR}/language
  cp $TEMP_DIR/sing-box $TEMP_DIR/jq ${WORK_DIR}
  [ -x $TEMP_DIR/qrencode ] && cp $TEMP_DIR/qrencode ${WORK_DIR}

  # 生成 sing-box systemd 配置文件
  sing-box_systemd

  # 生成 Argo systemd 配置文件，并复制 cloudflared 可执行二进制文件
  cp $TEMP_DIR/cloudflared ${WORK_DIR}
  [ -n "$ARGO_RUNS" ] && argo_systemd

  # 如果是 Json Argo，把配置文件复制到工作目录
  [ -n "$ARGO_JSON" ] && cp $TEMP_DIR/tunnel.* ${WORK_DIR}

  # 生成 Nginx 配置文件
  [ -n "$PORT_NGINX" ] && export_nginx_conf_file

  # 系统启动 sing-box 服务
  cmd_systemctl enable sing-box

  # 等待服务启动
  sleep 2

  # 处理防火墙相关端口
  sync_firewall_rules

  # 检查服务是否成功启动
  if cmd_systemctl status sing-box &>/dev/null; then
    STATUS[0]=$(text 28)
    info "\n Sing-box $(text 28) $(text 37) \n"
  else
    STATUS[0]=$(text 27)
    error "\n Sing-box $(text 27) $(text 38) \n"
    # 如果启动失败，再尝试重启
    cmd_systemctl restart sing-box
  fi

  # 如果配置了 Argo，也启动 Argo 服务
  if [ -s ${ARGO_DAEMON_FILE} ]; then
    cmd_systemctl enable argo

    sleep 2

    # 检查 Argo 服务是否成功启动
    if cmd_systemctl status argo &>/dev/null; then
      STATUS[1]=$(text 28)
      info "\n Argo $(text 28) $(text 37) \n"
    else
      STATUS[1]=$(text 27)
      error "\n Argo $(text 27) $(text 38) \n"
      # 如果启动失败，再尝试重启
      cmd_systemctl restart argo
    fi
  fi
}

export_list() {
  IS_INSTALL=$1

  check_install

  [ "$IS_INSTALL" != 'install' ] && fetch_nodes_value

  # IPv6 时的 IP 处理
  if [[ "$SERVER_IP" =~ : ]]; then
    SERVER_IP_1="[$SERVER_IP]"
    SERVER_IP_2="[[$SERVER_IP]]"
  else
    SERVER_IP_1="$SERVER_IP"
    SERVER_IP_2="$SERVER_IP"
  fi

  # 使用 Argo 时，获取临时隧道域名
  ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1 && [ "$IS_ARGO" = 'is_argo' ] && [ -z "$ARGO_DOMAIN" ] && [[ "${STATUS[1]}" = "$(text 28)" || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]] && fetch_quicktunnel_domain

  # 如果使用 Json 或者 Token Argo，则使用加密的而且是固定的 Argo 隧道域名，否则使用 IP:PORT 的 http 服务
  [[ "$ARGO_TYPE" = 'is_token_argo' || "$ARGO_TYPE" = 'is_json_argo' ]] && SUBSCRIBE_ADDRESS="https://$ARGO_DOMAIN" || SUBSCRIBE_ADDRESS="http://${SERVER_IP_1}:${PORT_NGINX}"

  # v1.3.0 (2025.11.10)及之后 reality 使用 xtls-rprx-vision 流控替代多路复用 multiplex，但为了兼容旧版本已安装的客户端 URI，在这里作判断
  if [ -n "$PORT_XTLS_REALITY" ]; then
    local FLOW="$(awk -F '"' '/"flow"/{print $4}' ${WORK_DIR}/conf/*_${NODE_TAG[0]}_inbounds.json)"

    if [ "${FLOW}" = 'xtls-rprx-vision' ]; then
      local VISION_OR_MUX_SHADOWROCKET='xtls=2' && local VISION_FLOW='&flow=xtls-rprx-vision' && local VISION_OR_MUX_CLASH=', flow: xtls-rprx-vision' && local MULTIPLEX_PADDING_ENABLED='false' && local VISION_BRUTAL_ENABLED='false'
    else
      local VISION_OR_MUX_SHADOWROCKET='mux=1' && local MULTIPLEX_PADDING_ENABLED='true' && local VISION_BRUTAL_ENABLED="${IS_BRUTAL}"
    fi
  fi

  # 获取自签证书指纹。origin rules 或者 argo 回源的是由 Google Trust Services（谷歌信任服务）作为中间 CA（CN=WE1）签发，受信任的证书（非自签名）
  local SELF_SIGNED_FINGERPRINT_SHA256=$(openssl x509 -fingerprint -noout -sha256 -in ${WORK_DIR}/cert/cert.pem | awk -F '=' '{print $NF}')
  local SELF_SIGNED_FINGERPRINT_BASE64=$(openssl x509 -in ${WORK_DIR}/cert/cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64)

  local CERT_URL_1=$(awk '{printf "%s,", $0}' ${WORK_DIR}/cert/cert.pem | sed 's/ /%20/g; s/,$//') &&
  local CERT_URL_2=$(awk '{printf "%s\\r\\n", $0}' ${WORK_DIR}/cert/cert.pem)
  [ -s ${WORK_DIR}/cert/cert_200.pem ] &&
  local CERT_200_URL_1=$(awk '{printf "%s,", $0}' ${WORK_DIR}/cert/cert_200.pem | sed 's/,$//') &&
  local CERT_200_URL_2=$(awk '{printf "%s\\r\\n", $0}' ${WORK_DIR}/cert/cert_200.pem)

  # 从自签证书的 SAN 中读取当前使用的 SNI，优先取 SAN，退回到 CN
  local TLS_SERVER=$(openssl x509 -noout -ext subjectAltName -in ${WORK_DIR}/cert/cert.pem 2>/dev/null | awk -F 'DNS:' '/DNS:/{gsub(/,.*/, "", $2); print $2}')

  # naive 协议的特殊处理
  if [ -n "$PORT_NAIVE" ]; then
    # 在 -n 查看节点时，如 cert_200.pem 过期 / 缺失 / SNI 不一致则自动更新
    ssl_certificate "$TLS_SERVER" naive_only

    # 读取 naive 自签证书并格式化为 JSON 字符串数组内容；多行/单行位置共用这一个变量
    local CERT200_JSON=$(awk 'BEGIN{sep=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s\"%s\"", sep, $0; sep=",\n"}' "${WORK_DIR}/cert/cert_200.pem")

    # 获取 naive 自签名证书的指纹
    local SELF_SIGNED_200_FINGERPRINT_SHA256=$(openssl x509 -fingerprint -noout -sha256 -in ${WORK_DIR}/cert/cert_200.pem | awk -F '=' '{print $NF}')
  fi

  # 生成各订阅文件
  # 生成 Clash proxy providers 订阅文件
  local CLASH_SUBSCRIBE='proxies:'

  [ -n "$PORT_XTLS_REALITY" ] && local CLASH_XTLS_REALITY="- {name: \"${NODE_NAME[11]} ${NODE_TAG[0]}\", type: vless, server: ${SERVER_IP}, port: ${PORT_XTLS_REALITY}, uuid: ${UUID[11]}, network: tcp, udp: true, tls: true${VISION_OR_MUX_CLASH}, servername: ${TLS_SERVER}, client-fingerprint: firefox, reality-opts: {public-key: ${REALITY_PUBLIC[11]}, short-id: \"\"}, smux: { enabled: ${MULTIPLEX_PADDING_ENABLED}, protocol: 'h2mux', padding: ${MULTIPLEX_PADDING_ENABLED}, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${VISION_BRUTAL_ENABLED}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_XTLS_REALITY
"
  if [ -n "$PORT_HYSTERIA2" ]; then
    [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && local CLASH_HOPPING=" ports: ${PORT_HOPPING_START}-${PORT_HOPPING_END}, hop-interval: 30,"
    local HY2_UP=${HY2_UP:-200}
    local HY2_DOWN=${HY2_DOWN:-1000}
    local CLASH_REALM_OPTS=""
    if [ "$IS_HY2_REALM" = 'is_hy2_realm' ]; then
      HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]}}"
      CLASH_REALM_OPTS=", realm-opts: {enable: true, server-url: \"https://realm.hy2.io\", token: public, realm-id: \"${HY2_REALM_ID}\", stun-servers: [turn.cloudflare.com:3478, stun.nextcloud.com:3478, stun.sip.us:3478, global.stun.twilio.com:3478]}"
    fi
    local CLASH_HYSTERIA2="- {name: \"${NODE_NAME[12]} ${NODE_TAG[1]}\", type: hysteria2, server: ${SERVER_IP}, port: ${PORT_HYSTERIA2},${CLASH_HOPPING} up: \"${HY2_UP} Mbps\", down: \"${HY2_DOWN} Mbps\", password: ${UUID[12]}, sni: ${TLS_SERVER}, skip-cert-verify: false, fingerprint: ${SELF_SIGNED_FINGERPRINT_SHA256}${CLASH_REALM_OPTS}}" &&
    local CLASH_SUBSCRIBE+="
  $CLASH_HYSTERIA2
"
  fi

  [ -n "$PORT_TUIC" ] && local CLASH_TUIC="- {name: \"${NODE_NAME[13]} ${NODE_TAG[2]}\", type: tuic, server: ${SERVER_IP}, port: ${PORT_TUIC}, uuid: ${UUID[13]}, password: ${TUIC_PASSWORD}, alpn: [h3], reduce-rtt: true, request-timeout: 8000, udp-relay-mode: native, congestion-controller: $TUIC_CONGESTION_CONTROL, sni: ${TLS_SERVER}, skip-cert-verify: false, fingerprint: ${SELF_SIGNED_FINGERPRINT_SHA256}}" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_TUIC
"
  [ -n "$PORT_SHADOWTLS" ] && local CLASH_SHADOWTLS="- {name: \"${NODE_NAME[14]} ${NODE_TAG[3]}\", type: ss, server: ${SERVER_IP}, port: ${PORT_SHADOWTLS}, cipher: $SHADOWTLS_METHOD, password: $SHADOWTLS_PASSWORD, plugin: shadow-tls, client-fingerprint: firefox, plugin-opts: {host: ${TLS_SERVER}, password: \"${UUID[14]}\", version: 3}, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_SHADOWTLS
"

  [ -n "$PORT_SHADOWSOCKS" ] && local CLASH_SHADOWSOCKS="- {name: \"${NODE_NAME[15]} ${NODE_TAG[4]}\", type: ss, server: ${SERVER_IP}, port: $PORT_SHADOWSOCKS, cipher: ${SHADOWSOCKS_METHOD}, password: ${SHADOWSOCKS_PASSWORD}, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_SHADOWSOCKS
"
  [ -n "$PORT_TROJAN" ] && local CLASH_TROJAN="- {name: \"${NODE_NAME[16]} ${NODE_TAG[5]}\", type: trojan, server: ${SERVER_IP}, port: $PORT_TROJAN, password: $TROJAN_PASSWORD, client-fingerprint: firefox, sni: ${TLS_SERVER}, skip-cert-verify: false, fingerprint: ${SELF_SIGNED_FINGERPRINT_SHA256}, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_TROJAN
"
  if [ -n "$PORT_VMESS_WS" ]; then
    local VMESS_CDN_PORT=${CDN_PORT[17]:-80}
    local VMESS_CDN_SERVER=$(format_uri_host "${CDN[17]}")
    if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local CLASH_VMESS_WS="- {name: \"${NODE_NAME[17]} ${NODE_TAG[6]}\", type: vmess, server: ${VMESS_CDN_SERVER}, port: ${VMESS_CDN_PORT}, uuid: ${UUID[17]}, udp: true, tls: false, alterId: 0, cipher: auto, network: ws, ws-opts: { path: \"/$VMESS_WS_PATH\", headers: {Host: $ARGO_DOMAIN} }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
      local CLASH_SUBSCRIBE+="
  $CLASH_VMESS_WS
"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && CLASH_SUBSCRIBE+="
  # $(text 94)
"
    else
      local CLASH_VMESS_WS="- {name: \"${NODE_NAME[17]} ${NODE_TAG[6]}\", type: vmess, server: ${VMESS_CDN_SERVER}, port: ${VMESS_CDN_PORT}, uuid: ${UUID[17]}, udp: true, tls: false, alterId: 0, cipher: auto, network: ws, ws-opts: { path: \"/$VMESS_WS_PATH\", headers: {Host: $VMESS_HOST_DOMAIN} }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
      local WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} && local TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN && local TYPE_PORT_WS=$PORT_VMESS_WS &&
      local CLASH_SUBSCRIBE+="
  $CLASH_VMESS_WS

  # $(text 52)
"
    fi
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_SERVER=$(format_uri_host "${CDN[18]}")
     if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local CLASH_VLESS_WS="- {name: \"${NODE_NAME[18]} ${NODE_TAG[7]}\", type: vless, server: ${VLESS_CDN_SERVER}, port: ${VLESS_CDN_PORT}, uuid: ${UUID[18]}, udp: true, tls: true, servername: $ARGO_DOMAIN, network: ws, skip-cert-verify: false, ws-opts: { path: \"/$VLESS_WS_PATH\", headers: {Host: $ARGO_DOMAIN}, max-early-data: 2560, early-data-header-name: Sec-WebSocket-Protocol }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
      local CLASH_SUBSCRIBE+="
  $CLASH_VLESS_WS
"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && CLASH_SUBSCRIBE+="
  # $(text 94)
"
    else
      local CLASH_VLESS_WS="- {name: \"${NODE_NAME[18]} ${NODE_TAG[7]}\", type: vless, server: ${VLESS_CDN_SERVER}, port: ${VLESS_CDN_PORT}, uuid: ${UUID[18]}, udp: true, tls: true, servername: $VLESS_HOST_DOMAIN, network: ws, skip-cert-verify: false, ws-opts: { path: \"/$VLESS_WS_PATH\", headers: {Host: $VLESS_HOST_DOMAIN}, max-early-data: 2560, early-data-header-name: Sec-WebSocket-Protocol }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
      local WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} && local TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN && local TYPE_PORT_WS=$PORT_VLESS_WS &&
      local CLASH_SUBSCRIBE+="
  $CLASH_VLESS_WS

  # $(text 52)
"
    fi
  fi

  [ -n "$PORT_H2_REALITY" ] && local CLASH_H2_REALITY="- {name: \"${NODE_NAME[19]} ${NODE_TAG[8]}\", type: vless, server: ${SERVER_IP}, port: ${PORT_H2_REALITY}, uuid: ${UUID[19]}, network: http, tls: true, servername: ${TLS_SERVER}, client-fingerprint: firefox, reality-opts: { public-key: ${REALITY_PUBLIC[19]}, short-id: \"\" }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_H2_REALITY
"

  [ -n "$PORT_GRPC_REALITY" ] && local CLASH_GRPC_REALITY="- {name: \"${NODE_NAME[20]} ${NODE_TAG[9]}\", type: vless, server: ${SERVER_IP}, port: ${PORT_GRPC_REALITY}, uuid: ${UUID[20]}, network: grpc, tls: true, udp: true, flow: , client-fingerprint: firefox, servername: ${TLS_SERVER}, grpc-opts: {  grpc-service-name: \"grpc\" }, reality-opts: { public-key: ${REALITY_PUBLIC[20]}, short-id: \"\" }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_GRPC_REALITY
"

  [ -n "$PORT_ANYTLS" ] && local CLASH_ANYTLS="- {name: \"${NODE_NAME[21]} ${NODE_TAG[10]}\", type: anytls, server: ${SERVER_IP}, port: $PORT_ANYTLS, password: ${UUID[21]}, client-fingerprint: firefox, udp: true, idle-session-check-interval: 30, idle-session-timeout: 30, sni: ${TLS_SERVER}, skip-cert-verify: false, fingerprint: ${SELF_SIGNED_FINGERPRINT_SHA256} }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_ANYTLS
"

  echo -n "${CLASH_SUBSCRIBE}" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' > ${WORK_DIR}/subscribe/proxies

  # 后台生成 clash 订阅配置文件
  {
    # 模板1: 使用 proxy providers
    cat ${TEMP_DIR}/clash | sed "s#NODE_NAME#${NODE_NAME_CONFIRM}#g; s#PROXY_PROVIDERS_URL#$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/proxies#" > ${WORK_DIR}/subscribe/clash

    # 模板2: 不使用 proxy providers
    CLASH2_PORT=("$PORT_XTLS_REALITY" "$PORT_HYSTERIA2" "$PORT_TUIC" "$PORT_SHADOWTLS" "$PORT_SHADOWSOCKS" "$PORT_TROJAN" "$PORT_VMESS_WS" "$PORT_VLESS_WS" "$PORT_GRPC_REALITY" "$PORT_ANYTLS")
    CLASH2_PROXY_INSERT=("$CLASH_XTLS_REALITY" "$CLASH_HYSTERIA2" "$CLASH_TUIC" "$CLASH_SHADOWTLS" "$CLASH_SHADOWSOCKS" "$CLASH_TROJAN" "$CLASH_VMESS_WS" "$CLASH_VLESS_WS" "$CLASH_GRPC_REALITY" "$CLASH_ANYTLS")
    CLASH2_PROXY_GROUPS_INSERT=("- ${NODE_NAME[11]} ${NODE_TAG[0]}" "- ${NODE_NAME[12]} ${NODE_TAG[1]}" "- ${NODE_NAME[13]} ${NODE_TAG[2]}" "- ${NODE_NAME[14]} ${NODE_TAG[3]}" "- ${NODE_NAME[15]} ${NODE_TAG[4]}" "- ${NODE_NAME[16]} ${NODE_TAG[5]}" "- ${NODE_NAME[17]} ${NODE_TAG[6]}" "- ${NODE_NAME[18]} ${NODE_TAG[7]}" "- ${NODE_NAME[20]} ${NODE_TAG[9]}" "- ${NODE_NAME[21]} ${NODE_TAG[10]}")

    CLASH2_YAML=$(cat ${TEMP_DIR}/clash2)
    for x in "${!CLASH2_PORT[@]}"; do
      [[ ${CLASH2_PORT[x]} =~ [0-9]+ ]] && { CLASH2_YAML=$(sed "/proxy-groups:/i\  ${CLASH2_PROXY_INSERT[x]}" <<< "$CLASH2_YAML"); CLASH2_YAML=$(sed -E "/- name: (♻️ 自动选择|📲 电报消息|💬 OpenAi|📹 油管视频|🎥 奈飞视频|📺 巴哈姆特|📺 哔哩哔哩|🌍 国外媒体|🌏 国内媒体|📢 谷歌FCM|Ⓜ️ 微软Bing|Ⓜ️ 微软云盘|Ⓜ️ 微软服务|🍎 苹果服务|🎮 游戏平台|🎶 网易音乐|🎯 全球直连)|^rules:$/i\      ${CLASH2_PROXY_GROUPS_INSERT[x]}" <<< "$CLASH2_YAML"); }
    done
    echo "$CLASH2_YAML" > ${WORK_DIR}/subscribe/clash2

    rm -f ${TEMP_DIR}/clash{,2}
  } &>/dev/null

  # 生成 ShadowRocket 订阅配置文件
  [ -n "$PORT_XTLS_REALITY" ] && local SHADOWROCKET_SUBSCRIBE+="
vless://$(echo -n "auto:${UUID[11]}@${SERVER_IP_2}:${PORT_XTLS_REALITY}" | base64 -w0)?remarks=${NODE_NAME[11]// /%20}%20${NODE_TAG[0]}&tls=1&peer=${TLS_SERVER}&${VISION_OR_MUX_SHADOWROCKET}&pbk=${REALITY_PUBLIC[11]}
"
  if [ -n "$PORT_HYSTERIA2" ]; then
    local SHADOWROCKET_PARAMS="peer=${TLS_SERVER}&hpkp=${SELF_SIGNED_FINGERPRINT_SHA256}&obfs=none&upmbps=${HY2_UP}&downmbps=${HY2_DOWN}"
    [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && SHADOWROCKET_PARAMS+="&keepalive=30&mport=${PORT_HYSTERIA2},${PORT_HOPPING_START}-${PORT_HOPPING_END}"
    local SHADOWROCKET_SUBSCRIBE+="
hysteria2://${UUID[12]}@${SERVER_IP_1}:${PORT_HYSTERIA2}?${SHADOWROCKET_PARAMS}#${NODE_NAME[12]// /%20}%20${NODE_TAG[1]}
"
  fi
  [ -n "$PORT_TUIC" ] && local SHADOWROCKET_SUBSCRIBE+="
tuic://${TUIC_PASSWORD}:${UUID[13]}@${SERVER_IP_2}:${PORT_TUIC}?peer=${TLS_SERVER}&congestion_control=$TUIC_CONGESTION_CONTROL&udp_relay_mode=native&alpn=h3&hpkp=${SELF_SIGNED_FINGERPRINT_SHA256}#${NODE_NAME[13]// /%20}%20${NODE_TAG[2]}
"
  [ -n "$PORT_SHADOWTLS" ] && local SHADOWROCKET_SUBSCRIBE+="
ss://$(echo -n "$SHADOWTLS_METHOD:$SHADOWTLS_PASSWORD@${SERVER_IP_2}:${PORT_SHADOWTLS}" | base64 -w0)?shadow-tls=$(echo -n "{\"version\":\"3\",\"host\":\"${TLS_SERVER}\",\"password\":\"${UUID[14]}\"}" | base64 -w0)#${NODE_NAME[14]// /%20}%20${NODE_TAG[3]}
"
  [ -n "$PORT_SHADOWSOCKS" ] && local SHADOWROCKET_SUBSCRIBE+="
ss://$(echo -n "${SHADOWSOCKS_METHOD}:${SHADOWSOCKS_PASSWORD}@${SERVER_IP_2}:$PORT_SHADOWSOCKS" | base64 -w0)#${NODE_NAME[15]// /%20}%20${NODE_TAG[4]}
"
  [ -n "$PORT_TROJAN" ] && local SHADOWROCKET_SUBSCRIBE+="
trojan://${TROJAN_PASSWORD}@${SERVER_IP_1}:$PORT_TROJAN?peer=${TLS_SERVER}&hpkp=${SELF_SIGNED_FINGERPRINT_SHA256}#${NODE_NAME[16]// /%20}%20${NODE_TAG[5]}
"
  if [ -n "$PORT_VMESS_WS" ]; then
    local VMESS_CDN_PORT=${CDN_PORT[17]:-80}
    local VMESS_CDN_HOST=$(format_uri_host "${CDN[17]}")
     if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "auto:${UUID[17]}@${VMESS_CDN_HOST}:${VMESS_CDN_PORT}" | base64 -w0)?remarks=${NODE_NAME[17]// /%20}%20${NODE_TAG[6]}&obfsParam=$ARGO_DOMAIN&path=/$VMESS_WS_PATH&obfs=websocket&alterId=0
"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && SHADOWROCKET_SUBSCRIBE+="
  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} && TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VMESS_WS && local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "auto:${UUID[17]}@${VMESS_CDN_HOST}:${VMESS_CDN_PORT}" | base64 -w0)?remarks=${NODE_NAME[17]// /%20}%20${NODE_TAG[6]}&obfsParam=$VMESS_HOST_DOMAIN&path=/$VMESS_WS_PATH&obfs=websocket&alterId=0

# $(text 52)
"
    fi
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_HOST=$(format_uri_host "${CDN[18]}")
     if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vless://$(echo -n "auto:${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}" | base64 -w0)?remarks=${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}&obfsParam=$ARGO_DOMAIN&path=/$VLESS_WS_PATH?ed=2560&obfs=websocket&tls=1&peer=$ARGO_DOMAIN
"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && SHADOWROCKET_SUBSCRIBE+="
  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} && TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VLESS_WS && local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vless://$(echo -n "auto:${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}" | base64 -w0)?remarks=${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}&obfsParam=$VLESS_HOST_DOMAIN&path=/$VLESS_WS_PATH?ed=2560&obfs=websocket&tls=1&peer=$VLESS_HOST_DOMAIN

# $(text 52)
"
    fi
  fi

  [ -n "$PORT_H2_REALITY" ] && local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vless://$(echo -n auto:${UUID[19]}@${SERVER_IP_2}:${PORT_H2_REALITY} | base64 -w0)?remarks=${NODE_NAME[19]// /%20}%20${NODE_TAG[8]}&path=/&obfs=h2&tls=1&peer=${TLS_SERVER}&alpn=h2&mux=1&pbk=${REALITY_PUBLIC[19]}
"
  [ -n "$PORT_GRPC_REALITY" ] && local SHADOWROCKET_SUBSCRIBE+="
vless://$(echo -n "auto:${UUID[20]}@${SERVER_IP_2}:${PORT_GRPC_REALITY}" | base64 -w0)?remarks=${NODE_NAME[20]// /%20}%20${NODE_TAG[9]}&path=grpc&obfs=grpc&tls=1&peer=${TLS_SERVER}&pbk=${REALITY_PUBLIC[20]}
"
  [ -n "$PORT_ANYTLS" ] && local SHADOWROCKET_SUBSCRIBE+="
anytls://${UUID[21]}@${SERVER_IP_1}:${PORT_ANYTLS}?peer=${TLS_SERVER}&udp=1&hpkp=${SELF_SIGNED_FINGERPRINT_SHA256}#${NODE_NAME[21]// /%20}%20${NODE_TAG[10]}
"
  [ -n "$PORT_NAIVE" ] && local SHADOWROCKET_SUBSCRIBE+="
http2://$(echo -n "${UUID[22]}:${UUID[22]}@${SERVER_IP_2}:${PORT_NAIVE}" | base64 -w0)?peer=${TLS_SERVER}&alpn=h2,http/1.1&padding=1&uot=2&hpkp=${SELF_SIGNED_200_FINGERPRINT_SHA256}#${NODE_NAME[22]// /%20}%20${NODE_TAG[11]}%20http2

http3://$(echo -n "${UUID[22]}:${UUID[22]}@${SERVER_IP_2}:${PORT_NAIVE}" | base64 -w0)?peer=${TLS_SERVER}&alpn=h3&padding=1&hpkp=${SELF_SIGNED_200_FINGERPRINT_SHA256}#${NODE_NAME[22]// /%20}%20${NODE_TAG[11]}%20http3
"
  echo -n "$SHADOWROCKET_SUBSCRIBE" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > ${WORK_DIR}/subscribe/shadowrocket

  # 生成 V2rayN 订阅文件
  [ -n "$PORT_XTLS_REALITY" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID[11]}@${SERVER_IP_1}:${PORT_XTLS_REALITY}?encryption=none${VISION_FLOW}&security=reality&sni=${TLS_SERVER}&fp=firefox&pbk=${REALITY_PUBLIC[11]}&type=tcp&headerType=none#${NODE_NAME[11]// /%20}%20${NODE_TAG[0]}"

  if [ -n "$PORT_HYSTERIA2" ]; then
    [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && local V2RAYN_PARAMS=",\"Ports\":\"${PORT_HOPPING_START}-${PORT_HOPPING_END}\",\"HopInterval\":\"30s\""
    local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://hysteria2/$(echo -n "{\"ConfigType\":7,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[12]} ${NODE_TAG[1]}\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_HYSTERIA2},\"Password\":\"${UUID[12]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Cert\":\"${CERT_URL_2}\",\"ProtoExtraObj\":{\"UpMbps\":${HY2_UP},\"DownMbps\":${HY2_DOWN}${V2RAYN_PARAMS}}}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  fi

  [ -n "$PORT_TUIC" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://tuic/$(echo -n "{\"ConfigType\":8,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[13]} ${NODE_TAG[2]}\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_TUIC},\"Password\":\"${TUIC_PASSWORD}\",\"Username\":\"${UUID[13]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Alpn\":\"h3\",\"Cert\":\"${CERT_URL_2}\",\"ProtoExtraObj\":{\"CongestionControl\":\"bbr\"}}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

  [ -n "$PORT_SHADOWTLS" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
{
    \"log\": {
        \"level\": \"warn\"
    },
    \"inbounds\": [
        {
            \"listen\": \"127.0.0.1\",
            \"listen_port\": ${PORT_SHADOWTLS},
            \"tag\": \"${PROTOCOL_LIST[3]}\",
            \"type\": \"mixed\"
        }
    ],
    \"outbounds\": [
        {
            \"detour\": \"shadowtls-out\",
            \"method\": \"$SHADOWTLS_METHOD\",
            \"password\": \"$SHADOWTLS_PASSWORD\",
            \"type\": \"shadowsocks\",
            \"udp_over_tcp\": false,
            \"multiplex\": {
              \"enabled\": true,
              \"protocol\": \"h2mux\",
              \"max_connections\": 8,
              \"min_streams\": 16,
              \"padding\": true
            }
        },
        {
            \"password\": \"${UUID[14]}\",
            \"server\": \"${SERVER_IP}\",
            \"server_port\": ${PORT_SHADOWTLS},
            \"tag\": \"shadowtls-out\",
            \"tls\": {
                \"enabled\": true,
                \"server_name\": \"${TLS_SERVER}\",
                \"utls\": {
                  \"enabled\": true,
                  \"fingerprint\": \"firefox\"
                }
            },
            \"type\": \"shadowtls\",
            \"version\": 3
        }
    ]
}"
  [ -n "$PORT_SHADOWSOCKS" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
ss://$(echo -n "${SHADOWSOCKS_METHOD}:${SHADOWSOCKS_PASSWORD}@${SERVER_IP_1}:$PORT_SHADOWSOCKS" | base64 -w0)#${NODE_NAME[15]// /%20}%20${NODE_TAG[4]}"

  [ -n "$PORT_TROJAN" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
trojan://$TROJAN_PASSWORD@${SERVER_IP_1}:$PORT_TROJAN?security=tls&insecure=1&allowInsecure=1&pcs=${SELF_SIGNED_FINGERPRINT_SHA256//:/}&type=tcp&headerType=none#${NODE_NAME[16]// /%20}%20${NODE_TAG[5]}"

  if [ -n "$PORT_VMESS_WS" ]; then
    local VMESS_CDN_PORT=${CDN_PORT[17]:-80}
    local VMESS_CDN_HOST=$(format_uri_host "${CDN[17]}")
     if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local V2RAYN_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{ \"v\": \"2\", \"ps\": \"${NODE_NAME[17]} ${NODE_TAG[6]}\", \"add\": \"${VMESS_CDN_HOST}\", \"port\": \"${VMESS_CDN_PORT}\", \"id\": \"${UUID[17]}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"$ARGO_DOMAIN\", \"path\": \"/$VMESS_WS_PATH\", \"tls\": \"\", \"sni\": \"\", \"alpn\": \"\" }" | base64 -w0)"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && V2RAYN_SUBSCRIBE+="

  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} && TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VMESS_WS && local V2RAYN_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{ \"v\": \"2\", \"ps\": \"${NODE_NAME[17]} ${NODE_TAG[6]}\", \"add\": \"${VMESS_CDN_HOST}\", \"port\": \"${VMESS_CDN_PORT}\", \"id\": \"${UUID[17]}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"$VMESS_HOST_DOMAIN\", \"path\": \"/$VMESS_WS_PATH\", \"tls\": \"\", \"sni\": \"\", \"alpn\": \"\" }" | base64 -w0)

# $(text 52)"
    fi
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_HOST=$(format_uri_host "${CDN[18]}")
     if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}?encryption=none&security=tls&sni=$ARGO_DOMAIN&type=ws&host=$ARGO_DOMAIN&path=%2F$VLESS_WS_PATH%3Fed%3D2560#${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && V2RAYN_SUBSCRIBE+="

  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} && TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VLESS_WS && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}?encryption=none&security=tls&sni=$VLESS_HOST_DOMAIN&type=ws&host=$VLESS_HOST_DOMAIN&path=%2F$VLESS_WS_PATH%3Fed%3D2560#${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}

# $(text 52)"
    fi
  fi

  [ -n "$PORT_H2_REALITY" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://vless/$(echo -n "{\"ConfigType\":5,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[19]} ${NODE_TAG[8]}\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_H2_REALITY},\"Password\":\"${UUID[19]}\",\"Network\":\"raw\",\"StreamSecurity\":\"reality\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Fingerprint\":\"firefox\",\"PublicKey\":\"${REALITY_PUBLIC[19]}\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

  [ -n "$PORT_GRPC_REALITY" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID[20]}@${SERVER_IP_1}:${PORT_GRPC_REALITY}?encryption=none&security=reality&sni=${TLS_SERVER}&fp=firefox&pbk=${REALITY_PUBLIC[20]}&type=grpc&serviceName=grpc&mode=gun#${NODE_NAME[20]// /%20}%20${NODE_TAG[9]}"

  [ -n "$PORT_ANYTLS" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://anytls/$(echo -n "{\"ConfigType\":11,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[21]} ${NODE_TAG[10]}\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_ANYTLS},\"Password\":\"${UUID[21]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Fingerprint\":\"firefox\",\"Cert\":\"${CERT_URL_2}\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

  [ -n "$PORT_NAIVE" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://naive/$(echo -n "{\"ConfigType\":12,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[22]} ${NODE_TAG[11]} http2\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_NAIVE},\"Password\":\"${UUID[22]}\",\"Username\":\"${UUID[22]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Cert\":\"${CERT_200_URL_2}\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
----------------------------
v2rayn://naive/$(echo -n "{\"ConfigType\":12,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[22]} ${NODE_TAG[11]} quic\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_NAIVE},\"Password\":\"${UUID[22]}\",\"Username\":\"${UUID[22]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Cert\":\"${CERT_200_URL_2}\",\"ProtoExtraObj\":{\"CongestionControl\":\"bbr\",\"NaiveQuic\":true}}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

  echo -n "$V2RAYN_SUBSCRIBE" | sed '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/d' | sed -E '/^[ ]*#|^[ ]+|^\{|^\}/d' | sed '/^$/d' | base64 -w0 > ${WORK_DIR}/subscribe/v2rayn

  # 生成 Throne 订阅文件
  [ -n "$PORT_XTLS_REALITY" ] && local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[11]}@${SERVER_IP_1}:${PORT_XTLS_REALITY}?security=reality&sni=${TLS_SERVER}&fp=firefox&pbk=${REALITY_PUBLIC[11]}&type=tcp${VISION_FLOW}&encryption=none#${NODE_NAME[11]// /%20}%20${NODE_TAG[0]}"

  if [ -n "$PORT_HYSTERIA2" ]; then
    local THRONE_PARAMS="allowInsecure=true&alpn&security=tls&sni=${TLS_SERVER}&upmbps=${HY2_UP}&downmbps=${HY2_DOWN}&security=tls&tls_certificate=${CERT_URL_1}"
    if [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]]; then
      THRONE_PARAMS+="&mport=${PORT_HOPPING_START}-${PORT_HOPPING_END}&hop_interval=30s"
    fi
    local THRONE_SUBSCRIBE+="
----------------------------
hysteria2://${UUID[12]}@${SERVER_IP_1}:${PORT_HYSTERIA2}?${THRONE_PARAMS}#${NODE_NAME[12]// /%20}%20${NODE_TAG[1]}"
  fi

  [ -n "$PORT_TUIC" ] && local THRONE_SUBSCRIBE+="
----------------------------
tuic://${TUIC_PASSWORD}:${UUID[13]}@${SERVER_IP_1}:${PORT_TUIC}?congestion_control=$TUIC_CONGESTION_CONTROL&alpn=h3&sni=${TLS_SERVER}&udp_relay_mode=native&allow_insecure=1&security=tls&tls_certificate=${CERT_URL_1}#${NODE_NAME[13]// /%20}%20${NODE_TAG[2]}"
  [ -n "$PORT_SHADOWTLS" ] && local THRONE_SUBSCRIBE+="
----------------------------
nekoray://custom#$(echo -n "{\"_v\":0,\"addr\":\"127.0.0.1\",\"cmd\":[\"\"],\"core\":\"internal\",\"cs\":\"{\n    \\\"password\\\": \\\"${UUID[14]}\\\",\n    \\\"server\\\": \\\"${SERVER_IP_1}\\\",\n    \\\"server_port\\\": ${PORT_SHADOWTLS},\n    \\\"tag\\\": \\\"shadowtls-out\\\",\n    \\\"tls\\\": {\n        \\\"enabled\\\": true,\n        \\\"server_name\\\": \\\"${TLS_SERVER}\\\"\n    },\n    \\\"type\\\": \\\"shadowtls\\\",\n    \\\"version\\\": 3\n}\n\",\"mapping_port\":0,\"name\":\"1-tls-not-use\",\"port\":1080,\"socks_port\":0}" | base64 -w0)

nekoray://shadowsocks#$(echo -n "{\"_v\":0,\"method\":\"$SHADOWTLS_METHOD\",\"name\":\"2-ss-not-use\",\"pass\":\"$SHADOWTLS_PASSWORD\",\"port\":0,\"stream\":{\"ed_len\":0,\"insecure\":false,\"mux_s\":0,\"net\":\"tcp\"},\"uot\":0}" | base64 -w0)"

  [ -n "$PORT_SHADOWSOCKS" ] && local THRONE_SUBSCRIBE+="
----------------------------
ss://$(echo -n "${SHADOWSOCKS_METHOD}:${SHADOWSOCKS_PASSWORD}" | base64 -w0)@${SERVER_IP_1}:$PORT_SHADOWSOCKS#${NODE_NAME[15]// /%20}%20${NODE_TAG[4]}"

  [ -n "$PORT_TROJAN" ] && local THRONE_SUBSCRIBE+="
----------------------------
trojan://${TROJAN_PASSWORD}@${SERVER_IP_1}:$PORT_TROJAN?security=tls&sni=${TLS_SERVER}&allowInsecure=1&tls_certificate=${CERT_URL_1}&fp=firefox&type=tcp#${NODE_NAME[16]// /%20}%20${NODE_TAG[5]}"

  if [ -n "$PORT_VMESS_WS" ]; then
     if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      THRONE_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{\"add\":\"${CDN[17]}\",\"aid\":\"0\",\"host\":\"$ARGO_DOMAIN\",\"id\":\"${UUID[17]}\",\"net\":\"ws\",\"path\":\"/$VMESS_WS_PATH\",\"port\":\"80\",\"ps\":\"${NODE_NAME[17]} ${NODE_TAG[6]}\",\"scy\":\"auto\",\"sni\":\"\",\"tls\":\"\",\"type\":\"\",\"v\":\"2\"}" | base64 -w0)"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && THRONE_SUBSCRIBE+="

  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} && TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VMESS_WS && local THRONE_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{\"add\":\"${CDN[17]}\",\"aid\":\"0\",\"host\":\"$VMESS_HOST_DOMAIN\",\"id\":\"${UUID[17]}\",\"net\":\"ws\",\"path\":\"/$VMESS_WS_PATH\",\"port\":\"80\",\"ps\":\"${NODE_NAME[17]} ${NODE_TAG[6]}\",\"scy\":\"auto\",\"sni\":\"\",\"tls\":\"\",\"type\":\"\",\"v\":\"2\"}" | base64 -w0)

# $(text 52)"
    fi
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_HOST=$(format_uri_host "${CDN[18]}")
     if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}?security=tls&sni=$ARGO_DOMAIN&type=ws&path=/$VLESS_WS_PATH?ed%3D2560&host=$ARGO_DOMAIN&encryption=none#${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && THRONE_SUBSCRIBE+="

  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} && TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VLESS_WS && local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}?security=tls&sni=$VLESS_HOST_DOMAIN&type=ws&path=/$VLESS_WS_PATH?ed%3D2560&host=$VLESS_HOST_DOMAIN&encryption=none#${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}

# $(text 52)"
    fi
  fi

  [ -n "$PORT_H2_REALITY" ] && local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[19]}@${SERVER_IP_1}:${PORT_H2_REALITY}?security=reality&sni=${TLS_SERVER}&alpn=h2&fp=firefox&pbk=${REALITY_PUBLIC[19]// /%20}&type=http&encryption=none#${NODE_NAME[19]// /%20}%20${NODE_TAG[8]}"

  [ -n "$PORT_GRPC_REALITY" ] && local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[20]}@${SERVER_IP_1}:${PORT_GRPC_REALITY}?security=reality&sni=${TLS_SERVER}&fp=firefox&pbk=${REALITY_PUBLIC[20]// /%20}&type=grpc&serviceName=grpc&encryption=none#${NODE_NAME[20]// /%20}%20${NODE_TAG[9]}"

  [ -n "$PORT_ANYTLS" ] && local THRONE_SUBSCRIBE+="
----------------------------
anytls://${UUID[21]}@${SERVER_IP_1}:${PORT_ANYTLS}?idle_session_check_interval=30s&idle_session_timeout=30s&min_idle_session=5&insecure=1&security=tls&sni=${TLS_SERVER}&tls_certificate=${CERT_URL_1}&fp=firefox#${NODE_NAME[21]// /%20}%20${NODE_TAG[10]}"

  [ -n "$PORT_NAIVE" ] && {
    local THRONE_SUBSCRIBE+="
----------------------------
naive+https://${UUID[22]}:${UUID[22]}@${SERVER_IP_1}:${PORT_NAIVE}?uot=1&security=tls&sni=${TLS_SERVER}&tls_certificate=${CERT_200_URL_1}#${NODE_NAME[22]// /%20}%20${NODE_TAG[11]}%20http2
----------------------------
naive+quic://${UUID[22]}:${UUID[22]}@${SERVER_IP_1}:${PORT_NAIVE}?congestion_control=bbr&security=tls&sni=${TLS_SERVER}&tls_certificate=${CERT_200_URL_1}#${NODE_NAME[22]// /%20}%20${NODE_TAG[11]}%20quic"
  }

  echo -n "$THRONE_SUBSCRIBE" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > ${WORK_DIR}/subscribe/neko

  # 生成 Sing-box 订阅文件
  [ -n "$PORT_XTLS_REALITY" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[11]} ${NODE_TAG[0]}\", \"server\":\"${SERVER_IP}\", \"server_port\":${PORT_XTLS_REALITY}, \"uuid\":\"${UUID[11]}\", \"flow\":\"${FLOW}\", \"tls\":{ \"enabled\":true, \"server_name\":\"${TLS_SERVER}\", \"utls\":{ \"enabled\":true, \"fingerprint\":\"firefox\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC[11]}\", \"short_id\":\"\" } }, \"multiplex\": { \"enabled\": ${MULTIPLEX_PADDING_ENABLED}, \"protocol\": \"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": ${MULTIPLEX_PADDING_ENABLED}, \"brutal\":{ \"enabled\":${VISION_BRUTAL_ENABLED}, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[11]} ${NODE_TAG[0]}\","

  if [ -n "$PORT_HYSTERIA2" ]; then
    if [ "$IS_HY2_REALM" = 'is_hy2_realm' ]; then
      HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]}}"
      local HYSTERIA2_CONFIG=" { \"type\": \"hysteria2\", \"tag\": \"${NODE_NAME[12]} ${NODE_TAG[1]}\", \"up_mbps\": ${HY2_UP}, \"down_mbps\": ${HY2_DOWN}, \"password\": \"${UUID[12]}\", \"tls\": { \"enabled\": true, \"server_name\": \"${TLS_SERVER}\", \"certificate_public_key_sha256\": [\"$SELF_SIGNED_FINGERPRINT_BASE64\"], \"alpn\": [ \"h3\" ] }, \"realm\": { \"server_url\": \"https://realm.hy2.io\", \"token\": \"public\", \"realm_id\": \"${HY2_REALM_ID}\", \"stun_servers\": [ \"turn.cloudflare.com:3478\", \"stun.nextcloud.com:3478\", \"stun.sip.us:3478\", \"global.stun.twilio.com:3478\" ] } },"
    else
      local HYSTERIA2_CONFIG=" { \"type\": \"hysteria2\", \"tag\": \"${NODE_NAME[12]} ${NODE_TAG[1]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_HYSTERIA2}, \"up_mbps\": ${HY2_UP}, \"down_mbps\": ${HY2_DOWN}, \"password\": \"${UUID[12]}\", \"tls\": { \"enabled\": true, \"server_name\": \"${TLS_SERVER}\", \"certificate_public_key_sha256\": [\"$SELF_SIGNED_FINGERPRINT_BASE64\"], \"alpn\": [ \"h3\" ] } },"
      if [[ -n "${PORT_HOPPING_START}" && -n "${PORT_HOPPING_END}" ]]; then
        HYSTERIA2_CONFIG="${HYSTERIA2_CONFIG/\"server_port\": ${PORT_HYSTERIA2},/\"server_port\": ${PORT_HYSTERIA2}, \"server_ports\": [ \"${PORT_HOPPING_START}:${PORT_HOPPING_END}\" ], \"hop_interval\": \"30s\", \"hop_interval_max\": \"60s\",}"
      fi
    fi
    local OUTBOUND_REPLACE+="${HYSTERIA2_CONFIG}"
    local NODE_REPLACE+="\"${NODE_NAME[12]} ${NODE_TAG[1]}\","
  fi

  [ -n "$PORT_TUIC" ] &&
  local TUIC_INBOUND=" { \"type\": \"tuic\", \"tag\": \"${NODE_NAME[13]} ${NODE_TAG[2]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_TUIC}, \"uuid\": \"${UUID[13]}\", \"password\": \"${TUIC_PASSWORD}\", \"congestion_control\": \"$TUIC_CONGESTION_CONTROL\", \"udp_relay_mode\": \"native\", \"zero_rtt_handshake\": false, \"heartbeat\": \"10s\", \"tls\": { \"enabled\": true, \"server_name\": \"${TLS_SERVER}\", \"certificate_public_key_sha256\": [\"$SELF_SIGNED_FINGERPRINT_BASE64\"], \"alpn\": [ \"h3\" ] } }," &&
  local OUTBOUND_REPLACE+="${TUIC_INBOUND}" &&
  local NODE_REPLACE+="\"${NODE_NAME[13]} ${NODE_TAG[2]}\","

  [ -n "$PORT_SHADOWTLS" ] &&
  local SHADOWTLS_INBOUND=" { \"type\": \"shadowsocks\", \"tag\": \"${NODE_NAME[14]} ${NODE_TAG[3]}\", \"method\": \"$SHADOWTLS_METHOD\", \"password\": \"$SHADOWTLS_PASSWORD\", \"detour\": \"shadowtls-out\", \"udp_over_tcp\": false, \"multiplex\": { \"enabled\": true, \"protocol\": \"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } }, { \"type\": \"shadowtls\", \"tag\": \"shadowtls-out\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_SHADOWTLS}, \"version\": 3, \"password\": \"${UUID[14]}\", \"tls\": { \"enabled\": true, \"server_name\": \"${TLS_SERVER}\", \"utls\": { \"enabled\": true, \"fingerprint\": \"firefox\" } } }," &&
  local OUTBOUND_REPLACE+="${SHADOWTLS_INBOUND}" &&
  local NODE_REPLACE+="\"${NODE_NAME[14]} ${NODE_TAG[3]}\","

  [ -n "$PORT_SHADOWSOCKS" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"shadowsocks\", \"tag\": \"${NODE_NAME[15]} ${NODE_TAG[4]}\", \"server\": \"${SERVER_IP}\", \"server_port\": $PORT_SHADOWSOCKS, \"method\": \"${SHADOWSOCKS_METHOD}\", \"password\": \"${SHADOWSOCKS_PASSWORD}\", \"multiplex\": { \"enabled\": true, \"protocol\": \"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[15]} ${NODE_TAG[4]}\","

  [ -n "$PORT_TROJAN" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"trojan\", \"tag\": \"${NODE_NAME[16]} ${NODE_TAG[5]}\", \"server\": \"${SERVER_IP}\", \"server_port\": $PORT_TROJAN, \"password\": \"$TROJAN_PASSWORD\", \"tls\": { \"enabled\": true, \"certificate_public_key_sha256\": [\"$SELF_SIGNED_FINGERPRINT_BASE64\"], \"server_name\":\"${TLS_SERVER}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"firefox\" } }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[16]} ${NODE_TAG[5]}\","

  if [ -n "$PORT_VMESS_WS" ]; then
    local VMESS_CDN_PORT=${CDN_PORT[17]:-80}
    local VMESS_CDN_HOST=$(format_uri_host "${CDN[17]}")
     if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local OUTBOUND_REPLACE+=" { \"type\": \"vmess\", \"tag\": \"${NODE_NAME[17]} ${NODE_TAG[6]}\", \"server\":\"${VMESS_CDN_HOST}\", \"server_port\":${VMESS_CDN_PORT}, \"uuid\": \"${UUID[17]}\", \"security\": \"auto\", \"transport\": { \"type\":\"ws\", \"path\":\"/$VMESS_WS_PATH\", \"headers\": { \"Host\": \"$ARGO_DOMAIN\" } }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } },"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && [ -z "$PROMPT" ] && local PROMPT="
  # $(text 94)"
    else
      local WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} &&
      local TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN &&
      local TYPE_PORT_WS=$PORT_VMESS_WS &&
      local PROMPT+="
      # $(text 52)" &&
      local OUTBOUND_REPLACE+=" { \"type\": \"vmess\", \"tag\": \"${NODE_NAME[17]} ${NODE_TAG[6]}\", \"server\":\"${VMESS_CDN_HOST}\", \"server_port\":${VMESS_CDN_PORT}, \"uuid\":\"${UUID[17]}\", \"security\": \"auto\", \"transport\": { \"type\":\"ws\", \"path\":\"/$VMESS_WS_PATH\", \"headers\": { \"Host\": \"$VMESS_HOST_DOMAIN\" } }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } },"
    fi
    local NODE_REPLACE+="\"${NODE_NAME[17]} ${NODE_TAG[6]}\","
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_HOST=$(format_uri_host "${CDN[18]}")
    if [[ "${STATUS[1]}" =~ $(text 27)|$(text 28) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local OUTBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[18]} ${NODE_TAG[7]}\", \"server\":\"${VLESS_CDN_HOST}\", \"server_port\":${VLESS_CDN_PORT}, \"uuid\": \"${UUID[18]}\", \"tls\": { \"enabled\":true, \"server_name\":\"$ARGO_DOMAIN\", \"insecure\": false, \"utls\": { \"enabled\":true, \"fingerprint\":\"firefox\" } }, \"transport\": { \"type\":\"ws\", \"path\":\"/$VLESS_WS_PATH\", \"headers\": { \"Host\": \"$ARGO_DOMAIN\" }, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\" }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } },"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && [ -z "$PROMPT" ] && local PROMPT="
  # $(text 94)"
    else
      local WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} &&
      local TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN &&
      local TYPE_PORT_WS=$PORT_VLESS_WS &&
      local PROMPT+="
      # $(text 52)" &&
      local OUTBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[18]} ${NODE_TAG[7]}\", \"server\":\"${VLESS_CDN_HOST}\", \"server_port\":${VLESS_CDN_PORT}, \"uuid\": \"${UUID[18]}\",\"tls\": { \"enabled\":true, \"server_name\":\"$VLESS_HOST_DOMAIN\", \"insecure\": false, \"utls\": { \"enabled\":true, \"fingerprint\":\"firefox\" } }, \"transport\": { \"type\":\"ws\", \"path\":\"/$VLESS_WS_PATH\", \"headers\": { \"Host\": \"$VLESS_HOST_DOMAIN\" }, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\" }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } },"
    fi
    local NODE_REPLACE+="\"${NODE_NAME[18]} ${NODE_TAG[7]}\","
  fi

  [ -n "$PORT_H2_REALITY" ] &&
  local REALITY_H2_INBOUND=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[19]} ${NODE_TAG[8]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_H2_REALITY}, \"uuid\":\"${UUID[19]}\", \"tls\": { \"enabled\":true, \"server_name\":\"${TLS_SERVER}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"firefox\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC[19]}\", \"short_id\":\"\" } }, \"transport\": { \"type\": \"http\" } }," &&
  local REALITY_H2_NODE="\"${NODE_NAME[19]} ${NODE_TAG[8]}\"" &&
  local NODE_REPLACE+="${REALITY_H2_NODE}," &&
  local OUTBOUND_REPLACE+=" ${REALITY_H2_INBOUND}"

  [ -n "$PORT_GRPC_REALITY" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[20]} ${NODE_TAG[9]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_GRPC_REALITY}, \"uuid\":\"${UUID[20]}\", \"tls\": { \"enabled\":true, \"server_name\":\"${TLS_SERVER}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"firefox\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC[20]}\", \"short_id\":\"\" } }, \"transport\": { \"type\": \"grpc\", \"service_name\": \"grpc\" } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[20]} ${NODE_TAG[9]}\","

  [ -n "$PORT_ANYTLS" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"anytls\", \"tag\": \"${NODE_NAME[21]} ${NODE_TAG[10]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_ANYTLS}, \"password\": \"${UUID[21]}\", \"idle_session_check_interval\": \"30s\", \"idle_session_timeout\": \"30s\", \"min_idle_session\": 5, \"tls\": { \"enabled\": true, \"certificate_public_key_sha256\": [\"$SELF_SIGNED_FINGERPRINT_BASE64\"], \"server_name\": \"${TLS_SERVER}\", \"utls\": { \"enabled\": true, \"fingerprint\": \"firefox\" } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[21]} ${NODE_TAG[10]}\","

  [ -n "$PORT_NAIVE" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"naive\", \"tag\": \"${NODE_NAME[22]} ${NODE_TAG[11]} http2\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_NAIVE}, \"username\": \"${UUID[22]}\", \"password\": \"${UUID[22]}\", \"udp_over_tcp\": true, \"quic\": false, \"tls\": { \"enabled\": true, \"certificate\": [$(tr -d '\n' <<< "$CERT200_JSON")], \"server_name\": \"${TLS_SERVER}\" } }, { \"type\": \"naive\", \"tag\": \"${NODE_NAME[22]} ${NODE_TAG[11]} quic\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_NAIVE}, \"username\": \"${UUID[22]}\", \"password\": \"${UUID[22]}\", \"udp_over_tcp\": false, \"quic\": true, \"quic_congestion_control\": \"bbr\", \"tls\": { \"enabled\": true, \"certificate\": [$(tr -d '\n' <<< "$CERT200_JSON")], \"server_name\": \"${TLS_SERVER}\" } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[22]} ${NODE_TAG[11]} http2\",\"${NODE_NAME[22]} ${NODE_TAG[11]} quic\","

  {
    # 生成 sing-box SFM SFA SFI 订阅文件
    [ ! -s "$TEMP_DIR/sing-box-template" ] && wget --no-check-certificate --continue -qO "$TEMP_DIR/sing-box-template" "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/sing-box" 2>/dev/null
    cat $TEMP_DIR/sing-box-template | sed "s#\"<OUTBOUND_REPLACE>\",#$OUTBOUND_REPLACE#; s#\"<NODE_REPLACE>\"#${NODE_REPLACE%,}#g" | ${WORK_DIR}/jq > ${WORK_DIR}/subscribe/sing-box
    rm -f $TEMP_DIR/sing-box-template
  } &>/dev/null

  # 生成二维码 url 文件
  [ "$IS_SUB" = 'is_sub' ] && cat > ${WORK_DIR}/subscribe/qr << EOF
$(text 81):
$(text 82) 1:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto

$(text 82) 2:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2

$(text 80) QRcode:
$(text 82) 1:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto

$(text 82) 2:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2

$(text 82) 1:
$(${WORK_DIR}/qrencode "$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto")

$(text 82) 2:
$(${WORK_DIR}/qrencode "$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2")
EOF

  # 生成配置文件
  EXPORT_LIST_FILE="*******************************************
┌────────────────┐
│                │
│     $(warning "V2rayN")     │
│                │
└────────────────┘
$(info "${V2RAYN_SUBSCRIBE}")

*******************************************
┌────────────────┐
│                │
│  $(warning "ShadowRocket")  │
│                │
└────────────────┘
----------------------------
$(hint "${SHADOWROCKET_SUBSCRIBE}")

*******************************************
┌────────────────┐
│                │
│   $(warning "Clash Verge")  │
│                │
└────────────────┘
----------------------------

$(info "$(sed '1d' <<< "${CLASH_SUBSCRIBE}")")

*******************************************
┌────────────────┐
│                │
│     $(warning "Throne")     │
│                │
└────────────────┘
$(hint "${THRONE_SUBSCRIBE}")

*******************************************
┌────────────────┐
│                │
│    $(warning "Sing-box")    │
│                │
└────────────────┘
----------------------------

$(info "$(echo "{ \"outbounds\":[ ${OUTBOUND_REPLACE%,} ] }" | ${WORK_DIR}/jq)

${PROMPT}

  $(text 72)")
"

  [ "$IS_SUB" = 'is_sub' ] && EXPORT_LIST_FILE+="

*******************************************

$(hint "Index:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/

QR code:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/qr

V2rayN $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/v2rayn")

$(hint "Throne $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/neko")

$(hint "Clash $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/clash
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/clash2

SFI / SFA / SFM $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/sing-box

ShadowRocket $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/shadowrocket")

*******************************************

$(info " $(text 81):
$(text 82) 1:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto

$(text 82) 2:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2

 $(text 80) QRcode:
$(text 82) 1:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto

$(text 82) 2:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2")

$(hint "$(text 82) 1:")
$(${WORK_DIR}/qrencode $SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto)

$(hint "$(text 82) 2:")
$(${WORK_DIR}/qrencode $SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2)
"

  # 生成并显示节点信息
  echo "$EXPORT_LIST_FILE" > ${WORK_DIR}/list
  cat ${WORK_DIR}/list

  # 显示脚本使用情况数据
  statistics_of_run_times get
}

# 创建快捷方式
create_shortcut() {
  cat > ${WORK_DIR}/sb.sh << EOF
#!/usr/bin/env bash

bash <(wget --no-check-certificate -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh) \$@
EOF
  chmod +x ${WORK_DIR}/sb.sh
  ln -sf ${WORK_DIR}/sb.sh /usr/bin/sb
  [ -s /usr/bin/sb ] && info "\n $(text 71) "
}

# 更换各协议的监听端口
change_start_port() {
  OLD_PORTS=$(awk -F ':|,' '/listen_port/{print $2}' ${WORK_DIR}/conf/*)
  OLD_START_PORT=$(awk 'NR == 1 { min = $0 } { if ($0 < min) min = $0; count++ } END {print min}' <<< "$OLD_PORTS")
  OLD_CONSECUTIVE_PORTS=$(awk 'END { print NR }' <<< "$OLD_PORTS")
  input_start_port $OLD_CONSECUTIVE_PORTS
  cmd_systemctl disable sing-box
  for ((a=0; a<$OLD_CONSECUTIVE_PORTS; a++)) do
    [ -s ${WORK_DIR}/conf/${CONF_FILES[a]} ] && sed -i "s/\(.*listen_port.*:\)$((OLD_START_PORT+a))/\1$((START_PORT+a))/" ${WORK_DIR}/conf/*
  done
  fetch_nodes_value
  [ -n "$PORT_NGINX" ] && UUID_CONFIRM=$(sed -n 's#.*location[ ]\+\/\(.*\)-v[ml]ess.*#\1#gp' /etc/sing-box/nginx.conf | sed -n '1p') && export_nginx_conf_file
  cmd_systemctl enable sing-box
  [ -n "$ARGO_DOMAIN" ] && export_argo_json_file
  sync_firewall_rules
  sleep 2
  export_list
  cmd_systemctl status sing-box &>/dev/null && info " Sing-box $(text 121) $(text 37) " || error " Sing-box $(text 121) $(text 38) "
}

# 增加或删除协议
change_protocols() {
  check_install
  [ "${STATUS[0]}" = "$(text 26)" ] && error "\n Sing-box $(text 26) "

  # 检查服务器 IP
  check_system_ip

  # 查找已安装的协议，并遍历其在所有协议列表中的名称，获取协议名后存放在 EXISTED_PROTOCOLS; 没有的协议存放在 NOT_EXISTED_PROTOCOLS
  INSTALLED_PROTOCOLS_LIST=$(awk -F '"' '/"tag":/{print $4}' ${WORK_DIR}/conf/*_inbounds.json | grep -v 'shadowtls-in' | awk '{print $NF}')
  for f in "${!NODE_TAG[@]}"; do
    [[ $INSTALLED_PROTOCOLS_LIST =~ ${NODE_TAG[f]} ]] && EXISTED_PROTOCOLS+=("${PROTOCOL_LIST[f]}") || NOT_EXISTED_PROTOCOLS+=("${PROTOCOL_LIST[f]}")
  done

  # 列出已安装协议
  hint "\n $(text 136) (${#EXISTED_PROTOCOLS[@]})"
  for h in "${!EXISTED_PROTOCOLS[@]}"; do
    hint " $(asc $(( h+97 ))). ${EXISTED_PROTOCOLS[h]} "
  done

  # 从已安装的协议中选择需要删除的协议名，并存放在 REMOVE_PROTOCOLS，把保存的协议的协议存放在 KEEP_PROTOCOLS
  reading "\n $(text 64) " REMOVE_SELECT
  # 统一为小写，去掉重复选项，处理不在可选列表里的选项，把特殊符号处理
  REMOVE_SELECT=$(sed "s/[^a-$(asc $(( ${#EXISTED_PROTOCOLS[@]} + 96 )))]//g" <<< "${REMOVE_SELECT,,}" | awk 'BEGIN{RS=""; FS=""}{delete seen; output=""; for(i=1; i<=NF; i++){ if(!seen[$i]++){ output=output $i } } print output}')

  for ((j=0; j<${#REMOVE_SELECT}; j++)); do
    REMOVE_PROTOCOLS+=("${EXISTED_PROTOCOLS[$(( $(asc "$(awk "NR==$[j+1] {print}" <<< "$(grep -o . <<< "$REMOVE_SELECT")")") - 97 ))]}")
  done

  for k in "${EXISTED_PROTOCOLS[@]}"; do
    array_contains "$k" "${REMOVE_PROTOCOLS[@]}" || KEEP_PROTOCOLS+=("$k")
  done

  # 如有未安装的协议，列表显示并选择安装，把增加的协议存在放在 ADD_PROTOCOLS
  if [ "${#NOT_EXISTED_PROTOCOLS[@]}" -gt 0 ]; then
    hint "\n $(text 137) (${#NOT_EXISTED_PROTOCOLS[@]}) "
    for i in "${!NOT_EXISTED_PROTOCOLS[@]}"; do
      hint " $(asc $(( i+97 ))). ${NOT_EXISTED_PROTOCOLS[i]} "
    done
    reading "\n $(text 66) " ADD_SELECT
    # 统一为小写，去掉重复选项，处理不在可选列表里的选项，把特殊符号处理
    ADD_SELECT=$(sed "s/[^a-$(asc $(( ${#NOT_EXISTED_PROTOCOLS[@]} + 96 )))]//g" <<< "${ADD_SELECT,,}" | awk 'BEGIN{RS=""; FS=""}{delete seen; output=""; for(i=1; i<=NF; i++){ if(!seen[$i]++){ output=output $i } } print output}')

    for ((l=0; l<${#ADD_SELECT}; l++)); do
      ADD_PROTOCOLS+=("${NOT_EXISTED_PROTOCOLS[$(( $(asc "$(awk "NR==$[l+1] {print}" <<< "$(grep -o . <<< "$ADD_SELECT")")") - 97 ))]}")
    done
  fi

  # 重新安装 = 保留 + 新增，如数量为 0 ，则触发卸载
  REINSTALL_PROTOCOLS=("${KEEP_PROTOCOLS[@]}" "${ADD_PROTOCOLS[@]}")
  [ "${#REINSTALL_PROTOCOLS[@]}" = 0 ] && error "\n $(text 73) "

  # 显示重新安装的协议列表，并确认是否正确
  hint "\n $(text 138) (${#REINSTALL_PROTOCOLS[@]}) "
  [ "${#KEEP_PROTOCOLS[@]}" -gt 0 ] && hint "\n $(text 74) (${#KEEP_PROTOCOLS[@]}) "
  for r in "${!KEEP_PROTOCOLS[@]}"; do
    hint " $[r+1]. ${KEEP_PROTOCOLS[r]} "
  done

  [ "${#ADD_PROTOCOLS[@]}" -gt 0 ] && hint "\n $(text 75) (${#ADD_PROTOCOLS[@]}) "
  for r in "${!ADD_PROTOCOLS[@]}"; do
    hint " $[r+1]. ${ADD_PROTOCOLS[r]} "
  done

  reading "\n $(text 68) " CONFIRM
  [ "${CONFIRM,,}" = 'n' ] && exit 0

  # 把确认安装的协议遍历所有协议列表的数组，找出其下标并变为英文小写的形式
  for m in "${!REINSTALL_PROTOCOLS[@]}"; do
    for n in "${!PROTOCOL_LIST[@]}"; do
      if [ "${REINSTALL_PROTOCOLS[m]}" = "${PROTOCOL_LIST[n]}" ]; then
        INSTALL_PROTOCOLS+=($(asc $[n+98]))
      fi
    done
  done

  # 获取各节点信息
  fetch_nodes_value

  # 用于新节点的配置信息
  UUID_CONFIRM=$(awk '{print $1}' <<< "${UUID[*]} $TROJAN_PASSWORD")
  for v in "${NODE_NAME[@]}"; do
    [ -n "$v" ] && NODE_NAME_CONFIRM="$v" && break
  done
  [ "${#WS_SERVER_IP[@]}" -gt 0 ] && WS_SERVER_IP_SHOW=$(awk '{print $1}' <<< "${WS_SERVER_IP[@]}") && CDN=$(awk '{print $1}' <<< "${CDN[@]}")

  # 寻找待删除协议的 inbound 文件名
  for o in "${REMOVE_PROTOCOLS[@]}"; do
    for s in "${!PROTOCOL_LIST[@]}"; do
      [ "$o" = "${PROTOCOL_LIST[s]}" ] && REMOVE_FILE+=("${NODE_TAG[s]}_inbounds.json")
    done
  done

  # 如有需要，删除 hysteria2 跳跃端口，待后面添加回来
  [ "$IS_HOPPING" = 'is_hopping' ] && del_port_hopping_nat

  # 删除不需要的协议配置文件
  [ "${#REMOVE_FILE[@]}" -gt 0 ] && for t in "${REMOVE_FILE[@]}"; do
    rm -f ${WORK_DIR}/conf/*${t}
  done

  # 寻找已存在协议中原有的端口号
  for p in "${KEEP_PROTOCOLS[@]}"; do
    for u in "${!PROTOCOL_LIST[@]}"; do
      [ "$p" = "${PROTOCOL_LIST[u]}" ] && KEEP_PORTS+=("$(awk -F '[:,]' '/listen_port/{print $2}' ${WORK_DIR}/conf/*${NODE_TAG[u]}_inbounds.json)")
    done
  done

  # 根据全部协议，找到空余的端口号
  for q in "${!REINSTALL_PROTOCOLS[@]}"; do
    array_contains "$((START_PORT + q))" "${KEEP_PORTS[@]}" || ADD_PORTS+=("$((START_PORT + q))")
  done

  # 所有协议的端口号
  REINSTALL_PORTS=("${KEEP_PORTS[@]}" "${ADD_PORTS[@]}")

  CHECK_PROTOCOLS=b
  # 获取 Reality 端口
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_XTLS_REALITY=${REINSTALL_PORTS[POSITION]}
    NEED_PRIVATE_KEY='need_private_key'
  else
    unset PORT_XTLS_REALITY
  fi

  # 获取 Hysteria2 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_HYSTERIA2=${REINSTALL_PORTS[POSITION]}
    if [[ " ${ADD_PROTOCOLS[*]} " =~ " ${PROTOCOL_LIST[1]} " ]] && [ -z "$IS_HY2_REALM" ]; then
      input_hy2_realm
    fi
    [ -z "${PORT_HOPPING_START}${PORT_HOPPING_END}" ] && input_hopping_port
  else
    unset PORT_HYSTERIA2 IS_HY2_REALM IS_HY2_WARP HY2_REALM_ID
  fi

  # 获取 Tuic V5 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_TUIC=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_TUIC
  fi

  # 获取 ShadowTLS 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_SHADOWTLS=${REINSTALL_PORTS[POSITION]}
  fi

  # 获取 Shadowsocks 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_SHADOWSOCKS=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_SHADOWSOCKS
  fi

  # 获取 Trojan 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_TROJAN=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_TROJAN
  fi

  # 获取 ws 的 argo 或者 origin 状态
  if [ -s ${ARGO_DAEMON_FILE} ]; then
    local ARGO_ORIGIN_RULES_STATUS=is_argo
    [ "$SYSTEM" = 'Alpine' ] && ARGO_RUNS="$(sed -n 's/command="\(.*\)"/\1/gp' $ARGO_DAEMON_FILE) $(sed -n 's/command_args="\(.*\)"/\1/gp' $ARGO_DAEMON_FILE)" || ARGO_RUNS=$(sed -n "s/^ExecStart=\(.*\)/\1/gp" ${ARGO_DAEMON_FILE})
  elif ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1; then
    local ARGO_ORIGIN_RULES_STATUS=is_origin
  else
    local ARGO_ORIGIN_RULES_STATUS=no_argo_no_origin
  fi

  # 获取 vmess + ws 配置信息
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    local DOMAIN_ERROR_TIME=5
    if [[ "$ARGO_READY" != 'argo_ready' || "$ORIGIN_READY" != 'origin_ready' ]]; then
      if [ "$ARGO_ORIGIN_RULES_STATUS" = 'is_origin' ]; then
        until [ -n "$VMESS_HOST_DOMAIN" ]; do
          (( DOMAIN_ERROR_TIME-- )) || true
          [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VMESS && reading "\n $(text 50) " VMESS_HOST_DOMAIN || error "\n $(text 3) \n"
        done
      elif [ "$ARGO_ORIGIN_RULES_STATUS" = 'no_argo_no_origin' ]; then
        [ -z "$ARGO_OR_ORIGIN_RULES" ] && hint "\n $(text 57) " && reading "\n $(text 24) " ARGO_OR_ORIGIN_RULES
        [ "$ARGO_OR_ORIGIN_RULES" != '2' ] && ARGO_OR_ORIGIN_RULES=1 && IS_ARGO=is_argo || IS_ARGO=no_argo
        if [ "$IS_ARGO" = 'is_argo' ]; then
          # 如果原来没有 nginx 配置，需要获取 nginx 端口信息
          [ -z "$PORT_NGINX"  ] && input_nginx_port
          until [ -n "$ARGO_RUNS" ]; do
            input_argo_auth is_add_protocols
            [ -n "$ARGO_RUNS" ] && local ARGO_READY=argo_ready && break
          done
        else
          until [ -n "$VMESS_HOST_DOMAIN" ]; do
            (( DOMAIN_ERROR_TIME-- )) || true
            [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VMESS && reading "\n $(text 50) " VMESS_HOST_DOMAIN || error "\n $(text 3) \n"
          done
          local ORIGIN_READY=origin_ready
        fi
      fi
    fi
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_VMESS_WS=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_VMESS_WS
  fi

  # 获取 vless + ws + tls 配置信息
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    local DOMAIN_ERROR_TIME=5
    if [[ "$ARGO_READY" != 'argo_ready' || "$ORIGIN_READY" != 'origin_ready' ]]; then
      if [ "$ARGO_ORIGIN_RULES_STATUS" = 'is_origin' ]; then
        until [ -n "$VLESS_HOST_DOMAIN" ]; do
          (( DOMAIN_ERROR_TIME-- )) || true
          [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VLESS && reading "\n $(text 50) " VLESS_HOST_DOMAIN || error "\n $(text   3) \n"
        done
      elif [ "$ARGO_ORIGIN_RULES_STATUS" = 'no_argo_no_origin' ]; then
        [ -z "$ARGO_OR_ORIGIN_RULES" ] && hint "\n $(text 57) " && reading "\n $(text 24) " ARGO_OR_ORIGIN_RULES
        [ "$ARGO_OR_ORIGIN_RULES" != '2' ] && ARGO_OR_ORIGIN_RULES=1 && IS_ARGO=is_argo || IS_ARGO=no_argo
        if [ "$IS_ARGO" = 'is_argo' ]; then
           # 如果原来没有 nginx 配置，需要获取 nginx 端口信息
          [ -z "$PORT_NGINX"  ] && input_nginx_port
          until [ -n "$ARGO_RUNS" ]; do
            [ "$ARGO_READY" != 'argo_ready' ] && input_argo_auth is_add_protocols
            [ -n "$ARGO_RUNS" ] && local ARGO_READY=argo_ready && break
          done
        else
          until [ -n "$VLESS_HOST_DOMAIN" ]; do
            (( DOMAIN_ERROR_TIME-- )) || true
            [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VLESS && reading "\n $(text 50) " VLESS_HOST_DOMAIN || error "\n $(text   3) \n"
          done
          local ORIGIN_READY=origin_ready
        fi
      fi
    fi
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_VLESS_WS=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_VLESS_WS
  fi

  # 如之前没有 ws，现新增的 ws，则确认服务器 IP 和输入 cdn
  if [[ "${#CDN[@]}" = '0' && ( "$ARGO_READY" = 'argo_ready' || "$ORIGIN_READY" = 'origin_ready' ) ]]; then
    if grep -qi 'cloudflare' <<< "$ASNORG4$ASNORG6"; then
      if grep -qi 'cloudflare' <<< "$ASNORG6" && [ -n "$WAN4" ] && ! grep -qi 'cloudflare' <<< "$ASNORG4"; then
        SERVER_IP_DEFAULT=$WAN4
      elif grep -qi 'cloudflare' <<< "$ASNORG4" && [ -n "$WAN6" ] && ! grep -qi 'cloudflare' <<< "$ASNORG6"; then
        SERVER_IP_DEFAULT=$WAN6
      else
        local a=6
        until [ -n "$SERVER_IP" ]; do
          ((a--)) || true
          [ "$a" = 0 ] && error "\n $(text 3) \n"
          reading "\n $(text 46) " SERVER_IP
        done
      fi
    elif [ -n "$WAN4" ]; then
      SERVER_IP_DEFAULT=$WAN4
    elif [ -n "$WAN6" ]; then
      SERVER_IP_DEFAULT=$WAN6
    fi

    # 输入服务器 IP,默认为检测到的服务器 IP，如果全部为空，则提示并退出脚本
    [ -z "$SERVER_IP" ] && reading "\n $(text 10) " SERVER_IP
    SERVER_IP=${SERVER_IP:-"$SERVER_IP_DEFAULT"} && WS_SERVER_IP_SHOW=$SERVER_IP
    [ -z "$SERVER_IP" ] && error " $(text 47) "

    input_cdn
  fi

  # 获取 H2 + Reality 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_H2_REALITY=${REINSTALL_PORTS[POSITION]}
    NEED_PRIVATE_KEY='need_private_key'
  else
    unset PORT_H2_REALITY
  fi

  # 获取 gRPC + Reality 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_GRPC_REALITY=${REINSTALL_PORTS[POSITION]}
    NEED_PRIVATE_KEY='need_private_key'
  else
    unset PORT_GRPC_REALITY
  fi

  # 如之前没有 Reality，现新增的 reality，则确认 privateKey
  [[ "${#REALITY_PRIVATE[@]}" = 0 && "${NEED_PRIVATE_KEY}" = 'need_private_key' ]] && input_reality_key

  # 让 ShadowTLS 和 shadowsocks 密码相同
  if [[ -n "$SHADOWTLS_PASSWORD" && -z "$SHADOWSOCKS_PASSWORD" ]]; then
    SIP022_PASSWORD=$SHADOWTLS_PASSWORD
  elif [[ -z "$SHADOWTLS_PASSWORD" && -n "$SHADOWSOCKS_PASSWORD" ]]; then
    SIP022_PASSWORD=$SHADOWSOCKS_PASSWORD
  fi

  # 获取 anytls 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_ANYTLS=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_ANYTLS
  fi

  # 获取 naive 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_NAIVE=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_NAIVE
  fi
  validate_nginx_port

  # 停止 sing-box 服务
  cmd_systemctl disable sing-box

  # 关闭防火墙相关端口

  # 生成 Nginx 配置文件
  [ -n "$PORT_NGINX" ] && export_nginx_conf_file

  # 重新生成 Sing-box 守护进程文件
  sing-box_systemd

  # 生成各协议的 json 文件
  sing-box_json change

  # 如有需要，安装和删除 Argo 服务
  if ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1; then
    if [[ "$ARGO_OR_ORIGIN_RULES" != '2' && "$ARGO_ORIGIN_RULES_STATUS" != 'is_origin' && ! -s ${ARGO_DAEMON_FILE} ]]; then
      argo_systemd
      cmd_systemctl enable argo >/dev/null 2>&1
    fi
  elif [ -s ${ARGO_DAEMON_FILE} ]; then
    cmd_systemctl disable argo >/dev/null 2>&1
    rm -f ${ARGO_DAEMON_FILE}
    [ -s ${WORK_DIR}/tunnel.json ] && rm -f ${WORK_DIR}/tunnel.*
  fi

  # 如有需要，删除 nginx 配置文件
  ! ls ${ARGO_DAEMON_FILE} >/dev/null 2>&1 && [[ -s ${WORK_DIR}/nginx.conf && "$IS_SUB" = 'no_sub' ]] && IS_ARGO=no_argo && rm -f ${WORK_DIR}/nginx.conf

  # 运行 sing-box
  cmd_systemctl enable sing-box

  # 打开防火墙相关端口
  sync_firewall_rules

  # 等待服务启动
  sleep 3

  # 再次检测状态，运行 sing-box
  check_install
  case "${STATUS[0]}" in
    "$(text 26)" )
      error "\n Sing-box $(text 28) $(text 38) \n"
      ;;
    "$(text 27)" )
      cmd_systemctl enable sing-box
      cmd_systemctl status sing-box &>/dev/null && info "\n Sing-box $(text 28) $(text 37) \n" || error "\n Sing-box $(text 28) $(text 38) \n"
      ;;
    "$(text 28)" )
      info "\n Sing-box $(text 28) $(text 37) \n"
  esac

  # 导出节点和订阅服务信息
  export_list
}

# 卸载 sing-box 全家桶
uninstall() {
  if [ -d ${WORK_DIR} ]; then
    [ -s ${ARGO_DAEMON_FILE} ] && cmd_systemctl disable argo &>/dev/null
    [ -s ${SINGBOX_DAEMON_FILE} ] && cmd_systemctl disable sing-box &>/dev/null
    sleep 1
    [[ -s ${WORK_DIR}/nginx.conf && "$(ps -ef | grep -c '[n]ginx')" = 0 ]] && reading "\n $(text 83) " REMOVE_NGINX
    [ "${REMOVE_NGINX,,}" = 'y' ] && ${PACKAGE_UNINSTALL[int]} nginx >/dev/null 2>&1
    purge_service_firewall_rules
    del_port_hopping_nat >/dev/null 2>&1 || true
    rm -rf ${WORK_DIR} ${TEMP_DIR} ${ARGO_DAEMON_FILE} ${SINGBOX_DAEMON_FILE} /usr/bin/sb
    info "\n $(text 16) \n"
  else
    error "\n $(text 15) \n"
  fi
}


# Sing-box 的最新版本
version() {
  # 获取需要下载的 sing-box 版本
  local ONLINE=$(get_sing_box_version)

  grep -q '.' <<< "$ONLINE" || error " $(text 100) \n"
  local LOCAL=$(${WORK_DIR}/sing-box version | awk '/version/{print $NF}')
  info "\n $(text 40) "
  [[ -n "$ONLINE" && "$ONLINE" != "$LOCAL" ]] && reading "\n $(text 9) " UPDATE || info " $(text 41) "

  if [ "${UPDATE,,}" = 'y' ]; then
    check_system_info
    wget --no-check-certificate --continue ${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz -qO- | tar xz -C $TEMP_DIR sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box

    if [ -s $TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box ]; then
      cmd_systemctl disable sing-box

      # 备份旧版本
      cp ${WORK_DIR}/sing-box ${WORK_DIR}/sing-box.bak
      hint "\n $(text 102) \n"

      # 安装新版本
      chmod +x $TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box && mv $TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box ${WORK_DIR}/sing-box
      cmd_systemctl enable sing-box
      sleep 2

      # 检查新版本是否成功运行
      if cmd_systemctl status sing-box &>/dev/null; then
        # 新版本运行成功，删除备份
        rm -f ${WORK_DIR}/sing-box.bak
        info "\n $(text 103) \n"
      else
        # 新版本运行失败，恢复旧版本
        warning "\n $(text 104) \n"
        mv ${WORK_DIR}/sing-box.bak ${WORK_DIR}/sing-box
        cmd_systemctl enable sing-box
        sleep 2

        if cmd_systemctl status sing-box &>/dev/null; then
          info "\n $(text 105) \n"
        else
          error "\n $(text 106) \n"
        fi
      fi
    else
      error "\n $(text 42) "
    fi
  fi
}

# 判断当前 Sing-box 的运行状态，并对应的给菜单和动作赋值
menu_setting() {
  OPTION=()
  ACTION=()

  if [[ "${STATUS[0]}" =~ $(text 27)|$(text 28) ]]; then
    OPTION[1]="1 .  $(text 29)"
    [ "${STATUS[0]}" = "$(text 28)" ] && OPTION[2]="2 .  $(text 27) Sing-box (sb -s)" || OPTION[2]="2 .  $(text 28) Sing-box (sb -s)"
    [ "${STATUS[1]}" = "$(text 28)" ] && OPTION[3]="3 .  $(text 27) Argo (sb -a)" || OPTION[3]="3 .  $(text 28) Argo (sb -a)"
    OPTION[4]="4 .  $(text 92)"
    OPTION[5]="5 .  $(text 121)"
    OPTION[6]="6 .  $(text 31)"
    OPTION[7]="7 .  $(text 32)"
    OPTION[8]="8 .  $(text 62)"
    OPTION[9]="9 .  $(text 33)"
    OPTION[10]="10.  $(text 59)"
    OPTION[11]="11.  $(text 69)"
    OPTION[12]="12.  $(text 76)"

    menu_action_export_list() { export_list; exit 0; }

    if [ "${STATUS[0]}" = "$(text 28)" ]; then
      menu_action_toggle_sing_box() {
        cmd_systemctl disable sing-box
        cmd_systemctl status sing-box &>/dev/null && error " Sing-box $(text 27) $(text 38) " || info " Sing-box $(text 27) $(text 37)"
      }
    else
      menu_action_toggle_sing_box() {
        cmd_systemctl enable sing-box
        sleep 2
        cmd_systemctl status sing-box &>/dev/null && info " Sing-box $(text 28) $(text 37)" || error " Sing-box $(text 28) $(text 38) "
      }
    fi

    if [ "${STATUS[1]}" = "$(text 28)" ]; then
      menu_action_toggle_argo() {
        cmd_systemctl disable argo
        cmd_systemctl status argo &>/dev/null && error " Argo $(text 27) $(text 38) " || info " Argo $(text 27) $(text 37)"
      }
    else
      menu_action_toggle_argo() {
        cmd_systemctl enable argo
        sleep 2
        cmd_systemctl status argo &>/dev/null &&  info " Argo $(text 28) $(text 37)" || error " Argo $(text 28) $(text 38) "
        grep -qs '\--url' ${ARGO_DAEMON_FILE} && fetch_quicktunnel_domain && export_list
      }
    fi

    menu_action_change_argo() { change_argo; exit; }
    menu_action_change_config() { change_config; exit; }
    menu_action_version() { version; exit; }
    menu_action_bbr() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh); exit; }
    menu_action_change_protocols() { change_protocols; exit; }
    menu_action_uninstall() { uninstall; exit; }
    menu_action_argox() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh) -$L; exit; }
    menu_action_sba() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/fscarmen/sba/main/sba.sh) -$L; exit; }
    menu_action_hy2_tcp() { bash <(wget --no-check-certificate -qO- https://tcp.hy2.sh/); exit; }

    ACTION[1]=menu_action_export_list
    ACTION[2]=menu_action_toggle_sing_box
    ACTION[3]=menu_action_toggle_argo
    ACTION[4]=menu_action_change_argo
    ACTION[5]=menu_action_change_config
    ACTION[6]=menu_action_version
    ACTION[7]=menu_action_bbr
    ACTION[8]=menu_action_change_protocols
    ACTION[9]=menu_action_uninstall
    ACTION[10]=menu_action_argox
    ACTION[11]=menu_action_sba
    ACTION[12]=menu_action_hy2_tcp
  else
    OPTION[1]="1.  $(text 115)"
    OPTION[2]="2.  $(text 34) + Argo + $(text 80) $(text 89)"
    OPTION[3]="3.  $(text 34) + Argo $(text 89)"
    OPTION[4]="4.  $(text 34) + $(text 80) $(text 89)"
    OPTION[5]="5.  $(text 34)"
    OPTION[6]="6.  $(text 32)"
    OPTION[7]="7.  $(text 59)"
    OPTION[8]="8.  $(text 69)"
    OPTION[9]="9.  $(text 76)"

    menu_action_fast_install() {
      IS_FAST_INSTALL='is_fast_install'
      CHOOSE_PROTOCOLS=${CHOOSE_PROTOCOLS:-'a'}
      START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
      CDN=${CDN:-"${CDN_DOMAIN[0]}"}
      IS_SUB='is_sub'
      IS_ARGO='is_argo'
      HY2_PORT_HOPPING_RANGE=${HY2_PORT_HOPPING_RANGE:-'50000:51000'}
      install_sing-box
      export_list install
      create_shortcut
      exit
    }
    menu_action_install_with_argo_sub() { IS_SUB=is_sub; IS_ARGO=is_argo; install_sing-box; export_list install; create_shortcut; exit; }
    menu_action_install_with_argo() { IS_SUB=no_sub; IS_ARGO=is_argo; install_sing-box; export_list install; create_shortcut; exit; }
    menu_action_install_with_sub() { IS_SUB=is_sub; IS_ARGO=no_argo; install_sing-box; export_list install; create_shortcut; exit; }
    menu_action_install() { install_sing-box; export_list install; create_shortcut; exit; }
    menu_action_bbr() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh); exit; }
    menu_action_argox() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh) -$L; exit; }
    menu_action_sba() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/fscarmen/sba/main/sba.sh) -$L; exit; }
    menu_action_hy2_tcp() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://tcp.hy2.sh/); exit; }

    ACTION[1]=menu_action_fast_install
    ACTION[2]=menu_action_install_with_argo_sub
    ACTION[3]=menu_action_install_with_argo
    ACTION[4]=menu_action_install_with_sub
    ACTION[5]=menu_action_install
    ACTION[6]=menu_action_bbr
    ACTION[7]=menu_action_argox
    ACTION[8]=menu_action_sba
    ACTION[9]=menu_action_hy2_tcp
  fi

  [ "${#OPTION[@]}" -ge '10' ] && OPTION[0]="0 .  $(text 35)" || OPTION[0]="0.  $(text 35)"
  menu_action_exit() { exit; }
  ACTION[0]=menu_action_exit
}

menu() {
  clear
  echo -e "======================================================================================================================\n"
  info " $(text 17): $VERSION\n $(text 18): $(text 1)\n $(text 19):\n\t $(text 20): $SYS\n\t $(text 21): $(uname -r)\n\t $(text 22): $SING_BOX_ARCH\n\t $(text 23): $VIRT "
  info "\t IPv4: $WAN4 $WARPSTATUS4 $COUNTRY4  $ASNORG4 "
  info "\t IPv6: $WAN6 $WARPSTATUS6 $COUNTRY6  $ASNORG6 "
  # 对齐显示：中文双宽字符按字符数补空格，英文按最长状态词 "Not install"(11字符) 定宽
  _sv() {
    local s="$1"
    if [ "$L" = 'C' ]; then
      [ "${#s}" -le 2 ] && printf '%s  ' "$s" || printf '%s' "$s"
    else
      printf '%-11s' "$s"
    fi
  }
  local _SBV; printf -v _SBV '%-26s' "$SING_BOX_VERSION"
  local _AV;  printf -v _AV  '%-26s' "$ARGO_VERSION"
  local _NV;  printf -v _NV  '%-26s' "$NGINX_VERSION"
  info "\t Sing-box: $(_sv "${STATUS[0]}")  ${_SBV}${SING_BOX_MEMORY_USAGE}\n\t Argo:     $(_sv "${STATUS[1]}")  ${_AV}${ARGO_MEMORY_USAGE}\n\t Nginx:    $(_sv "${STATUS[2]}")  ${_NV}${NGINX_MEMORY_USAGE}"
  echo -e "\n======================================================================================================================\n"
  for ((b=1;b<=${#OPTION[*]};b++)); do [ "$b" = "${#OPTION[*]}" ] && hint " ${OPTION[0]} " || hint " ${OPTION[b]} "; done
  reading "\n $(text 24) " CHOOSE

  # 输入必须是数字且少于等于最大可选项
  if grep -qE "^[0-9]{1,2}$" <<< "$CHOOSE" && [ "$CHOOSE" -lt "${#OPTION[*]}" ]; then
    "${ACTION[$CHOOSE]}"
  else
    warning " $(text 36) [0-$((${#OPTION[*]}-1))] " && sleep 1 && menu
  fi
}

check_cdn
statistics_of_run_times update sing-box.sh 2>/dev/null

# 传参
[[ "${*^^}" =~ '-E'|'-K' ]] && L=E
[[ "${*^^}" =~ '-C'|'-B'|'-L' ]] && L=C
# 支持在 select_language 前识别 --LANGUAGE，避免 KV 无交互安装仍弹出语言选择。
