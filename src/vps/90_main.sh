for ((_param_i=1; _param_i<=$#; _param_i++)); do
  eval "_param_v=\${${_param_i}}"
  case "${_param_v^^}" in
    --LANGUAGE )
      _param_n=$((_param_i+1))
      eval "_param_lang=\${${_param_n}}"
      [[ "${_param_lang^^}" =~ ^C ]] && L=C || L=E
      ;;
    --LANGUAGE=* )
      _param_lang="${_param_v#*=}"
      [[ "${_param_lang^^}" =~ ^C ]] && L=C || L=E
      ;;
  esac
done
unset _param_i _param_v _param_n _param_lang

# 获取 -F 参数的值
CONFIG_FILE=$(awk '-F[ =]' 'tolower($1) ~ /^-f$/{print $2}' <<< "$*")
if [[ -n "$CONFIG_FILE" && -s "$CONFIG_FILE" ]]; then
  apply_config_file_options
fi

check_root
select_language
check_system_info
check_brutal

# 可以是 Key Value 或者 Key=Value 的形式。传参时，
# 传参处理1: 把所有的 = 变为空格，但保留 =" ，因为 Json TunnelSecret 是 =" 结尾的，如 {"AccountTag":"9cc9e3e4d8f29d2a02e297f14f20513a","TunnelSecret":"6AYfKBOoNlPiTAuWg64ZwujsNuERpWLm6pPJ2qpN8PM=","TunnelID":"1ac55430-f4dc-47d5-a850-bdce824c4101"}
# 传参处理2: 去掉 sudo cloudflared service install ，以方便用户输入 Token 并能正确读取真正的以 ey 开头的 Value
ALL_PARAMETER=($(sed -E 's/(-c|-e|-f|-C|-E|-F) //; s/=([^"])/ \1/g; s/sudo cloudflared service install //' <<< $*))
# KV 参数安装：只要指定 --CHOOSE_PROTOCOLS，就认为用户要无交互安装。
# 其余参数允许缺省，脚本会按交互模式默认值自动补齐。
parameter_present --CHOOSE_PROTOCOLS "${ALL_PARAMETER[@]}" && NONINTERACTIVE_INSTALL=noninteractive_install
for _protocol_switch in \
  --XTLS_REALITY --HYSTERIA2 --TUIC --SHADOWTLS --SHADOWSOCKS --TROJAN \
  --VMESS_WS --VLESS_WS --H2_REALITY --GRPC_REALITY --ANYTLS --NAIVE; do
  if parameter_present "$_protocol_switch" "${ALL_PARAMETER[@]}"; then
    NONINTERACTIVE_INSTALL=noninteractive_install
    break
  fi
done
unset _protocol_switch

