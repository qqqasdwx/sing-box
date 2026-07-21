# shellcheck shell=bash

subscription_json_quote() {
  local _jq=$1 _value=$2
  "$_jq" -Rn --arg value "$_value" '$value'
}

write_clash_provider_config() {
  local _output=$1 _node_name=$2 _provider_url=$3 _jq=$4
  local _node_name_json _provider_url_json _rule_json
  _node_name_json=$(subscription_json_quote "$_jq" "$_node_name") || return 1
  _provider_url_json=$(subscription_json_quote "$_jq" "$_provider_url") || return 1
  _rule_json=$(subscription_json_quote "$_jq" "MATCH,${_node_name}") || return 1

  cat > "$_output" << EOF
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: true
external-controller: 127.0.0.1:9090
proxy-providers:
  nodes:
    type: http
    url: ${_provider_url_json}
    path: ./proxy-providers/sing-box.yaml
    interval: 3600
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
proxy-groups:
  - name: ${_node_name_json}
    type: select
    proxies:
      - AUTO
      - NODES
      - DIRECT
  - name: AUTO
    type: url-test
    use:
      - nodes
    url: https://www.gstatic.com/generate_204
    interval: 300
  - name: NODES
    type: select
    use:
      - nodes
rules:
  - ${_rule_json}
EOF
}

write_clash_inline_config() {
  local _output=$1 _proxies=$2 _jq=$3
  shift 3
  local _name _name_json
  local _selector_entries='' _urltest_entries=''

  for _name in "$@"; do
    _name_json=$(subscription_json_quote "$_jq" "$_name") || return 1
    _selector_entries+="      - ${_name_json}"$'\n'
    _urltest_entries+="      - ${_name_json}"$'\n'
  done

  if [ -z "$_selector_entries" ]; then
    _proxies='proxies: []'
  fi

  {
    printf '%s\n' "$_proxies"
    cat << EOF
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: true
external-controller: 127.0.0.1:9090
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - AUTO
${_selector_entries}      - DIRECT
EOF
    if [ -n "$_urltest_entries" ]; then
      cat << EOF
  - name: AUTO
    type: url-test
    proxies:
${_urltest_entries}    url: https://www.gstatic.com/generate_204
    interval: 300
EOF
    else
      cat << 'EOF'
  - name: AUTO
    type: select
    proxies:
      - DIRECT
EOF
    fi
    cat << 'EOF'
rules:
  - MATCH,PROXY
EOF
  } > "$_output"
}

write_sing_box_client_config() {
  local _output=$1 _outbounds=$2 _nodes=$3 _jq=$4
  local _tmp
  _tmp=$(mktemp "${_output}.tmp.XXXXXX") || return 1

  cat > "$_tmp" << EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-local"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    ${_outbounds}
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": [
        ${_nodes}"auto",
        "direct"
      ],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": [
        ${_nodes%,}
      ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "10m"
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      }
    ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
EOF

  if "$_jq" . "$_tmp" > "$_output"; then
    rm -f "$_tmp"
    return 0
  fi
  rm -f "$_tmp" "$_output"
  return 1
}
