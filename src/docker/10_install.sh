
# 安装 sing-box 容器
install() {
  # 下载 sing-box
  echo "正在下载 sing-box ..."
  local ONLINE=$(check_latest_sing-box)
  wget https://github.com/SagerNet/sing-box/releases/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz -O- | tar xz -C ${WORK_DIR} sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box && mv ${WORK_DIR}/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box ${WORK_DIR}/sing-box && rm -rf ${WORK_DIR}/sing-box-$ONLINE-linux-$SING_BOX_ARCH

  # 下载 jq
  echo "正在下载 jq ..."
  wget -O ${WORK_DIR}/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$JQ_ARCH && chmod +x ${WORK_DIR}/jq

  # 下载 qrencode
  echo "正在下载 qrencode ..."
  wget -O ${WORK_DIR}/qrencode https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-$QRENCODE_ARCH && chmod +x ${WORK_DIR}/qrencode

  # 下载 cloudflared
  echo "正在下载 cloudflared ..."
  wget -O ${WORK_DIR}/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH && chmod +x ${WORK_DIR}/cloudflared

  # 生成100年的自签证书，区分使用 IPv4 / IPv6 / 域名
  echo "生成自签证书 ..."
  openssl ecparam -genkey -name prime256v1 -out ${WORK_DIR}/cert/private.key
  openssl req -new -x509 -days 36500 -key ${WORK_DIR}/cert/private.key -out ${WORK_DIR}/cert/cert.pem -subj "/CN=mozilla.org" -addext "subjectAltName = DNS:addons.mozilla.org"

  # 检查系统是否已经安装 tcp-brutal
  IS_BRUTAL=false && [ -x "$(type -p lsmod)" ] && lsmod 2>/dev/null | grep -q 'brutal' && IS_BRUTAL=true
  [ "$IS_BRUTAL" = 'false' ] && [ -x "$(type -p modprobe)" ] && modprobe brutal 2>/dev/null && IS_BRUTAL=true

  # 生成 sing-box 配置文件
  for i in {1..3}; do
    ping -c 1 -W 1 "151.101.1.91" &>/dev/null && local IS_IPV4=is_ipv4 && break
  done

  for i in {1..3}; do
    ping -c 1 -W 1 "2a04:4e42:200::347" &>/dev/null && local IS_IPV6=is_ipv6 && break
  done

  case "${IS_IPV4}@${IS_IPV6}" in
    is_ipv4@is_ipv6)
      local STRATEGY=prefer_ipv4
      ;;
    @is_ipv6)
      local STRATEGY=ipv6_only
      ;;
    *)
      local STRATEGY=ipv4_only
      ;;
  esac

  if [[ "$REALITY_PRIVATE" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    # convert base64url -> base64 (standard), add padding
    local B64=$(printf '%s' "$REALITY_PRIVATE" | tr '_-' '/+')
    local MOD=$(( ${#B64} % 4 ))
    if [ $MOD -eq 2 ]; then
      B64="${B64}=="
    elif [ $MOD -eq 3 ]; then
      B64="${B64}="
    elif [ $MOD -eq 1 ]; then
      echo "Invalid base64url length" >&2
      exit 1
    fi

    # decode to raw 32 bytes
    echo "$B64" | base64 -d > /tmp/_x25519_priv_raw

    local PRIV_LEN=$(stat -c%s /tmp/_x25519_priv_raw 2>/dev/null || stat -f%z /tmp/_x25519_priv_raw)
    [ "$PRIV_LEN" -ne 32 ] && echo "Decoded private key is ${PRIV_LEN} bytes (expected 32)." >&2 && echo "Make sure you passed a 32-byte X25519 private scalar (base64url, no padding)." >&2 && rm -f /tmp/_x25519_* && exit 1

    # DER prefix for PKCS#8 private key with OID 1.3.101.110 (X25519)
    # Hex: 30 2e 02 01 00 30 05 06 03 2b 65 6e 04 22 04 20
    local PREFIX_HEX="302e020100300506032b656e04220420"

    # append raw private key hex and create DER
    local PRIV_HEX=$(xxd -p -c 256 /tmp/_x25519_priv_raw | tr -d '\n')
    printf "%s%s" "$PREFIX_HEX" "$PRIV_HEX" | xxd -r -p > /tmp/_x25519_priv_der

    # convert DER PKCS8 -> PEM private key
    openssl pkcs8 -inform DER -in /tmp/_x25519_priv_der -nocrypt -out /tmp/_x25519_priv_pem 2>/dev/null

    # extract public key in DER
    openssl pkey -in /tmp/_x25519_priv_pem -pubout -outform DER > /tmp/_x25519_pub_der 2>/dev/null

    # last 32 bytes are the raw public key
    tail -c 32 /tmp/_x25519_pub_der > /tmp/_x25519_pub_raw

    # encode to base64url (no padding)
    local REALITY_PUBLIC=$(base64 -w0 /tmp/_x25519_pub_raw | tr '+/' '-_' | sed -E 's/=+$//')

    rm -f /tmp/_x25519_*
  else
    local REALITY_KEYPAIR=$(${WORK_DIR}/sing-box generate reality-keypair) && REALITY_PRIVATE=$(awk '/PrivateKey/{print $NF}' <<< "$REALITY_KEYPAIR") && REALITY_PUBLIC=$(awk '/PublicKey/{print $NF}' <<< "$REALITY_KEYPAIR")
  fi

  local SIP022_PASSWORD=$(${WORK_DIR}/sing-box generate rand --base64 16)
  local SIP022_METHOD="2022-blake3-aes-128-gcm"
  local UUID=${UUID:-"$(${WORK_DIR}/sing-box generate uuid)"}
  local NODE_NAME=${NODE_NAME:-"sing-box"}
  local CDN=${CDN:-"skk.moe"}

  # 检测是否解锁 chatGPT，首先检查API访问
  local CHECK_RESULT1=$(wget --timeout=2 --tries=2 --retry-connrefused --waitretry=5 -qO- --content-on-error --header='authority: api.openai.com' --header='accept: */*' --header='accept-language: en-US,en;q=0.9' --header='authorization: Bearer null' --header='content-type: application/json' --header='origin: https://platform.openai.com' --header='referer: https://platform.openai.com/' --header='sec-ch-ua: "Google Chrome";v="125", "Chromium";v="125", "Not.A/Brand";v="24"' --header='sec-ch-ua-mobile: ?0' --header='sec-ch-ua-platform: "Windows"' --header='sec-fetch-dest: empty' --header='sec-fetch-mode: cors' --header='sec-fetch-site: same-site' --user-agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36' 'https://api.openai.com/compliance/cookie_requirements')

  # 如果API检测失败或者检测到unsupported_country,直接返回ban
  if [ -z "$CHECK_RESULT1" ] || grep -qi 'unsupported_country' <<< "$CHECK_RESULT1"; then
    CHATGPT_OUT=warp-ep
  fi

  # API检测通过后,继续检查网页访问
  local CHECK_RESULT2=$(wget --timeout=2 --tries=2 --retry-connrefused --waitretry=5 -qO- --content-on-error --header='authority: ios.chat.openai.com' --header='accept: */*;q=0.8,application/signed-exchange;v=b3;q=0.7' --header='accept-language: en-US,en;q=0.9' --header='sec-ch-ua: "Google Chrome";v="125", "Chromium";v="125", "Not.A/Brand";v="24"' --header='sec-ch-ua-mobile: ?0' --header='sec-ch-ua-platform: "Windows"' --header='sec-fetch-dest: document' --header='sec-fetch-mode: navigate' --header='sec-fetch-site: none' --header='sec-fetch-user: ?1' --header='upgrade-insecure-requests: 1' --user-agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36' https://ios.chat.openai.com/)

  # 检查第二个结果
  if [ -z "$CHECK_RESULT2" ] || grep -qi 'VPN' <<< "$CHECK_RESULT2"; then
    CHATGPT_OUT=warp-ep
  else
    CHATGPT_OUT=direct
  fi

  # 生成 log 配置
  cat > ${WORK_DIR}/conf/00_log.json << EOF
{
    "log":{
        "disabled":false,
        "level":"error",
        "output":"${WORK_DIR}/logs/box.log",
        "timestamp":true
    }
}
EOF

  # 生成 outbound 配置
  cat > ${WORK_DIR}/conf/01_outbounds.json << EOF
{
    "outbounds":[
        {
            "type":"direct",
            "tag":"direct"
        }
    ]
}
EOF

  # 生成 endpoint 配置
  cat > ${WORK_DIR}/conf/02_endpoints.json << EOF
{
    "endpoints":[
        {
            "type":"wireguard",
            "tag":"warp-ep",
            "mtu":1280,
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

  # 生成 route 配置
  cat > ${WORK_DIR}/conf/03_route.json << EOF
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

  # 生成缓存文件
  cat > ${WORK_DIR}/conf/04_experimental.json << EOF
{
    "experimental": {
        "cache_file": {
            "enabled": true,
            "path": "${WORK_DIR}/cache.db"
        }
    }
}
EOF

  # 生成 dns 配置文件
  cat > ${WORK_DIR}/conf/05_dns.json << EOF
{
    "dns":{
        "servers":[
            {
                "type":"local"
            }
        ],
        "strategy": "${STRATEGY}"
    }
}
EOF

  # 内建的 NTP 客户端服务配置文件，这对于无法进行时间同步的环境很有用
  cat > ${WORK_DIR}/conf/06_ntp.json << EOF
{
    "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
    }
}
EOF

  # 专门给 sing-box 内部组件发 HTTP 请求用，比如这些场景会用到它：下载远程 rule_set：.srs 规则文件，ACME 申请证书，Cloudflare Origin CA 证书提供器，DERP / Tailscale 相关 HTTP 请求
  cat > ${WORK_DIR}/conf/07_http_clients.json << EOF
{
    "http_clients": [
        {
            "tag": "http-client-direct"
        }
    ]
}
EOF

  # 生成 XTLS + Reality 配置
  [ "${XTLS_REALITY}" = 'true' ] && ((PORT++)) && PORT_XTLS_REALITY=$PORT && cat > ${WORK_DIR}/conf/11_xtls-reality_inbounds.json << EOF
//  "public_key":"${REALITY_PUBLIC}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME} xtls-reality",
            "listen":"::",
            "listen_port":${PORT_XTLS_REALITY},
            "users":[
                {
                    "uuid":"${UUID}",
                    "flow":"xtls-rprx-vision"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"addons.mozilla.org",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"addons.mozilla.org",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "multiplex":{
                "enabled":false,
                "padding":false,
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

  # 生成 Hysteria2 配置
  [ "${HYSTERIA2}" = 'true' ] && ((PORT++)) && PORT_HYSTERIA2=$PORT && cat > ${WORK_DIR}/conf/12_hysteria2_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"hysteria2",
            "tag":"${NODE_NAME} hysteria2",
            "listen":"::",
            "listen_port":${PORT_HYSTERIA2},
            "users":[
                {
                    "password":"${UUID}"
                }
            ],
            "ignore_client_bandwidth":false,
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

  # 生成 Tuic V5 配置
  [ "${TUIC}" = 'true' ] && ((PORT++)) && PORT_TUIC=$PORT && cat > ${WORK_DIR}/conf/13_tuic_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"tuic",
            "tag":"${NODE_NAME} tuic",
            "listen":"::",
            "listen_port":${PORT_TUIC},
            "users":[
                {
                    "uuid":"${UUID}",
                    "password":"${UUID}"
                }
            ],
            "congestion_control": "bbr",
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

  # 生成 ShadowTLS V5 配置
  [ "${SHADOWTLS}" = 'true' ] && ((PORT++)) && PORT_SHADOWTLS=$PORT && cat > ${WORK_DIR}/conf/14_ShadowTLS_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"shadowtls",
            "tag":"${NODE_NAME} ShadowTLS",
            "listen":"::",
            "listen_port":${PORT_SHADOWTLS},
            "detour":"shadowtls-in",
            "version":3,
            "users":[
                {
                    "password":"${UUID}"
                }
            ],
            "handshake":{
                "server":"addons.mozilla.org",
                "server_port":443
            },
            "strict_mode":true
        },
        {
            "type":"shadowsocks",
            "tag":"shadowtls-in",
            "listen":"127.0.0.1",
            "network":"tcp",
            "method":"${SIP022_METHOD}",
            "password":"${SIP022_PASSWORD}",
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

  # 生成 Shadowsocks 配置
  [ "${SHADOWSOCKS}" = 'true' ] && ((PORT++)) && PORT_SHADOWSOCKS=$PORT && cat > ${WORK_DIR}/conf/15_shadowsocks_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"shadowsocks",
            "tag":"${NODE_NAME} shadowsocks",
            "listen":"::",
            "listen_port":${PORT_SHADOWSOCKS},
            "method":"${SIP022_METHOD}",
            "password":"${SIP022_PASSWORD}",
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

  # 生成 Trojan 配置
  [ "${TROJAN}" = 'true' ] && ((PORT++)) && PORT_TROJAN=$PORT && cat > ${WORK_DIR}/conf/16_trojan_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"trojan",
            "tag":"${NODE_NAME} trojan",
            "listen":"::",
            "listen_port":${PORT_TROJAN},
            "users":[
                {
                    "password":"${UUID}"
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

  # 生成 vmess + ws 配置
  [ "${VMESS_WS}" = 'true' ] && ((PORT++)) && PORT_VMESS_WS=$PORT && cat > ${WORK_DIR}/conf/17_vmess-ws_inbounds.json << EOF
//  "CDN": "${CDN}"
{
    "inbounds":[
        {
            "type":"vmess",
            "tag":"${NODE_NAME} vmess-ws",
            "listen":"127.0.0.1",
            "listen_port":${PORT_VMESS_WS},
            "tcp_fast_open":false,
            "proxy_protocol":false,
            "users":[
                {
                    "uuid":"${UUID}",
                    "alterId":0
                }
            ],
            "transport":{
                "type":"ws",
                "path":"/${UUID}-vmess",
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

  # 生成 vless + ws + tls 配置
  [ "${VLESS_WS}" = 'true' ] && ((PORT++)) && PORT_VLESS_WS=$PORT && cat > ${WORK_DIR}/conf/18_vless-ws-tls_inbounds.json << EOF
//  "CDN": "${CDN}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME} vless-ws-tls",
            "listen":"127.0.0.1",
            "listen_port":${PORT_VLESS_WS},
            "tcp_fast_open":false,
            "proxy_protocol":false,
            "users":[
                {
                    "name":"sing-box",
                    "uuid":"${UUID}"
                }
            ],
            "transport":{
                "type":"ws",
                "path":"/${UUID}-vless",
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

  # 生成 H2 + Reality 配置
  [ "${H2_REALITY}" = 'true' ] && ((PORT++)) && PORT_H2_REALITY=$PORT && cat > ${WORK_DIR}/conf/19_h2-reality_inbounds.json << EOF
//  "public_key":"${REALITY_PUBLIC}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME} h2-reality",
            "listen":"::",
            "listen_port":${PORT_H2_REALITY},
            "users":[
                {
                    "uuid":"${UUID}"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"addons.mozilla.org",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"addons.mozilla.org",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "transport": {
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

  # 生成 gRPC + Reality 配置
  [ "${GRPC_REALITY}" = 'true' ] && ((PORT++)) && PORT_GRPC_REALITY=$PORT && cat > ${WORK_DIR}/conf/20_grpc-reality_inbounds.json << EOF
//  "public_key":"${REALITY_PUBLIC}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME} grpc-reality",
            "listen":"::",
            "listen_port":${PORT_GRPC_REALITY},
            "users":[
                {
                    "uuid":"${UUID}"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"addons.mozilla.org",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"addons.mozilla.org",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "transport": {
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

  # 生成 AnyTLS 配置
  [ "${ANYTLS}" = 'true' ] && ((PORT++)) && PORT_ANYTLS=$PORT && cat > ${WORK_DIR}/conf/21_anytls_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"anytls",
            "tag":"${NODE_NAME} anytls",
            "listen":"::",
            "listen_port":$PORT_ANYTLS,
            "users":[
                {
                    "password":"${UUID}"
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

  # 判断 argo 隧道类型
  if [[ -n "$ARGO_DOMAIN" && -n "$ARGO_AUTH" ]]; then
    # 根据 ARGO_AUTH 的内容，自行判断是 Json， Token 还是 API 申请
    if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
      # JSON 类型
      local ARGO_JSON=${ARGO_AUTH//[ ]/}
    elif [[ "${ARGO_AUTH}" =~ [A-Z0-9a-z=]{150,250}$ ]]; then
      # Token 类型
      local ARGO_TOKEN=$(awk '{print $NF}' <<< "$ARGO_AUTH")
    elif [[ "${#ARGO_AUTH}" == 40 ]]; then
      # API 类型 (Cloudflare API Token)
      echo -e "\n使用 Cloudflare API 创建隧道..."

      # 获取隧道名和根域名
      local TUNNEL_NAME=${ARGO_DOMAIN%%.*}
      local ROOT_DOMAIN=${ARGO_DOMAIN#*.}

      # 获取 Zone ID 和 Account ID
      local ZONE_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
        --header="Authorization: Bearer ${ARGO_AUTH}" \
        --header="Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}")

      local ZONE_ID=$(sed 's/.*"result":[ ]*[{"id:[ ]*"\([^"]*\)",.*/\1/' <<< $ZONE_RESPONSE)
      local ACCOUNT_ID=$(sed 's/.*account":[ ]*{"id":"\([^"]*\)",.*/\1/' <<< $ZONE_RESPONSE)

      # 查询并处理现有 Tunnel
      local TUNNEL_LIST=$(wget --no-check-certificate -qO- --content-on-error \
        --header="Authorization: Bearer ${ARGO_AUTH}" \
        --header="Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel?is_deleted=false" \
        | awk 'BEGIN{RS="";FS=""}{s=substr($0,index($0,"\"result\":[")+10);d=0;b="";for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c=="{")d++;if(d>0)b=b c;if(c=="}"){d--;if(d==0){print b;b=""}}}}')

      if [[ "$TUNNEL_LIST" =~ \"id\":\"([^\"]+).*\"name\":\"$TUNNEL_NAME\" ]]; then
        # 有同名 Tunnel，则获取其 ID 和 TOKEN
        local EXISTING_TUNNEL_ID="${BASH_REMATCH[1]}"
        local EXISTING_TUNNEL_TOKEN=$(wget -qO- --content-on-error \
          --header="Authorization: Bearer ${ARGO_AUTH}" \
          --header="Content-Type: application/json" \
          "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${EXISTING_TUNNEL_ID}/token")

        local TUNNEL_ID=$EXISTING_TUNNEL_ID
        local ARGO_TOKEN=$(sed -n 's/.*"result":"\([^"]\+\)".*/\1/p' <<< "$EXISTING_TUNNEL_TOKEN")
      else
        # 生成 Tunnel Secret (至少 32 字节的 base64 编码)
        local TUNNEL_SECRET=$(openssl rand -base64 32)

        # 创建新 Tunnel
        local CREATE_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
          --header="Authorization: Bearer ${ARGO_AUTH}" \
          --header="Content-Type: application/json" \
          --post-data="{
            \"name\": \"$TUNNEL_NAME\",
            \"config_src\": \"cloudflare\",
            \"tunnel_secret\": \"$TUNNEL_SECRET\"
          }" \
          "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel")

        local TUNNEL_ID=$(sed -n 's/.*"id":"\([^"]\+\)".*/\1/p' <<< "$CREATE_RESPONSE")
        local ARGO_TOKEN=$(sed -n 's/.*"token":"\([^"]\+\)".*/\1/p' <<< "$CREATE_RESPONSE")
      fi

      # 配置隧道ingress规则
      local CONFIG_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
        --method=PUT \
        --header="Authorization: Bearer ${ARGO_AUTH}" \
        --header="Content-Type: application/json" \
        --body-data="{
          \"config\": {
            \"ingress\": [
              {
                \"service\": \"http://localhost:${START_PORT}\",
                \"hostname\": \"${ARGO_DOMAIN}\"
              },
              {
                \"service\": \"http_status:404\"
              }
            ],
            \"warp-routing\": {
              \"enabled\": false
            }
          }
        }" \
        "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations")

      # 管理DNS记录
      local DNS_PAYLOAD="{
        \"name\": \"${ARGO_DOMAIN}\",
        \"type\": \"CNAME\",
        \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
        \"proxied\": true,
        \"settings\": {
          \"flatten_cname\": false
        }
      }"

      local DNS_LIST=$(wget --no-check-certificate -qO- --content-on-error \
        --header="Authorization: Bearer ${ARGO_AUTH}" \
        --header="Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME&name=${ARGO_DOMAIN}")

      # 如果已存在需要的 DNS 记录，就跳过
      if [[ "$DNS_LIST" =~ \"id\":\"([^\"]+)\".*\"$ARGO_DOMAIN\".*\"content\":\"([^\"]+)\" ]]; then
        local EXISTING_DNS_ID="${BASH_REMATCH[1]}" EXISTED_DNS_CONTENT="${BASH_REMATCH[2]}"

        # DNS 记录与隧道 ID 不匹配的话，覆盖原来的 CNAME 记录
        if ! grep -qw "$EXISTING_TUNNEL_ID" <<< "${EXISTED_DNS_CONTENT%%.*}"; then
          local DNS_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
            --method=PATCH \
            --header="Authorization: Bearer ${ARGO_AUTH}" \
            --header="Content-Type: application/json" \
            --body-data="$DNS_PAYLOAD" \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXISTING_DNS_ID}")
        fi
      else
        # 未找到现有 DNS 记录，使用 POST 创建
        local DNS_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
          --method=POST \
          --header="Authorization: Bearer ${ARGO_AUTH}" \
          --header="Content-Type: application/json" \
          --body-data="$DNS_PAYLOAD" \
          "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records")
      fi

      # 构造ARGO_JSON
      local ARGO_JSON="{\"AccountTag\":\"$ACCOUNT_ID\",\"TunnelSecret\":\"$TUNNEL_SECRET\",\"TunnelID\":\"$TUNNEL_ID\",\"Endpoint\":\"\"}"
    fi

    # 根据ARGO_JSON或ARGO_TOKEN设置ARGO_RUNS
    if [[ -n "$ARGO_JSON" ]]; then
      local ARGO_RUNS="cloudflared tunnel --edge-ip-version auto --config ${WORK_DIR}/tunnel.yml run"
      echo $ARGO_JSON > ${WORK_DIR}/tunnel.json
      cat > ${WORK_DIR}/tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< $ARGO_JSON)
credentials-file: ${WORK_DIR}/tunnel.json

ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://localhost:${START_PORT}
  - service: http_status:404
EOF
    elif [[ -n "$ARGO_TOKEN" ]]; then
      local ARGO_RUNS="cloudflared tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}"
    fi
  else
    ((PORT++))
    METRICS_PORT=$PORT
    local ARGO_RUNS="cloudflared tunnel --edge-ip-version auto --no-autoupdate --no-tls-verify --metrics 0.0.0.0:$METRICS_PORT --url http://localhost:$START_PORT"
  fi