# 传参处理，无交互快速安装参数
for z in "${!ALL_PARAMETER[@]}"; do
  case "${ALL_PARAMETER[z]^^}" in
    -K|-L )
      ((z++))
      IS_FAST_INSTALL=is_fast_install
      ;;
    -S )
      check_install
      if [ "${STATUS[0]}" = "$(text 26)" ]; then
        error "\n Sing-box $(text 26) "
      elif [ "${STATUS[0]}" = "$(text 28)" ]; then
        disable_service_or_fail Sing-box sing-box
      elif [ "${STATUS[0]}" = "$(text 27)" ]; then
        enable_service_or_fail Sing-box sing-box
      fi
      exit 0
      ;;
    -A )
      check_install
      if [ "${STATUS[1]}" = "$(text 26)" ]; then
        error "\n Argo $(text 26) "
      elif [ "${STATUS[1]}" = "$(text 28)" ]; then
        disable_service_or_fail Argo argo
      elif [ "${STATUS[1]}" = "$(text 27)" ]; then
        enable_service_or_fail Argo argo
        grep -Fqs -- '--url' "$ARGO_DAEMON_FILE" && fetch_quicktunnel_domain && export_list
      fi
      exit 0
      ;;
    -T )
      change_argo; exit 0
      ;;
    -D )
      check_install
      [ "${STATUS[0]}" = "$(text 26)" ] && error "\n Sing-box $(text 26) "
      protocol_config_menu
      exit 0
      ;;
    -U )
      check_install; uninstall; exit 0
      ;;
    -N )
      [ ! -s ${WORK_DIR}/list ] && error " Sing-box $(text 26) "; export_list; exit 0
      ;;
    -V )
      check_system_info; check_arch; version; exit 0
      ;;
    -B )
      bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh); exit
      ;;
    -R )
      change_protocols; exit 0
      ;;
    --LANGUAGE )
      ((z++)); [[ "${ALL_PARAMETER[z]^^}" =~ ^C ]] && LANGUAGE=C || LANGUAGE=E
      ;;
    --CHOOSE_PROTOCOLS )
      ((z++)); CHOOSE_PROTOCOLS=${ALL_PARAMETER[z]}
      ;;
    --XTLS_REALITY )
      ((z++)); XTLS_REALITY=${ALL_PARAMETER[z]}
      ;;
    --HYSTERIA2 )
      ((z++)); HYSTERIA2=${ALL_PARAMETER[z]}
      ;;
    --TUIC )
      ((z++)); TUIC=${ALL_PARAMETER[z]}
      ;;
    --SHADOWTLS )
      ((z++)); SHADOWTLS=${ALL_PARAMETER[z]}
      ;;
    --SHADOWSOCKS )
      ((z++)); SHADOWSOCKS=${ALL_PARAMETER[z]}
      ;;
    --TROJAN )
      ((z++)); TROJAN=${ALL_PARAMETER[z]}
      ;;
    --VMESS_WS )
      ((z++)); VMESS_WS=${ALL_PARAMETER[z]}
      ;;
    --VLESS_WS )
      ((z++)); VLESS_WS=${ALL_PARAMETER[z]}
      ;;
    --H2_REALITY )
      ((z++)); H2_REALITY=${ALL_PARAMETER[z]}
      ;;
    --GRPC_REALITY )
      ((z++)); GRPC_REALITY=${ALL_PARAMETER[z]}
      ;;
    --ANYTLS )
      ((z++)); ANYTLS=${ALL_PARAMETER[z]}
      ;;
    --NAIVE )
      ((z++)); NAIVE=${ALL_PARAMETER[z]}
      ;;
    --START_PORT )
      ((z++)); START_PORT=${ALL_PARAMETER[z]}
      ;;
    --LOG_LEVEL )
      ((z++)); LOG_LEVEL=${ALL_PARAMETER[z]}
      ;;
    --NTP_ENABLED )
      ((z++)); NTP_ENABLED=${ALL_PARAMETER[z]}
      ;;
    --NTP_SERVER )
      ((z++)); NTP_SERVER=${ALL_PARAMETER[z]}
      ;;
    --NTP_SERVER_PORT )
      ((z++)); NTP_SERVER_PORT=${ALL_PARAMETER[z]}
      ;;
    --NTP_INTERVAL )
      ((z++)); NTP_INTERVAL=${ALL_PARAMETER[z]}
      ;;
    --FINGER_PRINT )
      ((z++)); FINGER_PRINT=${ALL_PARAMETER[z]}; FINGER_PRINT_EXPLICIT=1
      ;;
    --PORT_NGINX )
      ((z++)); PORT_NGINX=${ALL_PARAMETER[z]}
      ;;
    --PORT_XTLS_REALITY )
      ((z++)); PORT_XTLS_REALITY=${ALL_PARAMETER[z]}
      ;;
    --PORT_HYSTERIA2 )
      ((z++)); PORT_HYSTERIA2=${ALL_PARAMETER[z]}
      ;;
    --PORT_TUIC )
      ((z++)); PORT_TUIC=${ALL_PARAMETER[z]}
      ;;
    --PORT_SHADOWTLS )
      ((z++)); PORT_SHADOWTLS=${ALL_PARAMETER[z]}
      ;;
    --PORT_SHADOWSOCKS )
      ((z++)); PORT_SHADOWSOCKS=${ALL_PARAMETER[z]}
      ;;
    --PORT_TROJAN )
      ((z++)); PORT_TROJAN=${ALL_PARAMETER[z]}
      ;;
    --PORT_VMESS_WS )
      ((z++)); PORT_VMESS_WS=${ALL_PARAMETER[z]}
      ;;
    --PORT_VLESS_WS )
      ((z++)); PORT_VLESS_WS=${ALL_PARAMETER[z]}
      ;;
    --PORT_H2_REALITY )
      ((z++)); PORT_H2_REALITY=${ALL_PARAMETER[z]}
      ;;
    --PORT_GRPC_REALITY )
      ((z++)); PORT_GRPC_REALITY=${ALL_PARAMETER[z]}
      ;;
    --PORT_ANYTLS )
      ((z++)); PORT_ANYTLS=${ALL_PARAMETER[z]}
      ;;
    --PORT_NAIVE )
      ((z++)); PORT_NAIVE=${ALL_PARAMETER[z]}
      ;;
    --SERVER_IP )
      ((z++)); SERVER_IP=${ALL_PARAMETER[z]}
      ;;
    --VMESS_HOST_DOMAIN )
      ((z++)); VMESS_HOST_DOMAIN=${ALL_PARAMETER[z]}
      ;;
    --VLESS_HOST_DOMAIN )
      ((z++)); VLESS_HOST_DOMAIN=${ALL_PARAMETER[z]}
      ;;
    --CDN )
      ((z++)); CDN=${ALL_PARAMETER[z]}
      ;;
    --UUID_CONFIRM )
      ((z++)); UUID_CONFIRM=${ALL_PARAMETER[z]}
      ;;
    --NODE_NAME_CONFIRM )
      NODE_NAME_CONFIRM=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_XTLS_REALITY )
      NODE_NAME_XTLS_REALITY=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_HYSTERIA2 )
      NODE_NAME_HYSTERIA2=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_TUIC )
      NODE_NAME_TUIC=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_SHADOWTLS )
      NODE_NAME_SHADOWTLS=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_SHADOWSOCKS )
      NODE_NAME_SHADOWSOCKS=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_TROJAN )
      NODE_NAME_TROJAN=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_VMESS_WS )
      NODE_NAME_VMESS_WS=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_VLESS_WS )
      NODE_NAME_VLESS_WS=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_H2_REALITY )
      NODE_NAME_H2_REALITY=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_GRPC_REALITY )
      NODE_NAME_GRPC_REALITY=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_ANYTLS )
      NODE_NAME_ANYTLS=$(parameter_value_from $((z+1)))
      ;;
    --NODE_NAME_NAIVE )
      NODE_NAME_NAIVE=$(parameter_value_from $((z+1)))
      ;;
    --SUBSCRIBE )
      ((z++)); [ "${ALL_PARAMETER[z]}" = 'true' ] && IS_SUB=is_sub
      ;;
    --ARGO )
      ((z++)); [ "${ALL_PARAMETER[z]}" = 'true' ] && IS_ARGO=is_argo
      ;;
    --ARGO_DOMAIN )
      ((z++)); ARGO_DOMAIN=${ALL_PARAMETER[z]}
      ;;
    --ARGO_AUTH )
      ((z++)); ARGO_AUTH=${ALL_PARAMETER[z]}
      ;;
    --HY2_PORT_HOPPING_RANGE )
      ((z++)); [[ "${ALL_PARAMETER[z]//:/-}" =~ ^[1-6][0-9]{4}-[1-6][0-9]{4}$ ]] && HY2_PORT_HOPPING_RANGE=${ALL_PARAMETER[z]//-/:} && PORT_HOPPING_START=${ALL_PARAMETER[z]%:*} && PORT_HOPPING_END=${ALL_PARAMETER[z]#*:}
      [[ "$PORT_HOPPING_START" < "$PORT_HOPPING_END" && "$PORT_HOPPING_START" -ge "$MIN_HOPPING_PORT" && "$PORT_HOPPING_END" -le "$MAX_HOPPING_PORT" ]] && IS_HOPPING=is_hopping
      ;;
    --HY2_REALM|--REALM )
      ((z++)); [[ "${ALL_PARAMETER[z],,}" =~ ^(true|1|y|yes)$ ]] && IS_HY2_REALM=is_hy2_realm
      ;;
    --HY2_WARP|--REALM_WARP|--WARP_REALM )
      ((z++)); [[ "${ALL_PARAMETER[z],,}" =~ ^(true|1|y|yes)$ ]] && IS_HY2_WARP=is_hy2_warp && IS_HY2_REALM=is_hy2_realm
      ;;
    --REALITY_PRIVATE )
      ((z++)); REALITY_PRIVATE=${ALL_PARAMETER[z]}
      ;;
  esac
