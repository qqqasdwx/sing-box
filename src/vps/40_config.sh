# 读取现有基础配置中需要跨升级保留的用户偏好。
managed_base_config_values() {
  local SOURCE_DIR=$1 VALUE

  BASE_LOG_LEVEL=$LOG_LEVEL_DEFAULT
  if [ -s "${SOURCE_DIR}/00_log.json" ]; then
    VALUE=$(jq_exec -r '.log.level // empty' "${SOURCE_DIR}/00_log.json" 2>/dev/null || true)
    case "$VALUE" in
      trace|debug|info|warn|error|fatal|panic ) BASE_LOG_LEVEL=$VALUE ;;
    esac
  fi

  BASE_DNS_STRATEGY=prefer_ipv4
  BASE_DNS_PREFER_GO=''
  if [ -s "${SOURCE_DIR}/05_dns.json" ]; then
    VALUE=$(jq_exec -r '.dns.strategy // empty' "${SOURCE_DIR}/05_dns.json" 2>/dev/null || true)
    case "$VALUE" in
      ipv4_only|ipv6_only|prefer_ipv4|prefer_ipv6 ) BASE_DNS_STRATEGY=$VALUE ;;
    esac
    VALUE=$(jq_exec -r '
      ([.dns.servers[]? | select(.type == "local") | .prefer_go?] | .[0]) as $value |
      if $value == null then empty else $value end
    ' "${SOURCE_DIR}/05_dns.json" 2>/dev/null || true)
    case "$VALUE" in
      true|false ) BASE_DNS_PREFER_GO=$VALUE ;;
    esac
  fi

  if [ -z "$BASE_DNS_PREFER_GO" ]; then
    if [ "${SYSTEM:-}" != 'Alpine' ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved; then
      BASE_DNS_PREFER_GO=false
    else
      BASE_DNS_PREFER_GO=true
    fi
  fi
}

# 只生成由本项目管理的基础配置；custom/ 路由和协议入站不在此处修改。
generate_managed_base_config() {
  local TARGET_DIR=$1
  local BASE_LOG_LEVEL=${2:-$LOG_LEVEL_DEFAULT}
  local BASE_DNS_PREFER_GO=${3:-true}
  local BASE_DNS_STRATEGY=${4:-prefer_ipv4}

  mkdir -p "$TARGET_DIR"
  rm -f "${TARGET_DIR}/06_ntp.json"

  cat > "${TARGET_DIR}/00_log.json" << EOF
{
    "log":{
        "disabled":false,
        "level":"${BASE_LOG_LEVEL}",
        "output":"${WORK_DIR}/logs/box.log",
        "timestamp":true
    }
}
EOF

  cat > "${TARGET_DIR}/04_experimental.json" << EOF
{
    "experimental": {
        "cache_file": {
            "enabled": true,
            "path": "${WORK_DIR}/cache.db"
        }
    }
}
EOF

  cat > "${TARGET_DIR}/05_dns.json" << EOF
{
    "dns":{
        "servers":[
            {
                "type":"local",
                "prefer_go": ${BASE_DNS_PREFER_GO}
            }
        ],
        "strategy": "${BASE_DNS_STRATEGY}"
    }
}
EOF

  cat > "${TARGET_DIR}/07_http_clients.json" << 'EOF'
{
    "http_clients": [
        {
            "tag": "http-client-direct"
        }
    ]
}
EOF
}

# 生成 sing-box 配置文件
sing-box_json() {
  local IS_CHANGE=$1
  mkdir -p ${WORK_DIR}/conf ${WORK_DIR}/logs ${WORK_DIR}/subscribe "$CUSTOM_DIR" "$STATE_DIR"
  rm -f "${WORK_DIR}/conf/06_ntp.json"
  routing_migrate_legacy || failure_error " Routing configuration migration failed. " "Custom directory: ${CUSTOM_DIR}"

  # 判断是否为新安装，不为 change 就是新安装
  if [ "$IS_CHANGE" = 'change' ]; then
    # 判断 sing-box 主程序所在路径
    DIR=${WORK_DIR}
  else
    DIR=$TEMP_DIR
    generate_managed_base_config "${WORK_DIR}/conf" "$LOG_LEVEL" "$IS_PREFER_GO" "$STRATEGY"
  fi

  # 生成或规范化 Reality 公私钥，避免空数组元素或无效私钥写入 sing-box 配置。
  array_contains_any INSTALL_PROTOCOLS b j k && normalize_reality_keypair "$DIR/sing-box"
  normalize_ws_domain_mode

  # 获取自签名证书的域名
  TLS_SERVER=$(openssl x509 -noout -ext subjectAltName -in ${WORK_DIR}/cert/cert.pem 2>/dev/null | awk -F 'DNS:' '/DNS:/{gsub(/,.*/, "", $2); print $2}')

  # naive 在 -r 新增协议时，如 cert_200.pem 过期 / 缺失 / SNI 不一致则自动更新
  array_contains m "${INSTALL_PROTOCOLS[@]}" && ssl_certificate "$TLS_SERVER" naive_only

  # 生成 2022-blake3-aes-128-gcm 的 password
  local SIP022_PASSWORD=${SIP022_PASSWORD:-"$(openssl rand -base64 16)"}

  # 第1个协议为 b  (a为全部)，生成 XTLS + Reality 配置
  CHECK_PROTOCOLS=b
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_XTLS_REALITY" ] && PORT_XTLS_REALITY=$(( START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}") ))
    NODE_NAME[11]=${NODE_NAME[11]:-"$NODE_NAME_CONFIRM"} && UUID[11]=${UUID[11]:-"$UUID_CONFIRM"} && REALITY_PRIVATE[11]=${REALITY_PRIVATE[11]:-"$REALITY_PRIVATE"} && REALITY_PUBLIC[11]=${REALITY_PUBLIC[11]:-"$REALITY_PUBLIC"} &&
    cat > ${WORK_DIR}/conf/11_${NODE_TAG[0]}_inbounds.json << EOF