done

apply_custom_node_names
normalize_log_level
normalize_ntp_config
normalize_finger_print
normalize_ws_domain_mode

check_arch
check_dependencies
check_system_ip
check_install
if [ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]; then
  if [ "${STATUS[0]}" != "$(text 26)" ]; then
    install_from_config_update
  else
    # 预设默认值，允许只传 --CHOOSE_PROTOCOLS 进行最小无交互安装。
    resolve_protocol_switch_mode
    CHOOSE_PROTOCOLS=${CHOOSE_PROTOCOLS:-'a'}
    START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
    CDN=${CDN:-"${CDN_DOMAIN[0]}"}
    IS_SUB=${IS_SUB:-'no_sub'}
    IS_ARGO=${IS_ARGO:-'no_argo'}
    IS_HOPPING=${IS_HOPPING:-'no_hopping'}
    normalize_ws_domain_mode

    install_sing-box
  fi
  export_list install
  write_config_state_file
  create_shortcut
elif [ "$IS_FAST_INSTALL" = 'is_fast_install' ]; then
  if [ "${STATUS[0]}" != "$(text 26)" ]; then
    info "\n $(text 77) \n"
    create_shortcut
    exit 0
  fi

  # 预设默认值
  resolve_protocol_switch_mode
  CHOOSE_PROTOCOLS=${CHOOSE_PROTOCOLS:-'a'}
  START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
  CDN=${CDN:-"${CDN_DOMAIN[0]}"}
  IS_SUB='is_sub'
  IS_ARGO='is_argo'
  [[ "$HY2_PORT_HOPPING_RANGE" =~ ^[0-9]+:[0-9]+$ ]] && IS_HOPPING='is_hopping' || IS_HOPPING='no_hopping'

  install_sing-box
  export_list install
  create_shortcut
else
  menu_setting
  menu
fi