//  "public_key":"${REALITY_PUBLIC[11]}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME[11]} ${NODE_TAG[0]}",
            "listen":"::",
            "listen_port":$PORT_XTLS_REALITY,
            "users":[
                {
                    "uuid":"${UUID[11]}",
                    "flow":"xtls-rprx-vision"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"${TLS_SERVER}",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"${TLS_SERVER}",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE[11]}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "multiplex":{
                "enabled":false,
                "padding":false,
                "brutal":{
                    "enabled":false,
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 Hysteria2 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_HYSTERIA2" ] && PORT_HYSTERIA2=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    [ "$IS_HOPPING" = 'is_hopping' ] && add_port_hopping_nat $PORT_HOPPING_START $PORT_HOPPING_END $PORT_HYSTERIA2
    NODE_NAME[12]=${NODE_NAME[12]:-"$NODE_NAME_CONFIRM"} && UUID[12]=${UUID[12]:-"$UUID_CONFIRM"}
    HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]}}"
    local HY2_REALM_CONFIG=""
    if [ "$IS_HY2_REALM" = 'is_hy2_realm' ]; then
      HY2_REALM_CONFIG=$(cat <<EOF_REALM
,
            "realm":{
                "server_url":"https://realm.hy2.io",
                "token":"public",
                "realm_id":"${HY2_REALM_ID}",
                "stun_servers":[
                    "turn.cloudflare.com:3478",
                    "stun.nextcloud.com:3478",
                    "stun.sip.us:3478",
                    "global.stun.twilio.com:3478"
                ]
            }
EOF_REALM
)
    fi
    cat > ${WORK_DIR}/conf/12_${NODE_TAG[1]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"hysteria2",
            "tag":"${NODE_NAME[12]} ${NODE_TAG[1]}",
            "listen":"::",
            "listen_port":$PORT_HYSTERIA2,
            "users":[
                {
                    "password":"${UUID[12]}"
                }
            ],
            "ignore_client_bandwidth":false${HY2_REALM_CONFIG},
            "tls":{
                "enabled":true,
                "alpn":[
                    "h3"
                ],
                "min_version":"1.3",
                "max_version":"1.3",
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            }
        }
    ]
}
EOF
  fi

  # 生成 Tuic V5 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_TUIC" ] && PORT_TUIC=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[13]=${NODE_NAME[13]:-"$NODE_NAME_CONFIRM"} && UUID[13]=${UUID[13]:-"$UUID_CONFIRM"} && TUIC_PASSWORD=${TUIC_PASSWORD:-"$UUID_CONFIRM"} && TUIC_CONGESTION_CONTROL=${TUIC_CONGESTION_CONTROL:-"bbr"}
    cat > ${WORK_DIR}/conf/13_${NODE_TAG[2]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"tuic",
            "tag":"${NODE_NAME[13]} ${NODE_TAG[2]}",
            "listen":"::",
            "listen_port":$PORT_TUIC,
            "users":[
                {
                    "uuid":"${UUID[13]}",
                    "password":"$TUIC_PASSWORD"
                }
            ],
            "congestion_control": "$TUIC_CONGESTION_CONTROL",
            "zero_rtt_handshake": false,
            "tls":{
                "enabled":true,
                "alpn":[
                    "h3"
                ],
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            }
        }
    ]
}
EOF
  fi

  # 生成 ShadowTLS V5 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_SHADOWTLS" ] && PORT_SHADOWTLS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[14]=${NODE_NAME[14]:-"$NODE_NAME_CONFIRM"} && UUID[14]=${UUID[14]:-"$UUID_CONFIRM"} && SHADOWTLS_PASSWORD=${SHADOWTLS_PASSWORD:-"$SIP022_PASSWORD"} && SHADOWTLS_METHOD=${SHADOWTLS_METHOD:-"2022-blake3-aes-128-gcm"}

    cat > ${WORK_DIR}/conf/14_${NODE_TAG[3]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"shadowtls",
            "tag":"${NODE_NAME[14]} ${NODE_TAG[3]}",
            "listen":"::",
            "listen_port":$PORT_SHADOWTLS,
            "detour":"shadowtls-in",
            "version":3,
            "users":[
                {
                    "password":"${UUID[14]}"
                }
            ],
            "handshake":{
                "server":"${TLS_SERVER}",
                "server_port":443
            },
            "strict_mode":true
        },
        {
            "type":"shadowsocks",
            "tag":"shadowtls-in",
            "listen":"127.0.0.1",
            "network":"tcp",
            "method":"$SHADOWTLS_METHOD",
            "password":"$SHADOWTLS_PASSWORD",
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 Shadowsocks 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_SHADOWSOCKS" ] && PORT_SHADOWSOCKS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[15]=${NODE_NAME[15]:-"$NODE_NAME_CONFIRM"} && SHADOWSOCKS_PASSWORD=${SHADOWSOCKS_PASSWORD:-"$SIP022_PASSWORD"} && SHADOWSOCKS_METHOD=${SHADOWSOCKS_METHOD:-"2022-blake3-aes-128-gcm"}
    cat > ${WORK_DIR}/conf/15_${NODE_TAG[4]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"shadowsocks",
            "tag":"${NODE_NAME[15]} ${NODE_TAG[4]}",
            "listen":"::",
            "listen_port":$PORT_SHADOWSOCKS,
            "method":"${SHADOWSOCKS_METHOD}",
            "password":"${SHADOWSOCKS_PASSWORD}",
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 Trojan 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_TROJAN" ] && PORT_TROJAN=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[16]=${NODE_NAME[16]:-"$NODE_NAME_CONFIRM"} && TROJAN_PASSWORD=${TROJAN_PASSWORD:-"$UUID_CONFIRM"}
    cat > ${WORK_DIR}/conf/16_${NODE_TAG[5]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"trojan",
            "tag":"${NODE_NAME[16]} ${NODE_TAG[5]}",
            "listen":"::",
            "listen_port":$PORT_TROJAN,
            "users":[
                {
                    "password":"$TROJAN_PASSWORD"
                }
            ],
            "tls":{
                "enabled":true,
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 vmess + ws 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_VMESS_WS" ] && PORT_VMESS_WS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[17]=${NODE_NAME[17]:-"$NODE_NAME_CONFIRM"} && UUID[17]=${UUID[17]:-"$UUID_CONFIRM"} && WS_SERVER_IP[17]=${WS_SERVER_IP[17]:-"$SERVER_IP"} && CDN[17]=${CDN[17]:-"$CDN"} && CDN_PORT[17]=${CDN_PORT[17]:-${CDN_PORT:-80}} && VMESS_WS_PATH=${VMESS_WS_PATH:-"${UUID[17]}-vmess"}
    local VMESS_WS_HOST
    VMESS_WS_HOST=$(ws_host_for h)
    cat > ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json << EOF
//  "WS_SERVER_IP_SHOW": "${WS_SERVER_IP[17]}"
//  "VMESS_HOST_DOMAIN": "${VMESS_WS_HOST}"
//  "CDN": "${CDN[17]}"
//  "CDN_PORT": "${CDN_PORT[17]}"
{
    "inbounds":[
        {
            "type":"vmess",
            "tag":"${NODE_NAME[17]} ${NODE_TAG[6]}",
            "listen":"::",
            "listen_port":$PORT_VMESS_WS,
            "tcp_fast_open":false,
            "proxy_protocol":false,
            "users":[
                {
                    "uuid":"${UUID[17]}",
                    "alterId":0
                }
            ],
            "transport":{
                "type":"ws",
                "path":"/$VMESS_WS_PATH",
                "max_early_data":2560,
                "early_data_header_name":"Sec-WebSocket-Protocol"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 vless + ws + tls 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_VLESS_WS" ] && PORT_VLESS_WS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[18]=${NODE_NAME[18]:-"$NODE_NAME_CONFIRM"} && UUID[18]=${UUID[18]:-"$UUID_CONFIRM"} && WS_SERVER_IP[18]=${WS_SERVER_IP[18]:-"$SERVER_IP"} && CDN[18]=${CDN[18]:-"$CDN"} && CDN_PORT[18]=${CDN_PORT[18]:-${CDN_PORT:-443}} && VLESS_WS_PATH=${VLESS_WS_PATH:-"${UUID[18]}-vless"}
    local VLESS_WS_HOST
    VLESS_WS_HOST=$(ws_host_for i)
    cat > ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json << EOF
//  "WS_SERVER_IP_SHOW": "${WS_SERVER_IP[18]}"
//  "CDN": "${CDN[18]}"
//  "CDN_PORT": "${CDN_PORT[18]}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME[18]} ${NODE_TAG[7]}",
            "listen":"::",
            "listen_port":$PORT_VLESS_WS,
            "tcp_fast_open":false,
            "proxy_protocol":false,
            "users":[
                {
                    "name":"sing-box",
                    "uuid":"${UUID[18]}"
                }
            ],
            "transport":{
                "type":"ws",
                "path":"/$VLESS_WS_PATH",
                "max_early_data":2560,
                "early_data_header_name":"Sec-WebSocket-Protocol"
            },
            "tls":{
                "enabled":true,
                "server_name":"${VLESS_WS_HOST}",
                "min_version":"1.3",
                "max_version":"1.3",
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 H2 + Reality 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_H2_REALITY" ] && PORT_H2_REALITY=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[19]=${NODE_NAME[19]:-"$NODE_NAME_CONFIRM"} && UUID[19]=${UUID[19]:-"$UUID_CONFIRM"} && REALITY_PRIVATE[19]=${REALITY_PRIVATE[19]:-"$REALITY_PRIVATE"} && REALITY_PUBLIC[19]=${REALITY_PUBLIC[19]:-"$REALITY_PUBLIC"}
    cat > ${WORK_DIR}/conf/19_${NODE_TAG[8]}_inbounds.json << EOF
//  "public_key":"${REALITY_PUBLIC[19]}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME[19]} ${NODE_TAG[8]}",
            "listen":"::",
            "listen_port":$PORT_H2_REALITY,
            "users":[
                {
                    "uuid":"${UUID[19]}"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"${TLS_SERVER}",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"${TLS_SERVER}",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE[19]}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "transport":{
                "type": "http"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 gRPC + Reality 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_GRPC_REALITY" ] && PORT_GRPC_REALITY=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[20]=${NODE_NAME[20]:-"$NODE_NAME_CONFIRM"} && UUID[20]=${UUID[20]:-"$UUID_CONFIRM"} && REALITY_PRIVATE[20]=${REALITY_PRIVATE[20]:-"$REALITY_PRIVATE"} && REALITY_PUBLIC[20]=${REALITY_PUBLIC[20]:-"$REALITY_PUBLIC"}
    cat > ${WORK_DIR}/conf/20_${NODE_TAG[9]}_inbounds.json << EOF
//  "public_key":"${REALITY_PUBLIC[20]}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME[20]} ${NODE_TAG[9]}",
            "listen":"::",
            "listen_port":$PORT_GRPC_REALITY,
            "users":[
                {
                    "uuid":"${UUID[20]}"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"${TLS_SERVER}",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"${TLS_SERVER}",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE[20]}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "transport":{
                "type": "grpc",
                "service_name": "grpc"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 anytls 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_ANYTLS" ] && PORT_ANYTLS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[21]=${NODE_NAME[21]:-"$NODE_NAME_CONFIRM"} && UUID[21]=${UUID[21]:-"$UUID_CONFIRM"}

    cat > ${WORK_DIR}/conf/21_${NODE_TAG[10]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"anytls",
            "tag":"${NODE_NAME[21]} ${NODE_TAG[10]}",
            "listen":"::",
            "listen_port":$PORT_ANYTLS,
            "users":[
                {
                    "password":"${UUID[21]}"
                }
            ],
            "padding_scheme":[],
            "tls":{
                "enabled":true,
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            }
        }
    ]
}
EOF
  fi

  # 生成 naive 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if array_contains "$CHECK_PROTOCOLS" "${INSTALL_PROTOCOLS[@]}"; then
    [ -z "$PORT_NAIVE" ] && PORT_NAIVE=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[22]=${NODE_NAME[22]:-"$NODE_NAME_CONFIRM"} && UUID[22]=${UUID[22]:-"$UUID_CONFIRM"}

    cat > ${WORK_DIR}/conf/22_${NODE_TAG[11]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"naive",
            "tag":"${NODE_NAME[22]} ${NODE_TAG[11]}",
            "listen":"::",
            "listen_port":$PORT_NAIVE,
            "users":[
                {
                    "username":"${UUID[22]}",
                    "password":"${UUID[22]}"
                }
            ],
            "tls":{
                "enabled":true,
                "certificate_path":"${WORK_DIR}/cert/cert_200.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            }
        }
    ]
}
EOF
  fi
}

# Sing-box 生成守护进程文件
sing-box_systemd() {
  if [ "$SYSTEM" = 'Alpine' ]; then
    local OPENRC_SERVICE="#!/sbin/openrc-run

name=\"sing-box\"
description=\"sing-box service\"
command=\"${WORK_DIR}/sing-box\"
command_args=\"run -C ${WORK_DIR}/conf\"
pidfile=\"/var/run/\${RC_SVCNAME}.pid\"
command_background=\"yes\"
output_log=\"${WORK_DIR}/logs/sing-box.log\"
error_log=\"${WORK_DIR}/logs/sing-box.log\"

depend() {
    need net
    after net"

    # 如果配置了 Nginx，添加依赖
    [ -n "$PORT_NGINX" ] && OPENRC_SERVICE+="
    need nginx"

    # 添加 reload 和 start_pre 函数
    OPENRC_SERVICE+="
}

reload() {
    ebegin \"Reloading \${RC_SVCNAME}\"
    start-stop-daemon --signal HUP --pidfile \$pidfile
    eend \$? \"Failed to reload \${RC_SVCNAME}\"
}

start_pre() {
    # 确保日志目录和PID目录存在并有正确权限
    mkdir -p ${WORK_DIR}/logs
    mkdir -p /var/run
    chmod 755 /var/run"

    # 如果配置了 Nginx，启动 Nginx
    [ -n "$PORT_NGINX" ] && OPENRC_SERVICE+="
    $(command -v nginx) -c ${WORK_DIR}/nginx.conf"

    OPENRC_SERVICE+="
    # 确保 PID 文件不存在，避免启动失败
    rm -f \$pidfile
}"

    # 添加 stop_post 函数，用于在服务停止后清理 nginx 进程
    [ -n "$PORT_NGINX" ] && OPENRC_SERVICE+="

stop_post() {
    # 停止 nginx：优先用内置命令
    if command -v /usr/sbin/nginx >/dev/null 2>&1; then
        /usr/sbin/nginx -s quit -c ${WORK_DIR}/nginx.conf 2>/dev/null
        sleep 1 # 等待优雅关闭
        # 如果仍运行，用 SIGKILL
        local NGINX_MASTER=\$(pgrep -f \"nginx: master process /usr/sbin/nginx -c ${WORK_DIR}/nginx.conf\")
        if [ -n \"\$NGINX_MASTER\" ]; then
            kill -KILL \$NGINX_MASTER 2>/dev/null
        fi
    fi
}

stop() {
    ebegin \"Stopping \${RC_SVCNAME}\"
    # 先停止主进程（OpenRC 会调用）
    start-stop-daemon --stop --pidfile \$pidfile --retry 5
    eend \$? \"Failed to stop \${RC_SVCNAME}\"

    # 然后运行 post 清理
    stop_post
}"

    echo "$OPENRC_SERVICE" > ${SINGBOX_DAEMON_FILE}
    chmod +x ${SINGBOX_DAEMON_FILE}
  else
    # 原有的 systemd 服务创建代码
    SING_BOX_SERVICE="[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
WorkingDirectory=${WORK_DIR}
"
    [[ -n "$PORT_NGINX" && "$IS_CENTOS" != 'CentOS7' ]] && SING_BOX_SERVICE+="ExecStartPre=$(command -v nginx) -c ${WORK_DIR}/nginx.conf
"
    SING_BOX_SERVICE+="ExecStart=${WORK_DIR}/sing-box run -C ${WORK_DIR}/conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target"

    echo "$SING_BOX_SERVICE" > ${SINGBOX_DAEMON_FILE}
    systemctl daemon-reload
  fi
}

# Argo 生成守护进程文件
argo_systemd() {
  if [ "$SYSTEM" = 'Alpine' ]; then
    # 分离命令和参数
    local COMMAND="${ARGO_RUNS%% --*}"   # 提取命令部分（包括 cloudflared tunnel）
    local ARGS="${ARGO_RUNS#$COMMAND }"  # 提取参数部分

    cat > ${ARGO_DAEMON_FILE} << EOF
#!/sbin/openrc-run

name="argo"
description="Cloudflare Tunnel service"
command="${COMMAND}"
command_args="${ARGS}"
pidfile="/var/run/\${RC_SVCNAME}.pid"
command_background="yes"
output_log="${WORK_DIR}/logs/argo.log"
error_log="${WORK_DIR}/logs/argo.log"

depend() {
    need net
    after net
}

start_pre() {
    # 确保日志目录和PID目录存在并有正确权限
    mkdir -p ${WORK_DIR}/logs
    mkdir -p /var/run
    chmod 755 /var/run

    # 确保 PID 文件不存在，避免启动失败
    rm -f \$pidfile
}
EOF
    chmod +x ${ARGO_DAEMON_FILE}
  else
    # 原有的 systemd 服务创建代码
    cat > ${ARGO_DAEMON_FILE} << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORK_DIR
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=${ARGO_RUNS}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
}

# 获取原有各协议的参数，先清空所有的 key-value
fetch_nodes_value() {
  unset NODE_NAME PORT_XTLS_REALITY UUID TLS_SERVER REALITY_PRIVATE REALITY_PUBLIC PORT_HYSTERIA2 HY2_REALM_ID IS_HY2_REALM PORT_TUIC TUIC_PASSWORD TUIC_CONGESTION_CONTROL PORT_SHADOWTLS SHADOWTLS_PASSWORD SHADOWSOCKS_METHOD PORT_SHADOWSOCKS PORT_TROJAN TROJAN_PASSWORD PORT_VMESS_WS VMESS_WS_PATH WS_SERVER_IP WS_SERVER_IP_SHOW VMESS_HOST_DOMAIN CDN CDN_PORT PORT_VLESS_WS VLESS_WS_PATH VLESS_HOST_DOMAIN PORT_H2_REALITY PORT_GRPC_REALITY ARGO_DOMAIN PORT_ANYTLS PORT_NAIVE SELF_SIGNED_FINGERPRINT_SHA256 SELF_SIGNED_FINGERPRINT_BASE64

  # 获取公共数据
  ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1 && SERVER_IP=$(awk -F '"' '/"WS_SERVER_IP_SHOW"/{print $4; exit}' ${WORK_DIR}/conf/*-ws*inbounds.json) || SERVER_IP=$(grep -A1 '"tag"' ${WORK_DIR}/list | sed -E '/-ws(-tls)*",$/{N;d}' | awk -F '"' '/"server"/{count++; if (count == 1) {print $4; exit}}')
  EXISTED_PORTS=$(awk -F ':|,' '/listen_port/{print $2}' ${WORK_DIR}/conf/*_inbounds.json)
  START_PORT=$(awk 'NR == 1 { min = $0 } { if ($0 < min) min = $0; count++ } END {print min}' <<< "$EXISTED_PORTS")
  [[ -z "$NODE_NAME_CONFIRM" && -s ${WORK_DIR}/subscribe/clash ]] && NODE_NAME_CONFIRM=$(awk -F "'" '/u: &u/{print $2; exit}' ${WORK_DIR}/subscribe/clash)
  if [ -z "${FINGER_PRINT_EXPLICIT:-}" ]; then
    local FINGER_PRINT_NOW
    FINGER_PRINT_NOW=$(awk -F '"' '/"fingerprint"/{print $4; exit}' ${WORK_DIR}/list 2>/dev/null)
    [ -n "$FINGER_PRINT_NOW" ] && FINGER_PRINT="$FINGER_PRINT_NOW"
  fi
  FINGER_PRINT=${FINGER_PRINT:-${FINGER_PRINT_DEFAULT:-chrome}}

  # 如有 Argo，获取 Argo Tunnel
  [[ ${STATUS[1]} =~ $(text 27)|$(text 28) ]] && grep -Fq -- '--url' "$ARGO_DAEMON_FILE" && { cmd_systemctl enable argo; sleep 2 && cmd_systemctl status argo &>/dev/null && fetch_quicktunnel_domain; }

  # 获取 Nginx 端口和路径
  [[ "${IS_SUB}" = 'is_sub' || "${IS_ARGO}" = 'is_argo' ]] && local NGINX_JSON=$(cat ${WORK_DIR}/nginx.conf) &&
  PORT_NGINX=$(awk '/listen/{print $2; exit}' <<< "$NGINX_JSON") &&
  UUID_CONFIRM=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<< "$NGINX_JSON" | sed -n '1p')

  local NODE_CONF JSON

  # 获取 XTLS + Reality key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[0]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[11]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[0]}.*/\1/p" <<< "$JSON")
    PORT_XTLS_REALITY=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON")
    UUID[11]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON")
    REALITY_PRIVATE[11]=$(awk -F '"' '/"private_key"/{print $4}' <<< "$JSON")
    REALITY_PUBLIC[11]=$(awk -F '"' '/"public_key"/{print $4}' <<< "$JSON")
  fi

  # 获取 Hysteria2 key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[12]=$(awk -F '"' -v suffix=" ${NODE_TAG[1]}" '/"tag"[[:space:]]*:/ {v=$4; sub(suffix"$", "", v); print v; exit}' <<< "$JSON")
    PORT_HYSTERIA2=$(awk -F ':' '/"listen_port"[[:space:]]*:/ {gsub(/[[:space:],]/, "", $2); print $2; exit}' <<< "$JSON")
    UUID[12]=$(awk -F '"' '/"password"[[:space:]]*:/ {count++; if (count == 1) {print $4; exit}}' <<< "$JSON")
    HY2_UP=${HY2_UP:-"$(sed -n '/type: hysteria2/ s/.*,[ ]*up:[ ]*"\([0-9]\+\)[ ]*Mbps.*/\1/gp' $WORK_DIR/subscribe/proxies 2>/dev/null)"}
    HY2_DOWN=${HY2_DOWN:-"$(sed -n '/type: hysteria2/ s/.*,[ ]*down:[ ]*"\([0-9]\+\)[ ]*Mbps.*/\1/gp' $WORK_DIR/subscribe/proxies 2>/dev/null)"}
    HY2_UP=${HY2_UP:-"$(sed -n '/type: hysteria2/ s/.*,[ ]*up:[ ]*"\([0-9]\+\)[ ]*Mbps.*/\1/gp' $WORK_DIR/list)"}
    HY2_DOWN=${HY2_DOWN:-"$(sed -n '/type: hysteria2/ s/.*,[ ]*down:[ ]*"\([0-9]\+\)[ ]*Mbps.*/\1/gp' $WORK_DIR/list)"}
    if grep -q '"realm"[[:space:]]*:' <<< "$JSON"; then
      IS_HY2_REALM=is_hy2_realm
      HY2_REALM_ID=$(awk -F '"' '/"realm_id"[[:space:]]*:/{print $4; exit}' <<< "$JSON")
      HY2_REALM_ID=${HY2_REALM_ID:-${UUID[12]}}
    fi
    check_port_hopping_nat
  fi

  # 获取 Tuic V5 key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[2]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[13]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[2]}.*/\1/p" <<< "$JSON")
    PORT_TUIC=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON")
    UUID[13]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON")
    TUIC_PASSWORD=$(awk -F '"' '/"password"/{print $4}' <<< "$JSON")
    TUIC_CONGESTION_CONTROL=$(awk -F '"' '/"congestion_control"/{print $4}' <<< "$JSON")
  fi

  # 获取 ShadowTLS key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[3]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[14]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[3]}.*/\1/p" <<< "$JSON")
    PORT_SHADOWTLS=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON")
    UUID[14]=$(awk -F '"' '/"password"/{count++; if (count == 1) {print $4; exit}}' <<< "$JSON")
    SHADOWTLS_PASSWORD=$(awk -F '"' '/"password"/{count++; if (count == 2) {print $4; exit}}' <<< "$JSON")
    SHADOWTLS_METHOD=$(awk -F '"' '/"method"/{print $4}' <<< "$JSON")
  fi

  # 获取 Shadowsocks key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[4]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[15]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[4]}.*/\1/p" <<< "$JSON")
    PORT_SHADOWSOCKS=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON")
    SHADOWSOCKS_PASSWORD=$(awk -F '"' '/"password"/{print $4}' <<< "$JSON")
    SHADOWSOCKS_METHOD=$(awk -F '"' '/"method"/{print $4}' <<< "$JSON")
  fi

  # 获取 Trojan key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[5]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[16]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[5]}.*/\1/p" <<< "$JSON")
    PORT_TROJAN=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON")
    TROJAN_PASSWORD=$(awk -F '"' '/"password"/{print $4}' <<< "$JSON")
  fi

  # 获取 vmess + ws key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[6]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[17]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[6]}.*/\1/p" <<< "$JSON")
    PORT_VMESS_WS=$(json_number_value listen_port <<< "$JSON")
    UUID[17]=$(json_string_value uuid <<< "$JSON")
    VMESS_WS_PATH=$(json_string_value path <<< "$JSON")
    VMESS_WS_PATH=${VMESS_WS_PATH#/}
    WS_SERVER_IP[17]=$(json_string_value WS_SERVER_IP_SHOW <<< "$JSON")
    CDN[17]=$(json_string_value CDN <<< "$JSON")
    CDN_PORT[17]=$(json_string_value CDN_PORT <<< "$JSON")
    if [ -n "${ARGO_DAEMON_FILE:-}" ] && [ -s "$ARGO_DAEMON_FILE" ]; then
      ARGO_DOMAIN=$(json_string_value VMESS_HOST_DOMAIN <<< "$JSON")
    else
      VMESS_HOST_DOMAIN=$(json_string_value VMESS_HOST_DOMAIN <<< "$JSON")
    fi
    normalize_ws_domains
  fi

  # 获取 vless + ws + tls key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[7]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[18]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[7]}.*/\1/p" <<< "$JSON")
    PORT_VLESS_WS=$(json_number_value listen_port <<< "$JSON")
    UUID[18]=$(json_string_value uuid <<< "$JSON")
    VLESS_WS_PATH=$(json_string_value path <<< "$JSON")
    VLESS_WS_PATH=${VLESS_WS_PATH#/}
    WS_SERVER_IP[18]=$(json_string_value WS_SERVER_IP_SHOW <<< "$JSON")
    CDN[18]=$(json_string_value CDN <<< "$JSON")
    CDN_PORT[18]=$(json_string_value CDN_PORT <<< "$JSON")
    if [ -n "${ARGO_DAEMON_FILE:-}" ] && [ -s "$ARGO_DAEMON_FILE" ]; then
      ARGO_DOMAIN=$(json_string_value server_name <<< "$JSON")
    else
      VLESS_HOST_DOMAIN=$(json_string_value server_name <<< "$JSON")
    fi
    normalize_ws_domains
  fi

  # 获取 H2 + Reality key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[8]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[19]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[8]}.*/\1/p" <<< "$JSON")
    PORT_H2_REALITY=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON")
    UUID[19]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON")
    REALITY_PRIVATE[19]=$(awk -F '"' '/"private_key"/{print $4}' <<< "$JSON")
    REALITY_PUBLIC[19]=$(awk -F '"' '/"public_key"/{print $4}' <<< "$JSON")
  fi

  # 获取 gRPC + Reality key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[9]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[20]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[9]}.*/\1/p" <<< "$JSON")
    PORT_GRPC_REALITY=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON")
    UUID[20]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON")
    REALITY_PRIVATE[20]=$(awk -F '"' '/"private_key"/{print $4}' <<< "$JSON")
    REALITY_PUBLIC[20]=$(awk -F '"' '/"public_key"/{print $4}' <<< "$JSON")
  fi

  # 获取 anytls key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[10]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[21]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[10]}.*/\1/p" <<< "$JSON")
    PORT_ANYTLS=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON")
    UUID[21]=$(awk -F '"' '/"password"/{print $4}' <<< "$JSON")
  fi

  # 获取 naive key-value
  NODE_CONF=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[11]}_inbounds.json")
  if [ -s "$NODE_CONF" ]; then
    JSON=$(cat "$NODE_CONF")
    NODE_NAME[22]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[11]}.*/\1/p" <<< "$JSON")
    PORT_NAIVE=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON")
    UUID[22]=$(awk -F '"' '/"username"/{print $4; exit}' <<< "$JSON")
  fi

  return 0
}

# 获取 Argo 临时隧道域名
fetch_quicktunnel_domain() {
  unset CLOUDFLARED_PID METRICS_ADDRESS ARGO_DOMAIN
  local QUICKTUNNEL_ERROR_TIME=20
  until [ -n "$ARGO_DOMAIN" ]; do
    local CLOUDFLARED_PID=$(ps -eo pid,args | awk -v work_dir="$WORK_DIR" '$0~(work_dir"/cloudflared"){print $1;exit}')
    [[ -z "$METRICS_ADDRESS" && "$CLOUDFLARED_PID" =~ ^[0-9]+$ ]] && local METRICS_ADDRESS=$(ss -nltp | grep "pid=$CLOUDFLARED_PID" | awk '{print $4}')
    [ -n "$METRICS_ADDRESS" ] && ARGO_DOMAIN=$(wget -qO- http://$METRICS_ADDRESS/quicktunnel | awk -F '"' '{print $4}')
    if [[ ! "$ARGO_DOMAIN" =~ trycloudflare\.com$ ]]; then
      (( QUICKTUNNEL_ERROR_TIME-- )) || true
      [ "$QUICKTUNNEL_ERROR_TIME" = '0' ] && error " $(text 93) "
      sleep 2
    else
      break
    fi
  done

  # 把临时隧道写到 Sing-box 相应的 ws inbounds 文件
  normalize_ws_domain_mode
  [ -s ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json ] && sed -i "s/VMESS_HOST_DOMAIN.*/VMESS_HOST_DOMAIN\": \"$ARGO_DOMAIN\"/" ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json
  [ -s ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json ] && sed -i "s/\"server_name\":.*/\"server_name\": \"$ARGO_DOMAIN\",/" ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json
}
