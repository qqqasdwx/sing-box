# 自定义字体彩色，read 函数
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }  # 红色
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色
reading() { read -rp "$(info "$1")" "$2"; }

# 预处理：扫描 E/C 数组，把含 $ 的条目下标记录到关联数组，避免 text() 每次调用都启动 grep 子进程
declare -A TEXT_NEEDS_EVAL
for _text_i in "${!E[@]}"; do
  [[ "${E[${_text_i}]}" == *'$'* || "${C[${_text_i}]}" == *'$'* ]] && TEXT_NEEDS_EVAL[${_text_i}]=1
done
unset _text_i

# text <index>：输出当前语言对应的字符串，含 $ 变量的条目用 eval 展开，其余直接 printf
text() {
  local -n _text_arr="${L}"        # nameref 指向 E 或 C，零子进程
  local _text_val="${_text_arr[$*]}"
  if [[ -n "${TEXT_NEEDS_EVAL[$*]}" ]]; then
    eval "printf '%s' \"${_text_val}\""
  else
    printf '%s' "${_text_val}"
  fi
}

failure_reason_title() {
  [ "$L" = 'C' ] && printf '失败原因:' || printf 'Failure reason:'
}

service_detail_title() {
  if [ "$L" = 'C' ]; then
    case "$1" in
      command ) printf '命令输出' ;;
      status ) printf '服务状态' ;;
      journal ) printf '最近日志' ;;
      runtime ) printf '运行日志' ;;
      check ) printf '配置检查' ;;
      * ) printf '%s' "$1" ;;
    esac
  else
    case "$1" in
      command ) printf 'Command output' ;;
      status ) printf 'Service status' ;;
      journal ) printf 'Recent logs' ;;
      runtime ) printf 'Runtime log' ;;
      check ) printf 'Config check' ;;
      * ) printf '%s' "$1" ;;
    esac
  fi
}

service_action_text() {
  case "$1" in
    enable|start|open ) text 28 ;;
    disable|stop|close ) text 27 ;;
    restart ) [ "$L" = 'C' ] && printf '重启' || printf 'restart' ;;
    reload ) [ "$L" = 'C' ] && printf '重载' || printf 'reload' ;;
    update ) [ "$L" = 'C' ] && printf '更新' || printf 'update' ;;
    * ) printf '%s' "$1" ;;
  esac
}

service_command_log_file() {
  local _service=$1 _action=${2:-command}
  _service=${_service//[^[:alnum:]_.-]/_}
  _action=${_action//[^[:alnum:]_.-]/_}
  mkdir -p "$TEMP_DIR" 2>/dev/null || true
  printf '%s/service_%s_%s.log' "$TEMP_DIR" "$_service" "$_action"
}

redact_failure_detail() {
  sed -E \
    -e 's/--token[= ]+[^[:space:]]+/--token [REDACTED]/g' \
    -e 's/("TunnelSecret"[[:space:]]*:[[:space:]]*")[^"]+/\1[REDACTED]/g' \
    -e 's/(TunnelSecret[= ][[:space:]]*)[^,}[:space:]]+/\1[REDACTED]/g'
}

service_failure_detail() {
  local _service=$1 _action=${2:-status} _detail='' _log_file _runtime_log=''
  local _status_output _journal_output _runtime_output _check_output

  _log_file=$(service_command_log_file "$_service" "$_action")
  if [ -s "$_log_file" ]; then
    _detail+="$(service_detail_title command)"$'\n'
    _detail+="$(tail -n 25 "$_log_file")"$'\n'
  fi

  if [ "$SYSTEM" = 'Alpine' ]; then
    if command -v rc-service >/dev/null 2>&1; then
      _status_output=$(rc-service "$_service" status 2>&1 | tail -n 25)
      if [ -n "$_status_output" ]; then
        _detail+="$(service_detail_title status)"$'\n'
        _detail+="${_status_output}"$'\n'
      fi
    fi
  else
    if command -v systemctl >/dev/null 2>&1; then
      _status_output=$(systemctl status "$_service" --no-pager -l 2>&1 | tail -n 30)
      if [ -n "$_status_output" ]; then
        _detail+="$(service_detail_title status)"$'\n'
        _detail+="${_status_output}"$'\n'
      fi
    fi
    if command -v journalctl >/dev/null 2>&1; then
      _journal_output=$(journalctl -u "$_service" -n 30 --no-pager 2>&1 | tail -n 30)
      if [ -n "$_journal_output" ]; then
        _detail+="$(service_detail_title journal)"$'\n'
        _detail+="${_journal_output}"$'\n'
      fi
    fi
  fi

  case "$_service" in
    sing-box|argo )
      _runtime_log="${WORK_DIR}/logs/${_service}.log"
      ;;
    nginx )
      if command -v nginx >/dev/null 2>&1 && [ -s "${WORK_DIR}/nginx.conf" ]; then
        _check_output=$(nginx -t -c "${WORK_DIR}/nginx.conf" 2>&1 | tail -n 25)
        if [ -n "$_check_output" ]; then
          _detail+="$(service_detail_title check)"$'\n'
          _detail+="${_check_output}"$'\n'
        fi
      fi
      ;;
  esac

  if [ -n "$_runtime_log" ] && [ -s "$_runtime_log" ]; then
    _runtime_output=$(tail -n 30 "$_runtime_log")
    if [ -n "$_runtime_output" ]; then
      _detail+="$(service_detail_title runtime) (${_runtime_log})"$'\n'
      _detail+="${_runtime_output}"$'\n'
    fi
  fi

  printf '%s' "$_detail" | redact_failure_detail | sed '/^[[:space:]]*$/d' | tail -n 100
}

service_failure_message() {
  local _message=$1 _service=$2 _action=${3:-status} _detail
  _detail=$(service_failure_detail "$_service" "$_action")
  if [ -z "$_detail" ]; then
    if [ "$L" = 'C' ]; then
      if [ "$SYSTEM" = 'Alpine' ]; then
        _detail="未获取到服务错误输出，请手动运行: rc-service ${_service} status"
      else
        _detail="未获取到服务错误输出，请手动运行: systemctl status ${_service} --no-pager -l"
      fi
    else
      if [ "$SYSTEM" = 'Alpine' ]; then
        _detail="No service error output was available. Run: rc-service ${_service} status"
      else
        _detail="No service error output was available. Run: systemctl status ${_service} --no-pager -l"
      fi
    fi
  fi
  printf '\n%s\n\n%s\n%s\n' "$_message" "$(failure_reason_title)" "$_detail"
}

service_failure_error() {
  error "$(service_failure_message "$@")"
}

service_failure_warning() {
  warning "$(service_failure_message "$@")"
}

failure_error() {
  local _message=$1
  shift || true
  local _detail="$*"
  if [ -z "$_detail" ]; then
    [ "$L" = 'C' ] && _detail='未获取到命令输出。' || _detail='No command output was available.'
  fi
  error "$(printf '\n%s\n\n%s\n%s\n' "$_message" "$(failure_reason_title)" "$_detail")"
}

verify_command_or_fail() {
  local _message=$1 _detail=$2 _binary _output
  shift 2
  _binary=$1
  shift
  _output=$("$@" 2>&1) && return 0
  failure_error "$_message" "${_detail}${_detail:+
}Command: $*
Output:
${_output:-No output}
File: ${_binary}
Size: $([ -e "$_binary" ] && wc -c < "$_binary" 2>/dev/null || printf 0) bytes"
}

verify_file_or_fail() {
  local _file=$1 _message=$2 _detail=${3:-}
  [ -s "$_file" ] && return 0
  local _output
  _output=$(ls -l "$_file" 2>&1 || true)
  failure_error "$_message" "${_detail}${_detail:+
}File: ${_file}
Expected: non-empty file
Output:
${_output:-No output}"
}

service_action_failed() {
  local _label=$1 _service=$2 _action=$3
  service_failure_error " ${_label} $(service_action_text "$_action") $(text 38) " "$_service" "$_action"
}

service_action_warn() {
  local _label=$1 _service=$2 _action=$3
  service_failure_warning " ${_label} $(service_action_text "$_action") $(text 38) " "$_service" "$_action"
}

enable_service_or_fail() {
  local _label=$1 _service=$2 _wait=${3:-2}
  cmd_systemctl enable "$_service" || service_action_failed "$_label" "$_service" enable
  sleep "$_wait"
  cmd_systemctl status "$_service" &>/dev/null &&
    info " ${_label} $(service_action_text enable) $(text 37)" ||
    service_action_failed "$_label" "$_service" enable
}

disable_service_or_fail() {
  local _label=$1 _service=$2
  cmd_systemctl disable "$_service" || service_action_failed "$_label" "$_service" disable
  cmd_systemctl status "$_service" &>/dev/null &&
    service_action_failed "$_label" "$_service" disable ||
    info " ${_label} $(service_action_text disable) $(text 37)"
}

restart_service_or_fail() {
  local _label=$1 _service=$2
  cmd_systemctl restart "$_service" || service_action_failed "$_label" "$_service" restart
  sleep 2
  cmd_systemctl status "$_service" &>/dev/null &&
    info " ${_label} $(service_action_text restart) $(text 37)" ||
    service_action_failed "$_label" "$_service" restart
}

restart_service_or_warn() {
  local _label=$1 _service=$2
  cmd_systemctl restart "$_service" || { service_action_warn "$_label" "$_service" restart; return 1; }
  sleep 2
  cmd_systemctl status "$_service" &>/dev/null &&
    info " ${_label} $(service_action_text restart) $(text 37)" ||
    { service_action_warn "$_label" "$_service" restart; return 1; }
}

reload_service_or_fail() {
  local _label=$1 _service=$2
  cmd_systemctl reload "$_service" || service_action_failed "$_label" "$_service" reload
  cmd_systemctl status "$_service" &>/dev/null &&
    info " ${_label} $(service_action_text reload) $(text 37)" ||
    service_action_failed "$_label" "$_service" reload
}

reload_service_or_warn() {
  local _label=$1 _service=$2
  cmd_systemctl reload "$_service" || { service_action_warn "$_label" "$_service" reload; return 1; }
  cmd_systemctl status "$_service" &>/dev/null &&
    info " ${_label} $(service_action_text reload) $(text 37)" ||
    { service_action_warn "$_label" "$_service" reload; return 1; }
}

# 根据 INSTALL_PROTOCOLS 计算安装流程总步骤数
# sing-box 协议分类：Reality 类 (b/j/k)、Hysteria2(c)、WS 类 (h/i)
calc_install_steps() {
  local _total=5  # 固定步骤：协议选择、起始端口、VPS IP、UUID、节点名
  local HAS_REALITY=false HAS_WS=false
  for _P in "${INSTALL_PROTOCOLS[@]}"; do
    [[ "$_P" =~ ^[bjk]$ ]] && HAS_REALITY=true
    [[ "$_P" =~ ^[hi]$ ]] && HAS_WS=true
  done
  [[ "$IS_SUB" = 'is_sub' || "$IS_ARGO" = 'is_argo' ]] && (( _total++ ))  # nginx 端口
  $HAS_REALITY && (( _total++ ))                # Reality 私钥
  $HAS_WS && (( _total++ ))                     # CDN / 域名
  # Hysteria2 Realm / Port Hopping are protocol sub-options and are not counted as install steps.
  [ "$IS_ARGO" = 'is_argo' ] && (( _total++ ))  # Argo 域名
  TOTAL_STEPS=$_total
}

parameter_value_from() {
  local _idx=$1 _pos
  local _values=()
  for ((_pos=_idx; _pos<${#ALL_PARAMETER[@]}; _pos++)); do
    [[ "${ALL_PARAMETER[_pos]}" =~ ^- ]] && break
    _values+=("${ALL_PARAMETER[_pos]}")
  done
  printf '%s' "${_values[*]}"
}

apply_custom_node_names() {
  [ -n "${NODE_NAME_XTLS_REALITY:-}" ] && NODE_NAME[11]=$NODE_NAME_XTLS_REALITY
  [ -n "${NODE_NAME_HYSTERIA2:-}" ] && NODE_NAME[12]=$NODE_NAME_HYSTERIA2
  [ -n "${NODE_NAME_TUIC:-}" ] && NODE_NAME[13]=$NODE_NAME_TUIC
  [ -n "${NODE_NAME_SHADOWTLS:-}" ] && NODE_NAME[14]=$NODE_NAME_SHADOWTLS
  [ -n "${NODE_NAME_SHADOWSOCKS:-}" ] && NODE_NAME[15]=$NODE_NAME_SHADOWSOCKS
  [ -n "${NODE_NAME_TROJAN:-}" ] && NODE_NAME[16]=$NODE_NAME_TROJAN
  [ -n "${NODE_NAME_VMESS_WS:-}" ] && NODE_NAME[17]=$NODE_NAME_VMESS_WS
  [ -n "${NODE_NAME_VLESS_WS:-}" ] && NODE_NAME[18]=$NODE_NAME_VLESS_WS
  [ -n "${NODE_NAME_H2_REALITY:-}" ] && NODE_NAME[19]=$NODE_NAME_H2_REALITY
  [ -n "${NODE_NAME_GRPC_REALITY:-}" ] && NODE_NAME[20]=$NODE_NAME_GRPC_REALITY
  [ -n "${NODE_NAME_ANYTLS:-}" ] && NODE_NAME[21]=$NODE_NAME_ANYTLS
  [ -n "${NODE_NAME_NAIVE:-}" ] && NODE_NAME[22]=$NODE_NAME_NAIVE
}

normalize_log_level() {
  LOG_LEVEL=${LOG_LEVEL:-"$LOG_LEVEL_DEFAULT"}
  LOG_LEVEL=${LOG_LEVEL,,}
  case "$LOG_LEVEL" in
    trace|debug|info|warn|error|fatal|panic ) ;;
    * ) error " LOG_LEVEL must be one of: trace, debug, info, warn, error, fatal, panic. " ;;
  esac
}

normalize_finger_print() {
  FINGER_PRINT=${FINGER_PRINT:-"${FINGER_PRINT_DEFAULT:-chrome}"}
  [[ "${FINGER_PRINT,,}" =~ ^[0-9a-z]+$ ]] || error " FINGER_PRINT must contain only letters and numbers. "
}

collapse_repeated_value() {
  local _value=$1 _len=${#1} _part _repeat _i
  [ -n "$_value" ] || return 0

  for ((_i=1; _i<=_len/2; _i++)); do
    (( _len % _i == 0 )) || continue
    _part=${_value:0:_i}
    [[ "$_part" == *.* ]] || continue
    _repeat=''
    while [ ${#_repeat} -lt "$_len" ]; do
      _repeat+=$_part
    done
    if [ "$_repeat" = "$_value" ]; then
      printf '%s' "$_part"
      return 0
    fi
  done

  printf '%s' "$_value"
}

normalize_domain_value() {
  local _value=$1
  _value=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]//g; s/:[[:space:]]*$//' <<< "$_value")
  _value=$(collapse_repeated_value "$_value")
  printf '%s' "$_value"
}

normalize_ws_domains() {
  [ -n "${ARGO_DOMAIN+x}" ] && ARGO_DOMAIN=$(normalize_domain_value "$ARGO_DOMAIN")
  [ -n "${VMESS_HOST_DOMAIN+x}" ] && VMESS_HOST_DOMAIN=$(normalize_domain_value "$VMESS_HOST_DOMAIN")
  [ -n "${VLESS_HOST_DOMAIN+x}" ] && VLESS_HOST_DOMAIN=$(normalize_domain_value "$VLESS_HOST_DOMAIN")
  return 0
}

normalize_ws_domain_mode() {
  normalize_ws_domains

  if [ "${IS_ARGO:-}" = 'is_argo' ]; then
    if [ -z "$ARGO_DOMAIN" ] && [ -n "${ARGO_AUTH:-}" ]; then
      ARGO_DOMAIN=${VLESS_HOST_DOMAIN:-${VMESS_HOST_DOMAIN:-}}
    fi
    unset VMESS_HOST_DOMAIN VLESS_HOST_DOMAIN
  elif [ "${IS_ARGO:-}" = 'no_argo' ]; then
    VMESS_HOST_DOMAIN=${VMESS_HOST_DOMAIN:-${ARGO_DOMAIN:-}}
    VLESS_HOST_DOMAIN=${VLESS_HOST_DOMAIN:-${ARGO_DOMAIN:-}}
    unset ARGO_DOMAIN
  fi
  return 0
}

ws_host_for() {
  case "$1" in
    h|vmess )
      [ "${IS_ARGO:-}" = 'is_argo' ] && printf '%s' "${ARGO_DOMAIN:-}" || printf '%s' "${VMESS_HOST_DOMAIN:-}"
      ;;
    i|vless )
      [ "${IS_ARGO:-}" = 'is_argo' ] && printf '%s' "${ARGO_DOMAIN:-}" || printf '%s' "${VLESS_HOST_DOMAIN:-}"
      ;;
  esac
}

ws_uses_argo() {
  [ "${IS_ARGO:-}" = 'is_argo' ]
}

input_uuid() {
  UUID_DEFAULT=$(cat /proc/sys/kernel/random/uuid)
  [[ "$IS_FAST_INSTALL" = 'is_fast_install' || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]] && UUID_CONFIRM=${UUID_CONFIRM:-"$UUID_DEFAULT"}
  if [ -z "$UUID_CONFIRM" ]; then
    (( STEP_NUM++ )) || true
    reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 12) " UUID_CONFIRM
  fi
  local UUID_ERROR_TIME=5
  until [[ -z "$UUID_CONFIRM" || "${UUID_CONFIRM,,}" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; do
    (( UUID_ERROR_TIME-- )) || true
    [ "$UUID_ERROR_TIME" = 0 ] && error "\n $(text 3) \n" || reading "\n $(text 4) \n" UUID_CONFIRM
  done
  UUID_CONFIRM=${UUID_CONFIRM:-"$UUID_DEFAULT"}
}

array_contains() {
  local _needle=$1 _item
  shift
  for _item in "$@"; do
    [ "$_item" = "$_needle" ] && return 0
  done
  return 1
}

array_contains_any() {
  local -n _haystack=$1
  shift
  local _needle
  for _needle in "$@"; do
    array_contains "$_needle" "${_haystack[@]}" && return 0
  done
  return 1
}

bool_enabled() {
  case "${1,,}" in
    1|true|yes|y|on ) return 0 ;;
    * ) return 1 ;;
  esac
}

protocol_switches_to_selection() {
  local _selected=''
  bool_enabled "${XTLS_REALITY:-}" && _selected+='b'
  bool_enabled "${HYSTERIA2:-}" && _selected+='c'
  bool_enabled "${TUIC:-}" && _selected+='d'
  bool_enabled "${SHADOWTLS:-}" && _selected+='e'
  bool_enabled "${SHADOWSOCKS:-}" && _selected+='f'
  bool_enabled "${TROJAN:-}" && _selected+='g'
  bool_enabled "${VMESS_WS:-}" && _selected+='h'
  bool_enabled "${VLESS_WS:-}" && _selected+='i'
  bool_enabled "${H2_REALITY:-}" && _selected+='j'
  bool_enabled "${GRPC_REALITY:-}" && _selected+='k'
  bool_enabled "${ANYTLS:-}" && _selected+='l'
  bool_enabled "${NAIVE:-}" && _selected+='m'
  printf '%s' "$_selected"
}

resolve_protocol_switch_mode() {
  local _selected
  case "${CHOOSE_PROTOCOLS,,}" in
    switch )
      CHOOSE_PROTOCOLS=$(protocol_switches_to_selection)
      [ -n "$CHOOSE_PROTOCOLS" ] || error " CHOOSE_PROTOCOLS=switch requires at least one protocol switch set to true. "
      ;;
    "" )
      _selected=$(protocol_switches_to_selection)
      [ -n "$_selected" ] && CHOOSE_PROTOCOLS=$_selected
      ;;
  esac
}

normalize_install_protocols() {
  local _max_ord=$(( CONSECUTIVE_PORTS + 97 )) _max_code _ord _protocol
  _max_code=$(asc "$_max_ord")
  INSTALL_PROTOCOLS=()
  resolve_protocol_switch_mode

  if [[ ! "${CHOOSE_PROTOCOLS,,}" =~ [b-${_max_code}] ]]; then
    for ((_ord=98; _ord<=_max_ord; _ord++)); do
      INSTALL_PROTOCOLS+=("$(asc "$_ord")")
    done
  else
    while IFS= read -r _protocol; do
      INSTALL_PROTOCOLS+=("$_protocol")
    done < <(grep -o . <<< "${CHOOSE_PROTOCOLS,,}" | sed "/[^b-${_max_code}]/d" | awk '!seen[$0]++')
  fi
}

protocol_port_var() {
  case "$1" in
    b ) printf '%s' PORT_XTLS_REALITY ;;
    c ) printf '%s' PORT_HYSTERIA2 ;;
    d ) printf '%s' PORT_TUIC ;;
    e ) printf '%s' PORT_SHADOWTLS ;;
    f ) printf '%s' PORT_SHADOWSOCKS ;;
    g ) printf '%s' PORT_TROJAN ;;
    h ) printf '%s' PORT_VMESS_WS ;;
    i ) printf '%s' PORT_VLESS_WS ;;
    j ) printf '%s' PORT_H2_REALITY ;;
    k ) printf '%s' PORT_GRPC_REALITY ;;
    l ) printf '%s' PORT_ANYTLS ;;
    m ) printf '%s' PORT_NAIVE ;;
  esac
}

protocol_name_by_code() {
  local _idx=$(( $(asc "$1") - 98 ))
  printf '%s' "${PROTOCOL_LIST[_idx]}"
}

valid_listen_port() {
  [[ "$1" =~ ^[1-9][0-9]{1,4}$ && "$1" -ge "$MIN_PORT" && "$1" -le "$MAX_PORT" ]]
}

resolve_protocol_ports() {
  local _pos _code _var _port _default _idx _name
  local _ports=() _names=()

  for _idx in "${!PROTOCOL_LIST[@]}"; do
    _code=$(asc $((_idx + 98)))
    if ! array_contains "$_code" "${INSTALL_PROTOCOLS[@]}"; then
      _var=$(protocol_port_var "$_code")
      [ -n "$_var" ] && unset "$_var"
    fi
  done

  for _pos in "${!INSTALL_PROTOCOLS[@]}"; do
    _code=${INSTALL_PROTOCOLS[_pos]}
    _var=$(protocol_port_var "$_code")
    [ -z "$_var" ] && continue

    _port=${!_var:-}
    if [ -z "$_port" ]; then
      _default=$(( START_PORT + _pos ))
      printf -v "$_var" '%s' "$_default"
      _port=$_default
    fi

    _name=$(protocol_name_by_code "$_code")
    valid_listen_port "$_port" || error " ${_var} (${_name}) must be ${MIN_PORT}-${MAX_PORT}. "

    for _idx in "${!_ports[@]}"; do
      if [ "${_ports[_idx]}" = "$_port" ]; then
        error " ${_var} (${_name}) conflicts with ${_names[_idx]} on port ${_port}. "
      fi
    done

    _ports+=("$_port")
    _names+=("${_var} (${_name})")
  done
}

protocol_port_in_use() {
  local _target=$1 _code _var
  for _code in "${INSTALL_PROTOCOLS[@]}"; do
    _var=$(protocol_port_var "$_code")
    [ -n "$_var" ] && [ "${!_var:-}" = "$_target" ] && return 0
  done
  return 1
}

default_service_port() {
  local _port=$(( START_PORT + ${#INSTALL_PROTOCOLS[@]} ))
  while protocol_port_in_use "$_port"; do
    _port=$(( _port + 1 ))
  done
  printf '%s' "$_port"
}

validate_nginx_port() {
  [ -z "$PORT_NGINX" ] && return
  valid_listen_port "$PORT_NGINX" || error " PORT_NGINX must be ${MIN_PORT}-${MAX_PORT}. "
  protocol_port_in_use "$PORT_NGINX" && error " PORT_NGINX conflicts with a selected protocol port. "
}

load_installed_protocol_ports() {
  INSTALLED_PORT_CODES=()
  INSTALLED_PORT_NAMES=()
  INSTALLED_PORT_TAGS=()
  INSTALLED_PORT_FILES=()
  INSTALLED_PORT_VALUES=()

  local _idx _code _file _port
  for _idx in "${!NODE_TAG[@]}"; do
    _file=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[_idx]}_inbounds.json")
    [ -s "$_file" ] || continue
    _port=$(awk -F ':' '/"listen_port"[[:space:]]*:/ {gsub(/[[:space:],]/, "", $2); print $2; exit}' "$_file")
    [ -n "$_port" ] || continue
    _code=$(asc $((_idx + 98)))
    INSTALLED_PORT_CODES+=("$_code")
    INSTALLED_PORT_NAMES+=("${PROTOCOL_LIST[_idx]}")
    INSTALLED_PORT_TAGS+=("${NODE_TAG[_idx]}")
    INSTALLED_PORT_FILES+=("$_file")
    INSTALLED_PORT_VALUES+=("$_port")
  done
}

format_installed_protocol_ports() {
  load_installed_protocol_ports
  local _i _out=''
  for _i in "${!INSTALLED_PORT_VALUES[@]}"; do
    _out+="${_out:+, }${INSTALLED_PORT_TAGS[_i]}:${INSTALLED_PORT_VALUES[_i]}"
  done
  printf '%s' "$_out"
}

parameter_present() {
  local _needle=${1^^} _item
  shift
  for _item in "$@"; do
    [ "${_item^^}" = "$_needle" ] && return 0
  done
  return 1
}

config_file_has_var() {
  local _var=$1
  [ -n "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] || return 1
  awk -v var="$_var" '
    /^[[:space:]]*#/ { next }
    $0 ~ "^[[:space:]]*" var "[[:space:]]*=" { found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$CONFIG_FILE"
}

apply_config_file_options() {
  [ -n "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] || return

  NONINTERACTIVE_INSTALL=noninteractive_install
  local _config_hy2_hopping_set=false
  config_file_has_var HY2_PORT_HOPPING_RANGE && _config_hy2_hopping_set=true
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"

  if config_file_has_var REALITY_PRIVATE && [ -z "${REALITY_PRIVATE[0]-}" ]; then
    unset REALITY_PRIVATE REALITY_PUBLIC
  fi

  if config_file_has_var LANGUAGE; then
    L=${LANGUAGE^^}
    [[ "$L" =~ ^E ]] && L=E || L=C
  fi

  config_file_has_var FINGER_PRINT && FINGER_PRINT_EXPLICIT=1

  if config_file_has_var ARGO; then
    bool_enabled "${ARGO:-}" && IS_ARGO=is_argo || IS_ARGO=no_argo
  fi

  if config_file_has_var SUBSCRIBE; then
    bool_enabled "${SUBSCRIBE:-}" && IS_SUB=is_sub || IS_SUB=no_sub
  fi

  if config_file_has_var HY2_REALM || config_file_has_var REALM; then
    if bool_enabled "${HY2_REALM:-}" || bool_enabled "${REALM:-}"; then
      IS_HY2_REALM=is_hy2_realm
    else
      unset IS_HY2_REALM
    fi
  fi

  if [ "$_config_hy2_hopping_set" = true ] && [ -z "$HY2_PORT_HOPPING_RANGE" ]; then
    IS_HOPPING=no_hopping
    unset PORT_HOPPING_START PORT_HOPPING_END
  fi

  TLS_SERVER_DEFAULT=${TLS_SERVER:-"$TLS_SERVER_DEFAULT"}
  normalize_ws_domain_mode
}

set_protocol_switch() {
  local _code=$1 _value=$2
  case "$_code" in
    b ) XTLS_REALITY=$_value ;;
    c ) HYSTERIA2=$_value ;;
    d ) TUIC=$_value ;;
    e ) SHADOWTLS=$_value ;;
    f ) SHADOWSOCKS=$_value ;;
    g ) TROJAN=$_value ;;
    h ) VMESS_WS=$_value ;;
    i ) VLESS_WS=$_value ;;
    j ) H2_REALITY=$_value ;;
    k ) GRPC_REALITY=$_value ;;
    l ) ANYTLS=$_value ;;
    m ) NAIVE=$_value ;;
  esac
}

set_protocol_switches_from_selection() {
  local _selection=$1 _code
  for _code in b c d e f g h i j k l m; do
    set_protocol_switch "$_code" false
  done
  while IFS= read -r _code; do
    [ -n "$_code" ] && set_protocol_switch "$_code" true
  done < <(grep -o . <<< "$_selection")
}

installed_protocol_selection() {
  local _idx _file _selection=''
  for _idx in "${!NODE_TAG[@]}"; do
    _file=$(first_matching_file "${WORK_DIR}/conf/*_${NODE_TAG[_idx]}_inbounds.json")
    [ -s "$_file" ] && _selection+="$(asc $((_idx + 98)))"
  done
  printf '%s' "$_selection"
}

first_nonempty_array_value() {
  local -n _array=$1
  local _value
  for _value in "${_array[@]}"; do
    [ -n "$_value" ] && printf '%s' "$_value" && return
  done
  return 0
}

valid_reality_private_format() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

reality_public_from_private() {
  local _private_key=$1 _b64 _mod _priv_len _prefix_hex _priv_hex
  [ -n "$_private_key" ] || return 1
  valid_reality_private_format "$_private_key" || return 1
  command -v xxd >/dev/null 2>&1 || return 1

  _b64=$(printf '%s' "$_private_key" | tr '_-' '/+')
  _mod=$(( ${#_b64} % 4 ))
  [ "$_mod" -eq 2 ] && _b64="${_b64}=="
  [ "$_mod" -eq 3 ] && _b64="${_b64}="
  [ "$_mod" -eq 1 ] && return 1

  printf '%s' "$_b64" | base64 -d > "${TEMP_DIR}/_X25519_PRIV_RAW" 2>/dev/null || return 1
  _priv_len=$(stat -c%s "${TEMP_DIR}/_X25519_PRIV_RAW" 2>/dev/null || stat -f%z "${TEMP_DIR}/_X25519_PRIV_RAW" 2>/dev/null)
  [ "$_priv_len" = 32 ] || return 1

  _prefix_hex="302e020100300506032b656e04220420"
  _priv_hex=$(xxd -p -c 256 "${TEMP_DIR}/_X25519_PRIV_RAW" | tr -d '\n')
  printf '%s%s' "$_prefix_hex" "$_priv_hex" | xxd -r -p > "${TEMP_DIR}/_X25519_PRIV_DER"
  openssl pkcs8 -inform DER -in "${TEMP_DIR}/_X25519_PRIV_DER" -nocrypt -out "${TEMP_DIR}/_X25519_PRIV_PEM" 2>/dev/null || return 1
  openssl pkey -in "${TEMP_DIR}/_X25519_PRIV_PEM" -pubout -outform DER > "${TEMP_DIR}/_X25519_PUB_DER" 2>/dev/null || return 1
  tail -c 32 "${TEMP_DIR}/_X25519_PUB_DER" > "${TEMP_DIR}/_X25519_PUB_RAW"
  base64 -w0 "${TEMP_DIR}/_X25519_PUB_RAW" | tr '+/' '-_' | sed -E 's/=+$//'
}

generate_reality_keypair() {
  local _binary=${1:-${DIR:-$WORK_DIR}/sing-box} _keypair
  [ -x "$_binary" ] || _binary="${TEMP_DIR}/sing-box"
  [ -x "$_binary" ] || _binary="${WORK_DIR}/sing-box"
  [ -x "$_binary" ] || return 1

  _keypair=$("$_binary" generate reality-keypair) || return 1
  REALITY_PRIVATE=$(awk '/PrivateKey/{print $NF}' <<< "$_keypair")
  REALITY_PUBLIC=$(awk '/PublicKey/{print $NF}' <<< "$_keypair")
  [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ]
}

normalize_reality_keypair() {
  local _private _public _derived_public _binary=${1:-${DIR:-$WORK_DIR}/sing-box}

  _private=$(first_nonempty_array_value REALITY_PRIVATE)
  _public=$(first_nonempty_array_value REALITY_PUBLIC)

  if [ -z "$_private" ] && [ -z "$_public" ]; then
    if ! generate_reality_keypair "$_binary"; then
      if [ "$L" = 'C' ]; then
        failure_error " 生成 Reality 密钥失败，脚本退出。 " "Command: $_binary generate reality-keypair"
      else
        failure_error " Failed to generate Reality keypair, script exits. " "Command: $_binary generate reality-keypair"
      fi
    fi
    _private=$REALITY_PRIVATE
  fi

  if [ -z "$_private" ]; then
    if [ "$L" = 'C' ]; then
      failure_error " Reality 配置无效，脚本退出。 " "REALITY_PRIVATE is required when REALITY_PUBLIC is set."
    else
      failure_error " Reality configuration is invalid, script exits. " "REALITY_PRIVATE is required when REALITY_PUBLIC is set."
    fi
  fi

  if ! valid_reality_private_format "$_private"; then
    if [ "$L" = 'C' ]; then
      failure_error " Reality 配置无效，脚本退出。 " "REALITY_PRIVATE must be a 43-character base64url X25519 private key."
    else
      failure_error " Reality configuration is invalid, script exits. " "REALITY_PRIVATE must be a 43-character base64url X25519 private key."
    fi
  fi

  _derived_public=$(reality_public_from_private "$_private")
  if [ -z "$_derived_public" ]; then
    if [ "$L" = 'C' ]; then
      failure_error " Reality 配置无效，脚本退出。 " "REALITY_PRIVATE is invalid or cannot be converted to a Reality public key."
    else
      failure_error " Reality configuration is invalid, script exits. " "REALITY_PRIVATE is invalid or cannot be converted to a Reality public key."
    fi
  fi

  _public=$_derived_public
  unset REALITY_PRIVATE REALITY_PUBLIC
  REALITY_PRIVATE=$_private
  REALITY_PUBLIC=$_public
}

installed_argo_auth() {
  local _content
  if [ -s "${WORK_DIR}/tunnel.json" ]; then
    cat "${WORK_DIR}/tunnel.json"
    return
  fi

  [ -s "$ARGO_DAEMON_FILE" ] || return
  if [ "$SYSTEM" = 'Alpine' ]; then
    _content=$(grep '^command_args=' "$ARGO_DAEMON_FILE")
  else
    _content=$(grep '^ExecStart=' "$ARGO_DAEMON_FILE")
  fi

  if grep -Fq -- '--token' <<< "$_content"; then
    sed -n 's/.*--token[[:space:]]\+\([^"[:space:]]\+\).*/\1/p' <<< "$_content"
  fi
}

installed_subscription_enabled() {
  [ -s "${WORK_DIR}/nginx.conf" ] &&
    grep -Fq 'map $http_user_agent $path1' "${WORK_DIR}/nginx.conf"
}

prepare_config_update_defaults() {
  local _selection _value

  _selection=$(installed_protocol_selection)
  if [ -n "$_selection" ] && [ -z "$CHOOSE_PROTOCOLS" ] && [ -z "$(protocol_switches_to_selection)" ]; then
    set_protocol_switches_from_selection "$_selection"
    CHOOSE_PROTOCOLS=$_selection
  fi

  [ -s "$ARGO_DAEMON_FILE" ] && IS_ARGO=is_argo
  installed_subscription_enabled && IS_SUB=is_sub

  fetch_nodes_value
  normalize_ws_domain_mode

  [ -n "$_selection" ] && CHOOSE_PROTOCOLS=${CHOOSE_PROTOCOLS:-$_selection}
  UUID_CONFIRM=${UUID_CONFIRM:-"$(first_nonempty_array_value UUID)"}
  UUID_CONFIRM=${UUID_CONFIRM:-"${TROJAN_PASSWORD:-${SHADOWSOCKS_PASSWORD:-${SHADOWTLS_PASSWORD:-}}}"}
  NODE_NAME_CONFIRM=${NODE_NAME_CONFIRM:-"$(first_nonempty_array_value NODE_NAME)"}
  TLS_SERVER_DEFAULT=${TLS_SERVER:-"$TLS_SERVER_DEFAULT"}
  SERVER_IP=${SERVER_IP:-"$SERVER_IP_DEFAULT"}

  if [ -s "$ARGO_DAEMON_FILE" ]; then
    _value=$(installed_argo_auth)
    ARGO_AUTH=${ARGO_AUTH:-$_value}
  fi
}

shell_quote() {
  local _value=${1-}
  printf "'%s'" "${_value//\'/\'\\\'\'}"
}

config_value() {
  local _var=$1 _default=${2-}
  if [ -n "${!_var+x}" ]; then
    shell_quote "${!_var}"
  else
    shell_quote "$_default"
  fi
}

config_bool() {
  local _var=$1 _enabled=false
  case "$_var" in
    XTLS_REALITY ) array_contains b "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    HYSTERIA2 ) array_contains c "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    TUIC ) array_contains d "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    SHADOWTLS ) array_contains e "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    SHADOWSOCKS ) array_contains f "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    TROJAN ) array_contains g "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    VMESS_WS ) array_contains h "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    VLESS_WS ) array_contains i "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    H2_REALITY ) array_contains j "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    GRPC_REALITY ) array_contains k "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    ANYTLS ) array_contains l "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    NAIVE ) array_contains m "${INSTALL_PROTOCOLS[@]}" && _enabled=true ;;
    SUBSCRIBE ) [ "$IS_SUB" = 'is_sub' ] && _enabled=true ;;
    ARGO ) [ "$IS_ARGO" = 'is_argo' ] && _enabled=true ;;
    HY2_REALM ) [ "$IS_HY2_REALM" = 'is_hy2_realm' ] && _enabled=true ;;
  esac
  shell_quote "$_enabled"
}

config_node_name() {
  local _idx=$1
  shell_quote "${NODE_NAME[_idx]:-${NODE_NAME_CONFIRM:-}}"
}

config_reality_private() {
  local _value
  _value=$(first_nonempty_array_value REALITY_PRIVATE)
  shell_quote "$_value"
}

config_argo_auth() {
  if [ "${IS_ARGO:-}" != 'is_argo' ]; then
    shell_quote ''
    return
  fi

  if [ -n "${ARGO_AUTH:-}" ]; then
    shell_quote "$ARGO_AUTH"
  elif [ -n "$ARGO_JSON" ]; then
    shell_quote "$ARGO_JSON"
  elif [ -n "$ARGO_TOKEN" ]; then
    shell_quote "$ARGO_TOKEN"
  else
    shell_quote ''
  fi
}

config_argo_domain() {
  [ "${IS_ARGO:-}" = 'is_argo' ] && shell_quote "${ARGO_DOMAIN:-}" || shell_quote ''
}

config_ws_host_domain() {
  if [ "${IS_ARGO:-}" = 'is_argo' ]; then
    shell_quote ''
  else
    shell_quote "$(ws_host_for "$1")"
  fi
}

config_state_set_line() {
  local _file=$1 _var=$2 _value=$3 _active=${4:-true}
  local _tmp

  if grep -Eq "^[[:space:]]*#?[[:space:]]*${_var}[[:space:]]*=" "$_file"; then
    _tmp=$(mktemp "${_file}.line.XXXXXX") || error " Cannot create temporary config file. "
    awk -v var="$_var" -v value="$_value" -v active="$_active" '
      BEGIN { done = 0 }
      !done {
        pattern = "^[[:space:]]*#?[[:space:]]*" var "[[:space:]]*="
        if ($0 ~ pattern) {
          comment = ""
          if (match($0, /[[:space:]]#[^#]*$/)) {
            comment = substr($0, RSTART)
          }
          prefix = active == "true" ? "" : "#"
          print prefix var "=" value comment
          done = 1
          next
        }
      }
      { print }
    ' "$_file" > "$_tmp" || { rm -f "$_tmp"; error " Failed to update config variable: $_var "; }
    cat "$_tmp" > "$_file" || { rm -f "$_tmp"; error " Failed to write config file: $_file "; }
    rm -f "$_tmp"
  elif [ "$_active" = true ]; then
    printf '\n%s=%s\n' "$_var" "$_value" >> "$_file" || error " Failed to write config variable: $_var "
  fi
}

config_state_comment_line() {
  local _file=$1 _var=$2 _tmp
  grep -Eq "^[[:space:]]*#?[[:space:]]*${_var}[[:space:]]*=" "$_file" || return 0

  _tmp=$(mktemp "${_file}.line.XXXXXX") || error " Cannot create temporary config file. "
  awk -v var="$_var" '
    BEGIN { done = 0 }
    !done {
      pattern = "^[[:space:]]*#?[[:space:]]*" var "[[:space:]]*="
      if ($0 ~ pattern) {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        sub(/^#[[:space:]]*/, "", line)
        print "#" line
        done = 1
        next
      }
    }
    { print }
  ' "$_file" > "$_tmp" || { rm -f "$_tmp"; error " Failed to update config variable: $_var "; }
  cat "$_tmp" > "$_file" || { rm -f "$_tmp"; error " Failed to write config file: $_file "; }
  rm -f "$_tmp"
}

config_state_set_optional() {
  local _file=$1 _var=$2 _value=$3 _active=${4:-false}
  if [ "$_active" != true ]; then
    config_state_comment_line "$_file" "$_var"
    return
  fi
  config_state_set_line "$_file" "$_var" "$_value" "$_active"
}

config_state_set_bool() {
  local _file=$1 _var=$2 _value _active=false
  _value=$(config_bool "$_var")
  if [ "$_value" != "'true'" ]; then
    config_state_comment_line "$_file" "$_var"
    return
  fi
  _active=true
  config_state_set_line "$_file" "$_var" "$_value" "$_active"
}

write_config_state_file() {
  [ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ] || return
  [ -n "$CONFIG_FILE" ] || return

  local _target=$CONFIG_FILE
  local _dir _base _backup _tmp _active _value
  local _has_reality=false _has_xtls=false _has_hy2=false _has_tuic=false _has_shadowtls=false _has_shadowsocks=false _has_trojan=false
  local _has_vmess_ws=false _has_vless_ws=false _has_ws=false _has_h2=false _has_grpc=false _has_anytls=false _has_naive=false
  _dir=$(dirname "$_target")
  _base=$(basename "$_target")
  [ -d "$_dir" ] || error " Config directory does not exist: $_dir "
  [ -e "$_target" ] || error " Config file does not exist: $_target "

  _backup="${_target}.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$_target" "$_backup"
  _tmp=$(mktemp "${_dir}/.${_base}.tmp.XXXXXX") || error " Cannot create temporary config file. "
  cp -p "$_target" "$_tmp" || { rm -f "$_tmp"; error " Failed to prepare config file: $_target "; }

  array_contains b "${INSTALL_PROTOCOLS[@]}" && _has_xtls=true
  array_contains_any INSTALL_PROTOCOLS b j k && _has_reality=true
  array_contains c "${INSTALL_PROTOCOLS[@]}" && _has_hy2=true
  array_contains d "${INSTALL_PROTOCOLS[@]}" && _has_tuic=true
  array_contains e "${INSTALL_PROTOCOLS[@]}" && _has_shadowtls=true
  array_contains f "${INSTALL_PROTOCOLS[@]}" && _has_shadowsocks=true
  array_contains g "${INSTALL_PROTOCOLS[@]}" && _has_trojan=true
  array_contains h "${INSTALL_PROTOCOLS[@]}" && _has_vmess_ws=true
  array_contains i "${INSTALL_PROTOCOLS[@]}" && _has_vless_ws=true
  [[ "$_has_vmess_ws" = true || "$_has_vless_ws" = true ]] && _has_ws=true
  array_contains j "${INSTALL_PROTOCOLS[@]}" && _has_h2=true
  array_contains k "${INSTALL_PROTOCOLS[@]}" && _has_grpc=true
  array_contains l "${INSTALL_PROTOCOLS[@]}" && _has_anytls=true
  array_contains m "${INSTALL_PROTOCOLS[@]}" && _has_naive=true

  config_state_set_line "$_tmp" CHOOSE_PROTOCOLS "$(shell_quote switch)" true

  config_state_set_line "$_tmp" LANGUAGE "$(shell_quote "${L,,}")" true
  _active=false; [ -n "${GH_PROXY:-}" ] && _active=true
  config_state_set_optional "$_tmp" GH_PROXY "$(shell_quote "${GH_PROXY:-}")" "$_active"
  config_state_set_line "$_tmp" START_PORT "$(config_value START_PORT "$START_PORT_DEFAULT")" true
  config_state_set_line "$_tmp" LOG_LEVEL "$(config_value LOG_LEVEL "$LOG_LEVEL_DEFAULT")" true
  config_state_comment_line "$_tmp" NTP_ENABLED
  config_state_comment_line "$_tmp" NTP_SERVER
  config_state_comment_line "$_tmp" NTP_SERVER_PORT
  config_state_comment_line "$_tmp" NTP_INTERVAL
  _active=false; [[ "$IS_SUB" = 'is_sub' || "$IS_ARGO" = 'is_argo' ]] && _active=true
  config_state_set_optional "$_tmp" PORT_NGINX "$(config_value PORT_NGINX)" "$_active"
  config_state_set_line "$_tmp" SERVER_IP "$(config_value SERVER_IP)" true
  config_state_set_line "$_tmp" TLS_SERVER "$(shell_quote "${TLS_SERVER:-$TLS_SERVER_DEFAULT}")" true
  config_state_set_line "$_tmp" FINGER_PRINT "$(config_value FINGER_PRINT "${FINGER_PRINT:-${FINGER_PRINT_DEFAULT:-chrome}}")" true
  config_state_set_line "$_tmp" NODE_NAME_CONFIRM "$(config_value NODE_NAME_CONFIRM)" true

  config_state_set_line "$_tmp" UUID_CONFIRM "$(config_value UUID_CONFIRM)" true

  config_state_set_bool "$_tmp" SUBSCRIBE
  config_state_set_bool "$_tmp" ARGO
  _active=false; [[ "$IS_ARGO" = 'is_argo' && -n "${ARGO_DOMAIN:-}" && ! "$ARGO_DOMAIN" =~ trycloudflare\.com$ ]] && _active=true
  config_state_set_optional "$_tmp" ARGO_DOMAIN "$(config_argo_domain)" "$_active"
  _value=$(config_argo_auth)
  _active=false; [[ "$IS_ARGO" = 'is_argo' && "$_value" != "''" ]] && _active=true
  config_state_set_optional "$_tmp" ARGO_AUTH "$_value" "$_active"
  config_state_set_optional "$_tmp" CDN "$(shell_quote "${CDN[17]:-${CDN[18]:-${CDN:-${CDN_DOMAIN[0]}}}}")" "$_has_ws"
  _value=$(shell_quote "${CDN_PORT[17]:-${CDN_PORT[18]:-${CDN_PORT:-}}}")
  _active=false; [[ "$_has_ws" = true && "$_value" != "''" ]] && _active=true
  config_state_set_optional "$_tmp" CDN_PORT "$_value" "$_active"

  config_state_set_optional "$_tmp" REALITY_PRIVATE "$(config_reality_private)" "$_has_reality"

  config_state_set_bool "$_tmp" XTLS_REALITY
  config_state_set_optional "$_tmp" PORT_XTLS_REALITY "$(config_value PORT_XTLS_REALITY)" "$_has_xtls"
  config_state_set_optional "$_tmp" NODE_NAME_XTLS_REALITY "$(config_node_name 11)" "$_has_xtls"

  config_state_set_bool "$_tmp" HYSTERIA2
  config_state_set_optional "$_tmp" PORT_HYSTERIA2 "$(config_value PORT_HYSTERIA2)" "$_has_hy2"
  config_state_set_optional "$_tmp" NODE_NAME_HYSTERIA2 "$(config_node_name 12)" "$_has_hy2"
  _value=$(config_value HY2_PORT_HOPPING_RANGE)
  _active=false; [[ "$_has_hy2" = true && "$_value" != "''" ]] && _active=true
  config_state_set_optional "$_tmp" HY2_PORT_HOPPING_RANGE "$_value" "$_active"
  config_state_set_bool "$_tmp" HY2_REALM
  config_state_set_line "$_tmp" REALM "$(shell_quote false)" false
  config_state_comment_line "$_tmp" HY2_WARP
  config_state_comment_line "$_tmp" REALM_WARP
  config_state_comment_line "$_tmp" WARP_REALM
  _active=false; [[ "$_has_hy2" = true && "$IS_HY2_REALM" = 'is_hy2_realm' ]] && _active=true
  config_state_set_optional "$_tmp" HY2_REALM_ID "$(config_value HY2_REALM_ID)" "$_active"
  config_state_set_optional "$_tmp" HY2_UP "$(config_value HY2_UP 200)" "$_has_hy2"
  config_state_set_optional "$_tmp" HY2_DOWN "$(config_value HY2_DOWN 1000)" "$_has_hy2"

  config_state_set_bool "$_tmp" TUIC
  config_state_set_optional "$_tmp" PORT_TUIC "$(config_value PORT_TUIC)" "$_has_tuic"
  config_state_set_optional "$_tmp" NODE_NAME_TUIC "$(config_node_name 13)" "$_has_tuic"
  config_state_set_optional "$_tmp" TUIC_PASSWORD "$(config_value TUIC_PASSWORD)" "$_has_tuic"
  config_state_set_optional "$_tmp" TUIC_CONGESTION_CONTROL "$(config_value TUIC_CONGESTION_CONTROL bbr)" "$_has_tuic"

  config_state_set_bool "$_tmp" SHADOWTLS
  config_state_set_optional "$_tmp" PORT_SHADOWTLS "$(config_value PORT_SHADOWTLS)" "$_has_shadowtls"
  config_state_set_optional "$_tmp" NODE_NAME_SHADOWTLS "$(config_node_name 14)" "$_has_shadowtls"
  config_state_set_optional "$_tmp" SHADOWTLS_PASSWORD "$(config_value SHADOWTLS_PASSWORD)" "$_has_shadowtls"
  config_state_set_optional "$_tmp" SHADOWTLS_METHOD "$(config_value SHADOWTLS_METHOD 2022-blake3-aes-128-gcm)" "$_has_shadowtls"

  config_state_set_bool "$_tmp" SHADOWSOCKS
  config_state_set_optional "$_tmp" PORT_SHADOWSOCKS "$(config_value PORT_SHADOWSOCKS)" "$_has_shadowsocks"
  config_state_set_optional "$_tmp" NODE_NAME_SHADOWSOCKS "$(config_node_name 15)" "$_has_shadowsocks"
  config_state_set_optional "$_tmp" SHADOWSOCKS_PASSWORD "$(config_value SHADOWSOCKS_PASSWORD)" "$_has_shadowsocks"
  config_state_set_optional "$_tmp" SHADOWSOCKS_METHOD "$(config_value SHADOWSOCKS_METHOD 2022-blake3-aes-128-gcm)" "$_has_shadowsocks"

  config_state_set_bool "$_tmp" TROJAN
  config_state_set_optional "$_tmp" PORT_TROJAN "$(config_value PORT_TROJAN)" "$_has_trojan"
  config_state_set_optional "$_tmp" NODE_NAME_TROJAN "$(config_node_name 16)" "$_has_trojan"
  config_state_set_optional "$_tmp" TROJAN_PASSWORD "$(config_value TROJAN_PASSWORD)" "$_has_trojan"

  config_state_set_bool "$_tmp" VMESS_WS
  config_state_set_optional "$_tmp" PORT_VMESS_WS "$(config_value PORT_VMESS_WS)" "$_has_vmess_ws"
  config_state_set_optional "$_tmp" NODE_NAME_VMESS_WS "$(config_node_name 17)" "$_has_vmess_ws"
  _active=false; [[ "$_has_vmess_ws" = true && "$IS_ARGO" != 'is_argo' ]] && _active=true
  config_state_set_optional "$_tmp" VMESS_HOST_DOMAIN "$(config_ws_host_domain h)" "$_active"
  config_state_set_optional "$_tmp" VMESS_WS_PATH "$(config_value VMESS_WS_PATH)" "$_has_vmess_ws"

  config_state_set_bool "$_tmp" VLESS_WS
  config_state_set_optional "$_tmp" PORT_VLESS_WS "$(config_value PORT_VLESS_WS)" "$_has_vless_ws"
  config_state_set_optional "$_tmp" NODE_NAME_VLESS_WS "$(config_node_name 18)" "$_has_vless_ws"
  _active=false; [[ "$_has_vless_ws" = true && "$IS_ARGO" != 'is_argo' ]] && _active=true
  config_state_set_optional "$_tmp" VLESS_HOST_DOMAIN "$(config_ws_host_domain i)" "$_active"
  config_state_set_optional "$_tmp" VLESS_WS_PATH "$(config_value VLESS_WS_PATH)" "$_has_vless_ws"

  config_state_set_bool "$_tmp" H2_REALITY
  config_state_set_optional "$_tmp" PORT_H2_REALITY "$(config_value PORT_H2_REALITY)" "$_has_h2"
  config_state_set_optional "$_tmp" NODE_NAME_H2_REALITY "$(config_node_name 19)" "$_has_h2"

  config_state_set_bool "$_tmp" GRPC_REALITY
  config_state_set_optional "$_tmp" PORT_GRPC_REALITY "$(config_value PORT_GRPC_REALITY)" "$_has_grpc"
  config_state_set_optional "$_tmp" NODE_NAME_GRPC_REALITY "$(config_node_name 20)" "$_has_grpc"

  config_state_set_bool "$_tmp" ANYTLS
  config_state_set_optional "$_tmp" PORT_ANYTLS "$(config_value PORT_ANYTLS)" "$_has_anytls"
  config_state_set_optional "$_tmp" NODE_NAME_ANYTLS "$(config_node_name 21)" "$_has_anytls"

  config_state_set_bool "$_tmp" NAIVE
  config_state_set_optional "$_tmp" PORT_NAIVE "$(config_value PORT_NAIVE)" "$_has_naive"
  config_state_set_optional "$_tmp" NODE_NAME_NAIVE "$(config_node_name 22)" "$_has_naive"

  if [ -e "$_target" ]; then
    cat "$_tmp" > "$_target" || { rm -f "$_tmp"; error " Failed to write config file: $_target "; }
    rm -f "$_tmp"
  else
    mv "$_tmp" "$_target" || { rm -f "$_tmp"; error " Failed to write config file: $_target "; }
  fi

  info "\n Config file updated: $_target "
  [ -e "$_backup" ] && hint " Backup saved: $_backup "
}

first_matching_file() {
  local _matches
  _matches=$(compgen -G "$1" || true)
  sed -n '1p' <<< "$_matches"
}

json_string_value() {
  local _key=$1
  awk -v key="\"${_key}\"" '
    index($0, key) {
      value=$0
      sub(".*" key "[[:space:]]*:[[:space:]]*\"", "", value)
      if (value != $0) {
        sub("\".*", "", value)
        print value
        exit
      }
    }
  '
}

json_number_value() {
  local _key=$1
  awk -v key="\"${_key}\"" '
    index($0, key) {
      value=$0
      sub(".*" key "[[:space:]]*:[[:space:]]*", "", value)
      if (value != $0) {
        sub("[^0-9].*", "", value)
        print value
        exit
      }
    }
  '
}

check_cdn() {
  GH_PROXY=${GH_PROXY:-}
  [ -z "$GH_PROXY" ] && return 0
  [[ "$GH_PROXY" =~ ^https?://[^[:space:]]+$ ]] || error " GH_PROXY must be an HTTP(S) URL prefix. "
  [[ "$GH_PROXY" == */ ]] || GH_PROXY="${GH_PROXY}/"
}

# 选择中英语言
select_language() {
  if [ -z "$L" ]; then
    if [ -s ${WORK_DIR}/language ]; then
      L=$(cat ${WORK_DIR}/language)
    else
      L=E && hint "\n $(text 0) \n" && reading " $(text 24) " LANGUAGE
      [ "$LANGUAGE" = 2 ] && L=C
    fi
  fi
}

# 字母与数字的 ASCII 码值转换
asc() {
  if [[ "$1" = [a-z] ]]; then
    [ "$2" = '++' ] && printf "\\$(printf '%03o' "$(( $(printf "%d" "'$1'") + 1 ))")" || printf "%d" "'$1'"
  else
    [[ "$1" =~ ^[0-9]+$ ]] && printf "\\$(printf '%03o' "$1")"
  fi
}

# 收录一些热心网友和官网的 cdn
parse_host_port() {
  local INPUT_VALUE=$1
  local DEFAULT_PORT=$2
  local HOST_VALUE PORT_VALUE

  INPUT_VALUE=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$INPUT_VALUE")
  [ -z "$INPUT_VALUE" ] && return 1

  if [[ "$INPUT_VALUE" =~ ^\[([^][]+)\]:([0-9]{1,5})$ ]]; then
    HOST_VALUE="${BASH_REMATCH[1]}"
    PORT_VALUE="${BASH_REMATCH[2]}"
  elif [[ "$INPUT_VALUE" =~ ^([^:]+):([0-9]{1,5})$ ]] && [[ "${BASH_REMATCH[1]}" != *:* ]]; then
    HOST_VALUE="${BASH_REMATCH[1]}"
    PORT_VALUE="${BASH_REMATCH[2]}"
  else
    HOST_VALUE="$INPUT_VALUE"
    PORT_VALUE=$DEFAULT_PORT
  fi

  if [[ -n "$PORT_VALUE" && ( ! "$PORT_VALUE" =~ ^[0-9]+$ || "$PORT_VALUE" -lt 1 || "$PORT_VALUE" -gt 65535 ) ]]; then
    return 1
  fi

  PARSED_HOST="$HOST_VALUE"
  PARSED_PORT="$PORT_VALUE"
  return 0
}

format_uri_host() {
  local HOST_VALUE=$1
  if [[ "$HOST_VALUE" == *:* && ! "$HOST_VALUE" =~ ^\[.*\]$ ]]; then
    printf '[%s]' "$HOST_VALUE"
  else
    printf '%s' "$HOST_VALUE"
  fi
}

input_cdn() {
  echo ""
  unset CUSTOM_CDN PARSED_HOST PARSED_PORT
  for c in "${!CDN_DOMAIN[@]}"; do
    hint " $(( c+1 )). ${CDN_DOMAIN[c]} "
  done

  while true; do
    reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 53) " CUSTOM_CDN
    case "$CUSTOM_CDN" in
      [1-${#CDN_DOMAIN[@]}] )
        CDN="${CDN_DOMAIN[$((CUSTOM_CDN-1))]}"
        CDN_PORT[17]='80'
        CDN_PORT[18]='443'
        break
        ;;
      ?????* )
        parse_host_port "$CUSTOM_CDN" '' || {
          warning "\n $(text 36) \n"
          continue
        }
        CDN="$PARSED_HOST"
        if [ -n "$PARSED_PORT" ]; then
          CDN_PORT[17]="$PARSED_PORT"
          CDN_PORT[18]="$PARSED_PORT"
        else
          CDN_PORT[17]='80'
          CDN_PORT[18]='443'
        fi
        break
        ;;
      * )
        CDN="${CDN_DOMAIN[0]}"
        CDN_PORT[17]='80'
        CDN_PORT[18]='443'
        break
    esac
  done
}

# 更换优选域名 / reality SNI / 节点名 / UUID
change_config() {
  [ ! -d "${WORK_DIR}" ] && error " $(text 107) "

  local MENU_IDX=() MENU_KEY=() MENU_VAL=()

  # 优选 CDN
  ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1 && local CDN_NOW=$(awk -F '"' '/"CDN"/{print $4; exit}' ${WORK_DIR}/conf/*-ws*inbounds.json) && MENU_IDX+=(128) && MENU_KEY+=(cdn) && MENU_VAL+=("$CDN_NOW")

  # Reality SNI
  ls ${WORK_DIR}/conf/*reality_inbounds.json >/dev/null 2>&1 && local SNI_NOW=$(awk 'match($0, /"server_name"[[:space:]]*:[[:space:]]*"[^"]+"/){gsub(/.*: *"/,""); gsub(/".*/,""); print; exit}' ${WORK_DIR}/conf/*reality_inbounds.json) && MENU_IDX+=(129) && MENU_KEY+=(sni) && MENU_VAL+=("$SNI_NOW")

  # 监听端口
  local PORTS_NOW=$(format_installed_protocol_ports)
  if [ -n "$PORTS_NOW" ]; then
    MENU_IDX+=(30) && MENU_KEY+=(ports) && MENU_VAL+=("${PORTS_NOW}")
  fi

  # 节点名
  local NAME_NOW=$(awk '/"tag"/{gsub(/^.*"tag": *"/,""); gsub(/".*/,""); sub(/ [^ ]*$/,""); print; exit}' ${WORK_DIR}/conf/*_inbounds.json)
  [ -n "$NAME_NOW" ] && MENU_IDX+=(130) && MENU_KEY+=(name) && MENU_VAL+=("$NAME_NOW")

  # UUID / Password
  local UUID_NOW="$(awk -F'"' '/"uuid"[[:space:]]*:[[:space:]]*"/ || /"id"[[:space:]]*:[[:space:]]*"/ {print $4; exit}' ${WORK_DIR}/conf/*_inbounds.json)"
  [ -n "$UUID_NOW" ] && MENU_IDX+=(131) && MENU_KEY+=(uuid) && MENU_VAL+=("$UUID_NOW")

  # 服务器 IP
  ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1 && local SERVER_IP_NOW=$(awk -F '"' '/"WS_SERVER_IP_SHOW"/{print $4; exit}' ${WORK_DIR}/conf/*-ws*inbounds.json) || local SERVER_IP_NOW=$(grep -A1 '"tag"' ${WORK_DIR}/list | sed -E '/-ws(-tls)*",$/{N;d}' | awk -F '"' '/"server"/{count++; if (count == 1) {print $4; exit}}')
  [ -n "$SERVER_IP_NOW" ] && MENU_IDX+=(132) && MENU_KEY+=(serverip) && MENU_VAL+=("$SERVER_IP_NOW")

  # 从 sing-box 格式的 list 中提取 client-fingerprint，取第一个匹配值
  local FP_NOW=$(awk -F '"' '/"fingerprint"/{print $4; exit}' ${WORK_DIR}/list 2>/dev/null)
  FP_NOW=${FP_NOW:-${FINGER_PRINT:-${FINGER_PRINT_DEFAULT:-chrome}}}
  [ -n "$FP_NOW" ] && MENU_IDX+=(168) && MENU_KEY+=(fingerprint) && MENU_VAL+=("$FP_NOW")

  # Hysteria2 带宽和端口跳跃（仅在 Hysteria2 已安装时显示）
  if ls ${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json >/dev/null 2>&1; then
    local HY2_LINE=$(grep 'type: hysteria2' ${WORK_DIR}/subscribe/proxies)
    if [[ "$HY2_LINE" =~ up:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\".*down:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\" ]]; then
      HY2_UP_NOW="${BASH_REMATCH[1]}"
      HY2_DOWN_NOW="${BASH_REMATCH[2]}"
    elif [[ "$HY2_LINE" =~ down:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\".*up:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\" ]]; then
      HY2_DOWN_NOW="${BASH_REMATCH[1]}"
      HY2_UP_NOW="${BASH_REMATCH[2]}"
    fi
    HY2_UP_NOW=${HY2_UP_NOW:-200}
    HY2_DOWN_NOW=${HY2_DOWN_NOW:-1000}

    MENU_IDX+=(140) && MENU_KEY+=(hy2bw) && MENU_VAL+=("${HY2_UP_NOW}/${HY2_DOWN_NOW}")

    if grep -q 'realm-opts' <<< "$HY2_LINE"; then
      local HY2_REALM_ACTION="$(text 171)"
      MENU_IDX+=(171)
    else
      local HY2_REALM_ACTION="$(text 172)"
      MENU_IDX+=(172)
    fi
    MENU_KEY+=(hy2realm) && MENU_VAL+=("${HY2_REALM_ACTION}")

    check_port_hopping_nat
    MENU_IDX+=(139) && MENU_KEY+=(hy2hopping) && MENU_VAL+=("${HY2_PORT_HOPPING_RANGE}")
  fi

  [ "${#MENU_IDX[@]}" -eq 0 ] && error " $(text 110) "

  # 显示动态菜单
  hint "\n $(text 127)\n"
  for _i in "${!MENU_IDX[@]}"; do
    local _val="${MENU_VAL[_i]}"
    local _raw
    eval "_raw=\"\${${L}[${MENU_IDX[_i]}]}\""
    eval "hint \" $(( _i+1 )). ${_raw}\""
  done
  hint ""
  reading " $(text 24) " CHOOSE_NODE_INFO

  if ! [[ "$CHOOSE_NODE_INFO" =~ ^[0-9]+$ ]] || \
     [ "$CHOOSE_NODE_INFO" -lt 1 ] || \
     [ "$CHOOSE_NODE_INFO" -gt "${#MENU_IDX[@]}" ]; then
    info " $(text 135) " && return
  fi

  local IDX=$(( CHOOSE_NODE_INFO - 1 ))
  local KEY="${MENU_KEY[IDX]}"
  local OLD="${MENU_VAL[IDX]}"

  # 特殊操作路由（不走通用替换逻辑）
  if  [ "$KEY" = "cdn" ]; then
    input_cdn
    ls ${WORK_DIR}/conf/*vmess-ws*inbounds.json >/dev/null 2>&1 && sed -i "s|CDN\": \".*\"|CDN\": \"${CDN}\"|g; s|CDN_PORT\": \".*\"|CDN_PORT\": \"${CDN_PORT[17]}\"|g" ${WORK_DIR}/conf/*vmess-ws*inbounds.json 2>/dev/null
    ls ${WORK_DIR}/conf/*vless-ws*inbounds.json >/dev/null 2>&1 && sed -i "s|CDN\": \".*\"|CDN\": \"${CDN}\"|g; s|CDN_PORT\": \".*\"|CDN_PORT\": \"${CDN_PORT[18]}\"|g" ${WORK_DIR}/conf/*vless-ws*inbounds.json 2>/dev/null
    export_list
    return
  elif [ "$KEY" = "ports" ]; then
    change_start_port
    return
  elif [ "$KEY" = "hy2bw" ]; then
    # 修改 Hysteria2 带宽
    local HY2_UP HY2_DOWN
    while true; do
      reading " $(text 141) " HY2_UP
      [[ "$HY2_UP" =~ ^[1-9][0-9]*$ ]] && break
      warning " $(text 143) "
    done
    while true; do
      reading " $(text 142) " HY2_DOWN
      [[ "$HY2_DOWN" =~ ^[1-9][0-9]*$ ]] && break
      warning " $(text 143) "
    done
    sed -i -E "s/(up: \")([0-9]+)( Mbps\")/\1${HY2_UP}\3/g; s/(down: \")([0-9]+)( Mbps\")/\1${HY2_DOWN}\3/g" ${WORK_DIR}/subscribe/proxies
    hint " $(text 112) "
    export_list
    return
  elif [ "$KEY" = "hy2realm" ]; then
    # 添加 / 删除 Hysteria2 Realm；菜单已明确显示开启/关闭动作，这里不再二次确认 Realm 本身
    local HY2_LINE=$(grep 'type: hysteria2' ${WORK_DIR}/subscribe/proxies)
    if grep -q 'realm-opts' <<< "$HY2_LINE"; then
      set_hy2_realm_config disable
    else
      fetch_nodes_value
      IS_HY2_REALM=is_hy2_realm
      HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]:-${UUID_CONFIRM}}}"
      set_hy2_realm_config enable
    fi
    hint " $(text 112) "
    reload_service_or_fail Sing-box sing-box
    export_list
    return
  elif [ "$KEY" = "hy2hopping" ]; then
    # 修改 Hysteria2 端口跳跃
    check_port_hopping_nat
    local OLD_START="$PORT_HOPPING_START" OLD_END="$PORT_HOPPING_END"
    hint "\n $(text 97) \n"

    local HOPPING_ERROR_TIME=6
    local NEW_RANGE=""
    until [ -n "$IS_HOPPING_SET" ]; do
      if [ -z "$NEW_RANGE" ]; then
        (( HOPPING_ERROR_TIME-- )) || true
        case "$HOPPING_ERROR_TIME" in
          0 ) error "\n $(text 3) \n" ;;
          5 ) reading " $(text 98) " NEW_RANGE ;;
          * ) reading " $(text 98) " NEW_RANGE ;;
        esac
      fi

      # 预处理：将所有分隔符统一为冒号，过滤非法字符
      NEW_RANGE=$(sed 's/[-－—：]/:/g' <<< "$NEW_RANGE" | tr -cd '0-9:')

      if [[ -z "$NEW_RANGE" || "${NEW_RANGE,,}" =~ ^(n|no)$ ]]; then
        # 禁用端口跳跃
        [ -n "$OLD_START" ] && [ -n "$OLD_END" ] && del_port_hopping_nat
        unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
        IS_HOPPING_SET=true
      elif [[ "$NEW_RANGE" =~ ^[0-9]{4,5}:[0-9]{4,5}$ ]]; then
        local NEW_START=${NEW_RANGE%:*} NEW_END=${NEW_RANGE#*:}
        if [[ "$NEW_START" -lt "$NEW_END" && "$NEW_START" -ge "$MIN_HOPPING_PORT" && "$NEW_END" -le "$MAX_HOPPING_PORT" ]]; then
          # 删除旧规则，添加新规则
          [ -n "$OLD_START" ] && [ -n "$OLD_END" ] && del_port_hopping_nat
          PORT_HOPPING_START=$NEW_START
          PORT_HOPPING_END=$NEW_END
          HY2_PORT_HOPPING_RANGE="$NEW_RANGE"
          local HOPPING_TARGET="$PORT_HOPPING_TARGET"
          [ -z "$HOPPING_TARGET" ] && HOPPING_TARGET=$(awk -F '[:,]' '/"listen_port"/{print $2; exit}' ${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json 2>/dev/null | tr -d ' ')
          # 静默添加端口跳跃规则，不显示 UFW 检测和成功提示
          (add_port_hopping_nat "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$HOPPING_TARGET") >/dev/null 2>&1
          IS_HOPPING_SET=true
        else
          warning "\n $(text 36) " && unset NEW_RANGE
        fi
      else
        warning "\n $(text 36) " && unset NEW_RANGE
      fi
    done

    export_list
    return
  elif [ "$KEY" = "fingerprint" ]; then
    local FP_CHOICE
    hint "\n $(text 169) \n"
    reading " $(text 24) " FP_CHOICE
    case "$FP_CHOICE" in
      ""|1 ) NEW_VAL="chrome" ;;
      2 ) NEW_VAL="firefox" ;;
      * ) NEW_VAL="$FP_CHOICE" ;;
    esac
    [[ ! "${NEW_VAL,,}" =~ ^[0-9a-z]+$ ]] && error " $(text 170) "
    FINGER_PRINT="$NEW_VAL"
    FINGER_PRINT_EXPLICIT=1
    export_list
    return
  fi

  hint ""
  [ -z "$NEW_VAL" ] && reading " $(text 134) " NEW_VAL
  [ -z "$NEW_VAL" ] && info " $(text 135) " && return

  # 各 key 的校验
  if [ "$KEY" = "uuid" ]; then
    [[ ! "${NEW_VAL,,}" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] && error " $(text 4) "
  elif [ "$KEY" = "sni" ]; then
    ssl_certificate "$NEW_VAL"
  elif [ "$KEY" = "serverip" ]; then
    [[ ! "$NEW_VAL" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [[ ! "$NEW_VAL" =~ ^[0-9a-fA-F:]+$ ]] && error " $(text 133) "
  fi

  # 批量替换，更换服务 IP 和导出指纹不需重启服务
  [[ ! "$KEY" =~ ^(fingerprint|serverip|cdn)$ ]] && hint " $(text 112) "

  if [[ "$KEY" =~ ^(serverip|cdn)$ ]]; then
    # IP 在配置里出现的形式有多种，逐一替换
    find ${WORK_DIR} -type f | xargs -P 50 sed -i \
      -e "s|\"server\": \"${OLD}\"|\"server\": \"${NEW_VAL}\"|g" \
      -e "s|WS_SERVER_IP_SHOW\": \"${OLD}\"|WS_SERVER_IP_SHOW\": \"${NEW_VAL}\"|g" \
      2>/dev/null
    # 同时更新 subscribe/list 等文本文件中可能出现的裸 IP
    find ${WORK_DIR}/subscribe -type f | xargs -P 50 sed -i "s|${OLD}|${NEW_VAL}|g" 2>/dev/null
  else
    find ${WORK_DIR} -type f | xargs -P 50 sed -i "s|${OLD}|${NEW_VAL}|g" 2>/dev/null
    if [[ ! "$KEY" =~ ^(fingerprint)$ ]]; then
      reload_service_or_warn Sing-box sing-box || true
    fi
  fi

  export_list
}

# 创建 Argo Tunnel API
create_argo_tunnel() {
  local CLOUDFLARE_API_TOKEN="$1"
  local ARGO_DOMAIN="$2"
  local SERVICE_PORT="$3"
  local TUNNEL_NAME=${ARGO_DOMAIN%%.*}
  local ROOT_DOMAIN=${ARGO_DOMAIN#*.}

  api_error() {
    local RESPONSE="$1"
    local CHECK_ZONE_ID="$2"

    if grep -q '"code":9109,' <<< "$RESPONSE"; then
      warning " $(text 122) " && sleep 2 && return 2
    elif grep -q '"code":7003,' <<< "$RESPONSE"; then
      warning " $(text 126) " && sleep 2 && return 3
    elif grep -q 'check_zone_id' <<< "$CHECK_ZONE_ID" && grep -q '"count":0,' <<< "$RESPONSE"; then
      warning " $(text 123) " && sleep 2 && return 4
    elif grep -q '"code":10000,' <<< "$RESPONSE"; then
      warning " $(text 124) " && sleep 2 && return 1
    elif grep -q '"success":true' <<< "$RESPONSE"; then
      return 0
    else
      warning " $(text 125) " && sleep 2 && return 5
    fi
  }

  # 步骤 1: 获取 Zone ID 和 Account ID
  local ZONE_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
    --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    --header="Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}")

  api_error "$ZONE_RESPONSE" 'check_zone_id' || return $?

  [[ "$ZONE_RESPONSE" =~ \"id\":\"([^\"]+)\".*\"account\":\{\"id\":\"([^\"]+)\" ]] && local ZONE_ID="${BASH_REMATCH[1]}" ACCOUNT_ID="${BASH_REMATCH[2]}" || \
  return 5

  # 步骤 2: 查询并处理现有 Tunnel
  local TUNNEL_LIST=$(wget --no-check-certificate -qO- --content-on-error \
    --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    --header="Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel?is_deleted=false")

  api_error "$TUNNEL_LIST" || return $?

  local TUNNEL_LIST_SPLIT=$(awk 'BEGIN{RS="";FS=""}{s=substr($0,index($0,"\"result\":[")+10);d=0;b="";for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c=="{")d++;if(d>0)b=b c;if(c=="}"){d--;if(d==0){print b;b=""}}}}' <<< "$TUNNEL_LIST")

  # 检查是否存在同名 Tunnel
  while true; do
    unset TUNNEL_CHECK EXISTING_TUNNEL_ID EXISTING_TUNNEL_STATUS
    local TUNNEL_CHECK=$(grep -F "\"name\":\"$TUNNEL_NAME\"" <<< "$TUNNEL_LIST_SPLIT")
    if [[ "$TUNNEL_CHECK" =~ \"id\":\"([^\"]+)\".*\"status\":\"([^\"]+)\" ]]; then
      local EXISTING_TUNNEL_ID=${BASH_REMATCH[1]} EXISTING_TUNNEL_STATUS=${BASH_REMATCH[2]}
      # 处理状态显示的本地化
      grep -qw 'C' <<< "$L" && EXISTING_TUNNEL_STATUS=$(sed 's/inactive/停用（未激活）/; s/down/离线/; s/healthy/连接中/; s/degraded/降级/ ' <<< "$EXISTING_TUNNEL_STATUS")
      reading "\n $(text 120) " OVERWRITE
      if grep -qw 'n' <<< "${OVERWRITE,,}"; then
        # 询问用户输入另一个域名前缀
        unset ARGO_DOMAIN
        reading "\n $(text 87) " ARGO_DOMAIN

        # 用户直接回车，使用临时域名，退出当前流程
        ! grep -q '[.]' <<< "$ARGO_DOMAIN" && return 5

        # 更新TUNNEL_NAME和ROOT_DOMAIN，循环会自动检查新名称
        TUNNEL_NAME=${ARGO_DOMAIN%%.*}
        ROOT_DOMAIN=${ARGO_DOMAIN#*.}
      else
        # 用户选择覆盖，则跳出循环继续执行创建流程
        break
      fi
    else
      # 如果新域名不存在，则跳出循环继续执行创建流程
      unset TUNNEL_CHECK EXISTING_TUNNEL_ID EXISTING_TUNNEL_STATUS
      break
    fi
  done

  # 如果同名 Tunnel 不存在，则先创建
  if grep -q '^$' <<< "$EXISTING_TUNNEL_ID"; then
    # 生成 Tunnel Secret (至少 32 字节的 base64 编码)
    local TUNNEL_SECRET=$(openssl rand -base64 32)

    # 创建新 Tunnel
    local CREATE_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
      --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header="Content-Type: application/json" \
      --post-data="{
        \"name\": \"$TUNNEL_NAME\",
        \"config_src\": \"cloudflare\",
        \"tunnel_secret\": \"$TUNNEL_SECRET\"
      }" \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel")

    api_error "$CREATE_RESPONSE" || return $?

    [[ $CREATE_RESPONSE =~ \"id\":\"([^\"]+)\".*\"token\":\"([^\"]+)\" ]] && \
    local TUNNEL_ID=${BASH_REMATCH[1]} TUNNEL_TOKEN=${BASH_REMATCH[2]} || \
    return 5
  else
    # 如果有同名 Tunnel (EXISTING_TUNNEL_ID 非空），则获取其 TOKEN
    local EXISTING_TUNNEL_TOKEN=$(wget -qO- --content-on-error \
      --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header="Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${EXISTING_TUNNEL_ID}/token")

    api_error "$EXISTING_TUNNEL_TOKEN" || return $?

    local TUNNEL_ID=$EXISTING_TUNNEL_ID \
    TUNNEL_TOKEN=$(sed -n 's/.*"result":"\([^"]\+\)".*/\1/p' <<< "$EXISTING_TUNNEL_TOKEN") && \
    TUNNEL_SECRET=$(base64 -d <<< "$TUNNEL_TOKEN" | sed 's/.*"s":"\([^"]\+\)".*/\1/') || \
    return 5
  fi

  # 步骤 3: 配置 Tunnel ingress 规则... 不管原来的规则，一率覆盖处理
 local CONFIG_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
  --method=PUT \
  --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  --header="Content-Type: application/json" \
  --body-data="{
    \"config\": {
      \"ingress\": [
        {
          \"service\": \"http://localhost:${SERVICE_PORT}\",
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

  api_error "$CONFIG_RESPONSE" || return $?

  # 步骤 4: 管理 DNS 记录
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
    --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    --header="Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME&name=${ARGO_DOMAIN}")

  api_error "$DNS_LIST" || return $?

  # 如果已存在需要的 DNS 记录，就跳过
  if [[ "$DNS_LIST" =~ \"id\":\"([^\"]+)\".*\"$ARGO_DOMAIN\".*\"content\":\"([^\"]+)\" ]]; then
    local EXISTING_DNS_ID="${BASH_REMATCH[1]}" EXISTED_DNS_CONTENT="${BASH_REMATCH[2]}"

    # DNS 记录与隧道 ID 不匹配的话，覆盖原来的 CNAME 记录
    if ! grep -qw "$EXISTING_TUNNEL_ID" <<< "${EXISTED_DNS_CONTENT%%.*}"; then
      local DNS_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
        --method=PATCH \
        --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        --header="Content-Type: application/json" \
        --body-data="$DNS_PAYLOAD" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXISTING_DNS_ID}")

      api_error "$DNS_RESPONSE" || return $?
    fi
  else
    # 未找到现有 DNS 记录，使用 POST 创建
    local DNS_RESPONSE=$(wget --no-check-certificate -qO- --content-on-error \
      --method=POST \
      --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header="Content-Type: application/json" \
      --body-data="$DNS_PAYLOAD" \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records")

    api_error "$DNS_RESPONSE" || return $?
  fi

  # 返回 Argo Tunnel Token 或者 Json
  ARGO_JSON="{\"AccountTag\":\"$ACCOUNT_ID\",\"TunnelSecret\":\"$TUNNEL_SECRET\",\"TunnelID\":\"$TUNNEL_ID\",\"Endpoint\":\"\"}"
  ARGO_TOKEN="$TUNNEL_TOKEN"
}

# 输入 Nginx 服务端口
input_nginx_port() {
  local NUM=$1
  local PORT_ERROR_TIME=6
  # 生成 1000 - 65535 随机默认端口数
  local PORT_NGINX_DEFAULT=$(shuf -i ${MIN_PORT}-${MAX_PORT} -n 1)
  [[ "$IS_FAST_INSTALL" = 'is_fast_install' && -z "$PORT_NGINX" ]] && PORT_NGINX="$PORT_NGINX_DEFAULT"
  while true; do
    [[ "$PORT_ERROR_TIME" -gt 1 && "$PORT_ERROR_TIME" -lt 6 ]] && unset IN_USED PORT_NGINX
    (( PORT_ERROR_TIME-- )) || true
    if [ "$PORT_ERROR_TIME" = 0 ]; then
      error "\n $(text 3) \n"
    else
      [ -z "$PORT_NGINX" ] && reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 79) " PORT_NGINX
    fi
    PORT_NGINX=${PORT_NGINX:-"$PORT_NGINX_DEFAULT"}
    if [[ "$PORT_NGINX" =~ ^[1-9][0-9]{1,4}$ && "$PORT_NGINX" -ge "$MIN_PORT" && "$PORT_NGINX" -le "$MAX_PORT" ]]; then
      if protocol_port_in_use "$PORT_NGINX"; then
        [[ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' || "$IS_FAST_INSTALL" = 'is_fast_install' ]] && error " PORT_NGINX conflicts with a selected protocol port. "
        warning "\n $(text 44) \n"
      elif ss -nltup | grep -q ":$PORT_NGINX"; then
        if [ "$CONFIG_UPDATE_INSTALL" = 'config_update_install' ] && [ -s "${WORK_DIR}/nginx.conf" ] && [ "$PORT_NGINX" = "$(awk '/listen/{print $2; exit}' "${WORK_DIR}/nginx.conf")" ]; then
          break
        fi
        [[ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' || "$IS_FAST_INSTALL" = 'is_fast_install' ]] && error " PORT_NGINX is already in use. "
        warning "\n $(text 44) \n"
      else
        break
      fi
    fi
  done
}

# 输入 hysteria2 跳跃端口
input_hopping_port() {
  local HOPPING_ERROR_TIME=6

  # 参数 / 快速安装模式：不交互。未指定端口跳跃时默认禁用。
  if [[ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' || "$IS_FAST_INSTALL" = 'is_fast_install' ]]; then
    HY2_PORT_HOPPING_RANGE=$(sed 's/[-－—：]/:/g' <<< "$HY2_PORT_HOPPING_RANGE" | tr -cd '0-9:')
    if [[ "$HY2_PORT_HOPPING_RANGE" =~ ^[0-9]{4,5}:[0-9]{4,5}$ ]]; then
      PORT_HOPPING_START=${HY2_PORT_HOPPING_RANGE%:*}
      PORT_HOPPING_END=${HY2_PORT_HOPPING_RANGE#*:}
      if [[ "$PORT_HOPPING_START" -lt "$PORT_HOPPING_END" && "$PORT_HOPPING_START" -ge "$MIN_HOPPING_PORT" && "$PORT_HOPPING_END" -le "$MAX_HOPPING_PORT" ]]; then
        IS_HOPPING=is_hopping
      else
        unset HY2_PORT_HOPPING_RANGE PORT_HOPPING_START PORT_HOPPING_END
        IS_HOPPING=no_hopping
      fi
    else
      unset HY2_PORT_HOPPING_RANGE PORT_HOPPING_START PORT_HOPPING_END
      IS_HOPPING=no_hopping
    fi
    return
  fi

  until [ -n "$IS_HOPPING" ]; do
    if [ -z "$HY2_PORT_HOPPING_RANGE" ]; then
      (( HOPPING_ERROR_TIME-- )) || true
      case "$HOPPING_ERROR_TIME" in
        0 )
          error "\n $(text 3) \n"
          ;;
        5 )
          hint "\n $(text 97) \n" && reading " ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 98) " HY2_PORT_HOPPING_RANGE
          ;;
        * )
          reading " ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 98) " HY2_PORT_HOPPING_RANGE
      esac
    fi

    # 预处理：全角冒号/破折号统一换半角，过滤非法字符
    HY2_PORT_HOPPING_RANGE=$(sed 's/[-－—：]/:/g' <<< "$HY2_PORT_HOPPING_RANGE" | tr -cd '0-9:')

    if [[ "$HY2_PORT_HOPPING_RANGE" =~ ^[0-9]{4,5}:[0-9]{4,5}$ ]]; then
      PORT_HOPPING_START=${HY2_PORT_HOPPING_RANGE%:*}
      PORT_HOPPING_END=${HY2_PORT_HOPPING_RANGE#*:}
      if [[ "$PORT_HOPPING_START" -lt "$PORT_HOPPING_END" && \
            "$PORT_HOPPING_START" -ge "$MIN_HOPPING_PORT" && \
            "$PORT_HOPPING_END" -le "$MAX_HOPPING_PORT" ]]; then
        IS_HOPPING=is_hopping
      else
        warning "\n $(text 114) " && unset HY2_PORT_HOPPING_RANGE
      fi
    elif [[ -z "$HY2_PORT_HOPPING_RANGE" || "${HY2_PORT_HOPPING_RANGE,,}" =~ ^(n|no)$ ]]; then
      IS_HOPPING=no_hopping
    else
      warning "\n $(text 36) " && unset HY2_PORT_HOPPING_RANGE
    fi
  done
}


# 输入 Hysteria2 Realm 选项
input_hy2_realm() {
  HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]:-${UUID_CONFIRM}}}"

  # 参数 / 快速安装模式：不交互，尊重 --HY2_REALM。
  if [[ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' || "$IS_FAST_INSTALL" = 'is_fast_install' ]]; then
    if [ "$IS_HY2_REALM" = 'is_hy2_realm' ]; then
      HY2_REALM_ID="${HY2_REALM_ID:-${UUID_CONFIRM}}"
    else
      unset IS_HY2_REALM HY2_REALM_ID
    fi
    return
  fi

  unset IS_HY2_REALM
  local CHOOSE_REALM
  reading "\n $(text 147) " CHOOSE_REALM
  if [[ "${CHOOSE_REALM,,}" =~ ^(y|yes)$ ]]; then
    IS_HY2_REALM=is_hy2_realm
    HY2_REALM_ID="${HY2_REALM_ID:-${UUID_CONFIRM}}"
  fi
}

# jq 入口，优先使用脚本自带 jq
jq_exec() {
  if [ -x "${WORK_DIR}/jq" ]; then
    "${WORK_DIR}/jq" "$@"
  elif [ -x "${TEMP_DIR}/jq" ]; then
    "${TEMP_DIR}/jq" "$@"
  else
    jq "$@"
  fi
}

# ===================== 自定义出站与路由发布 =====================

routing_default_outbounds() {
  cat << 'EOF'
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

routing_default_route() {
  cat << 'EOF'
{
  "route": {
    "default_http_client": "http-client-direct",
    "rule_set": [
      {
        "tag": "geosite-google",
        "type": "remote",
        "format": "binary",
        "url": "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/google.srs"
      },
      {
        "tag": "geosite-openai",
        "type": "remote",
        "format": "binary",
        "url": "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/openai.srs"
      }
    ],
    "rules": [
      {
        "action": "sniff"
      },
      {
        "action": "resolve",
        "domain": [
          "api.openai.com"
        ],
        "strategy": "prefer_ipv4"
      },
      {
        "action": "resolve",
        "rule_set": [
          "geosite-openai"
        ],
        "strategy": "prefer_ipv6"
      },
      {
        "action": "resolve",
        "rule_set": [
          "geosite-google"
        ],
        "strategy": "prefer_ipv6"
      },
      {
        "domain": [
          "api.openai.com"
        ],
        "rule_set": [
          "geosite-openai"
        ],
        "action": "route",
        "outbound": "direct"
      },
      {
        "rule_set": [
          "geosite-google"
        ],
        "action": "route",
        "outbound": "direct"
      }
    ]
  }
}
EOF
}

routing_remove_legacy_warp() {
  local ROUTE_FILE="${CUSTOM_DIR}/03_route.json"
  local TMP_FILE="${ROUTE_FILE}.tmp.$$"
  local LEGACY_COUNT
  [ -s "$ROUTE_FILE" ] || return 0

  LEGACY_COUNT=$(jq_exec '[.route.rules[]? | select(.outbound? == "warp-ep")] | length' "$ROUTE_FILE") || return 1
  [ "$LEGACY_COUNT" -gt 0 ] || return 0

  jq_exec '
    .route.rules |= map(select(.outbound? != "warp-ep")) |
    ([.route.rules[]? | .rule_set[]?] | unique) as $used |
    .route.rule_set = [(.route.rule_set // [])[] | select(.tag as $tag | $used | index($tag) != null)]
  ' "$ROUTE_FILE" > "$TMP_FILE" || { rm -f "$TMP_FILE"; return 1; }
  mv "$TMP_FILE" "$ROUTE_FILE"
}

routing_migrate_legacy() {
  local ROUTE_FILE="${CUSTOM_DIR}/03_route.json"
  local OUTBOUNDS_FILE="${CUSTOM_DIR}/04_outbounds.json"
  local LEGACY_ROUTE="${WORK_DIR}/conf/03_route.json"
  local LEGACY_OUTBOUNDS="${WORK_DIR}/conf/01_outbounds.json"
  local LEGACY_CUSTOM="${WORK_DIR}/conf/08_custom_route.json"
  local PUBLISHED="${WORK_DIR}/conf/03_routing.json"
  local TMP_FILE

  mkdir -p "$CUSTOM_DIR" "$STATE_DIR"

  if [ ! -e "$OUTBOUNDS_FILE" ]; then
    TMP_FILE="${OUTBOUNDS_FILE}.tmp.$$"
    if [ -s "$PUBLISHED" ] && jq_exec -e '.outbounds | type == "array"' "$PUBLISHED" >/dev/null 2>&1; then
      jq_exec '{outbounds:.outbounds}' "$PUBLISHED" > "$TMP_FILE"
    elif [ -s "$LEGACY_OUTBOUNDS" ] && jq_exec -e '.outbounds | type == "array"' "$LEGACY_OUTBOUNDS" >/dev/null 2>&1; then
      jq_exec '{outbounds:.outbounds}' "$LEGACY_OUTBOUNDS" > "$TMP_FILE"
    elif [ -s "$PUBLISHED" ] || [ -s "$LEGACY_OUTBOUNDS" ]; then
      printf 'Unable to migrate invalid outbound configuration.\n' >&2
      rm -f "$TMP_FILE"
      return 1
    else
      routing_default_outbounds > "$TMP_FILE"
    fi
    mv "$TMP_FILE" "$OUTBOUNDS_FILE"
  fi

  if [ ! -e "$ROUTE_FILE" ]; then
    TMP_FILE="${ROUTE_FILE}.tmp.$$"
    if [ -s "$PUBLISHED" ] && jq_exec -e '.route | type == "object"' "$PUBLISHED" >/dev/null 2>&1; then
      jq_exec '{route:.route}' "$PUBLISHED" > "$TMP_FILE"
    elif [ -s "$LEGACY_ROUTE" ] && jq_exec -e '.route | type == "object"' "$LEGACY_ROUTE" >/dev/null 2>&1; then
      jq_exec '{route:.route}' "$LEGACY_ROUTE" > "$TMP_FILE"
    elif [ -s "$PUBLISHED" ] || [ -s "$LEGACY_ROUTE" ]; then
      printf 'Unable to migrate invalid routing configuration.\n' >&2
      rm -f "$TMP_FILE"
      return 1
    else
      routing_default_route > "$TMP_FILE"
    fi

    if [ -s "$LEGACY_CUSTOM" ] && jq_exec -e '.route | type == "object"' "$LEGACY_CUSTOM" >/dev/null 2>&1; then
      if ! jq_exec -s '
        .[0] as $base | .[1] as $extra |
        $base |
        .route.rule_set = reduce ((($base.route.rule_set // []) + ($extra.route.rule_set // []))[]) as $item
          ([]; if any(.[]; .tag == $item.tag) then . else . + [$item] end) |
        .route.rules = (($base.route.rules // []) + ($extra.route.rules // []))
      ' "$TMP_FILE" "$LEGACY_CUSTOM" > "${TMP_FILE}.merged"; then
        printf 'Unable to merge legacy custom routing configuration: %s\n' "$LEGACY_CUSTOM" >&2
        rm -f "$TMP_FILE" "${TMP_FILE}.merged"
        return 1
      fi
      mv "${TMP_FILE}.merged" "$TMP_FILE"
    elif [ -s "$LEGACY_CUSTOM" ]; then
      printf 'Unable to migrate invalid custom routing configuration: %s\n' "$LEGACY_CUSTOM" >&2
      rm -f "$TMP_FILE"
      return 1
    fi
    if ! jq_exec '
      .route.rule_set = (.route.rule_set // []) |
      if any(.route.rule_set[]; .tag == "geosite-google") then . else
        .route.rule_set += [{
          tag:"geosite-google",
          type:"remote",
          format:"binary",
          url:"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/google.srs"
        }]
      end |
      .route.rules = (.route.rules // []) |
      .route.rules |= map(
        if .outbound? == "warp-ep" and
           (.domain? // []) == ["api.openai.com"] and
           (.rule_set? // []) == ["geosite-openai"] and
           ((keys_unsorted - ["action", "domain", "outbound", "rule_set"]) | length) == 0 then
          .outbound = "direct" | .action = "route"
        elif .outbound? == "direct" and
             (.rule_set? // []) == ["geosite-google", "geosite-openai"] and
             ((keys_unsorted - ["action", "outbound", "rule_set"]) | length) == 0 then
          .rule_set = ["geosite-openai"] | .domain = ["api.openai.com"] | .action = "route"
        else . end
      ) |
      if any(.route.rules[]; .action? == "resolve" and (.rule_set? // []) == ["geosite-google"]) then . else
        (.route.rules | map(.outbound? != null) | index(true)) as $idx |
        ({action:"resolve", rule_set:["geosite-google"], strategy:"prefer_ipv6"}) as $rule |
        .route.rules = if $idx == null then .route.rules + [$rule] else .route.rules[0:$idx] + [$rule] + .route.rules[$idx:] end
      end |
      if any(.route.rules[]; .outbound? == "direct" and (.rule_set? // []) == ["geosite-google"]) then . else
        .route.rules += [{rule_set:["geosite-google"], action:"route", outbound:"direct"}]
      end
    ' "$TMP_FILE" > "${TMP_FILE}.defaults"; then
      printf 'Unable to update migrated default routing rules.\n' >&2
      rm -f "$TMP_FILE" "${TMP_FILE}.defaults"
      return 1
    fi
    mv "${TMP_FILE}.defaults" "$TMP_FILE"
    if ! jq_exec '
      .route.rules |= map(
        if .outbound? != null and .action? == null then . + {action:"route"} else . end
      )
    ' "$TMP_FILE" > "${TMP_FILE}.normalized"; then
      printf 'Unable to normalize migrated routing configuration.\n' >&2
      rm -f "$TMP_FILE" "${TMP_FILE}.normalized"
      return 1
    fi
    mv "${TMP_FILE}.normalized" "$TMP_FILE"
    mv "$TMP_FILE" "$ROUTE_FILE"
  fi
  routing_remove_legacy_warp
}

routing_validate_sources() {
  local ROUTE_FILE="${CUSTOM_DIR}/03_route.json"
  local OUTBOUNDS_FILE="${CUSTOM_DIR}/04_outbounds.json"

  [ -s "$ROUTE_FILE" ] || { printf 'Missing routing source: %s\n' "$ROUTE_FILE" >&2; return 1; }
  [ -s "$OUTBOUNDS_FILE" ] || { printf 'Missing outbound source: %s\n' "$OUTBOUNDS_FILE" >&2; return 1; }
  jq_exec -e '.route | type == "object"' "$ROUTE_FILE" >/dev/null || {
    printf 'Invalid routing source: %s\n' "$ROUTE_FILE" >&2
    return 1
  }
  jq_exec -e '.outbounds | type == "array" and length > 0' "$OUTBOUNDS_FILE" >/dev/null || {
    printf 'Invalid outbound source: %s\n' "$OUTBOUNDS_FILE" >&2
    return 1
  }
}

routing_prepare_candidate() {
  local CANDIDATE_DIR=$1 FILE BASENAME
  routing_validate_sources || return 1
  mkdir -p "$CANDIDATE_DIR"

  for FILE in "${WORK_DIR}"/conf/*.json; do
    [ -e "$FILE" ] || continue
    BASENAME=${FILE##*/}
    case "$BASENAME" in
      01_outbounds.json|02_endpoints.json|03_route.json|03_routing.json|08_custom_route.json ) continue ;;
    esac
    cp "$FILE" "$CANDIDATE_DIR/$BASENAME" || return 1
  done

  jq_exec -s '.[0] * .[1]' \
    "${CUSTOM_DIR}/04_outbounds.json" \
    "${CUSTOM_DIR}/03_route.json" > "${CANDIDATE_DIR}/03_routing.json"
}

routing_validate_candidate() {
  local CANDIDATE_DIR=$1
  [ -x "${WORK_DIR}/sing-box" ] || {
    printf 'Sing-box binary not found: %s\n' "${WORK_DIR}/sing-box" >&2
    return 1
  }
  routing_validate_outbound_references "$CANDIDATE_DIR" || return 1
  "${WORK_DIR}/sing-box" check -C "$CANDIDATE_DIR"
}

routing_validate_outbound_references() {
  local CANDIDATE_DIR=$1 ROUTING_FILE MISSING_TAGS
  ROUTING_FILE="${CANDIDATE_DIR}/03_routing.json"
  [ -s "$ROUTING_FILE" ] || {
    printf 'Candidate routing configuration not found: %s\n' "$ROUTING_FILE" >&2
    return 1
  }

  MISSING_TAGS=$(jq_exec -r '
    (
      [.outbounds[]?.tag?, .endpoints[]?.tag?] |
      map(select(type == "string" and length > 0)) |
      unique
    ) as $defined |
    (
      [
        .route.rules[]? |
        .. |
        objects |
        .outbound? |
        select(type == "string")
      ] + [
        .route.final? |
        select(type == "string")
      ]
    ) |
    unique |
    map(select(. as $tag | ($defined | index($tag) | not))) |
    map(if length == 0 then "<empty>" else . end) |
    join(", ")
  ' "$ROUTING_FILE") || return 1

  [ -z "$MISSING_TAGS" ] || {
    printf 'Undefined route outbound/endpoint tag(s): %s\n' "$MISSING_TAGS" >&2
    return 1
  }
}

routing_check() {
  local CANDIDATE_DIR RC
  CANDIDATE_DIR=$(mktemp -d "${TEMP_DIR}/routing-check.XXXXXX") || return 1
  routing_prepare_candidate "$CANDIDATE_DIR" && routing_validate_candidate "$CANDIDATE_DIR"
  RC=$?
  rm -rf "$CANDIDATE_DIR"
  return "$RC"
}

routing_write_state() {
  local ROUTE_HASH OUTBOUNDS_HASH
  command -v sha256sum >/dev/null 2>&1 || return 0
  ROUTE_HASH=$(sha256sum "${CUSTOM_DIR}/03_route.json" | awk '{print $1}')
  OUTBOUNDS_HASH=$(sha256sum "${CUSTOM_DIR}/04_outbounds.json" | awk '{print $1}')
  jq_exec -n \
    --arg schema "1" \
    --arg route "$ROUTE_HASH" \
    --arg outbounds "$OUTBOUNDS_HASH" \
    --arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:($schema|tonumber),route_sha256:$route,outbounds_sha256:$outbounds,published_at:$published}' \
    > "${STATE_DIR}/routing.json.tmp.$$" &&
    mv "${STATE_DIR}/routing.json.tmp.$$" "${STATE_DIR}/routing.json"
}

routing_publish() (
  local LOCK_DIR="${STATE_DIR}/routing.lock"
  local CANDIDATE_DIR='' RUNTIME_TMP='' RC=1 WAIT_COUNT=0
  mkdir -p "$STATE_DIR"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    WAIT_COUNT=$((WAIT_COUNT + 1))
    [ "$WAIT_COUNT" -lt 50 ] || { printf 'Routing publish is locked: %s\n' "$LOCK_DIR" >&2; return 1; }
    sleep 0.1
  done
  RUNTIME_TMP="${WORK_DIR}/conf/03_routing.json.tmp.$$"
  trap 'rm -rf "$CANDIDATE_DIR" "$LOCK_DIR"; rm -f "$RUNTIME_TMP"' EXIT

  CANDIDATE_DIR=$(mktemp -d "${TEMP_DIR}/routing-publish.XXXXXX") || return 1
  if routing_prepare_candidate "$CANDIDATE_DIR" && routing_validate_candidate "$CANDIDATE_DIR"; then
    cp "${CANDIDATE_DIR}/03_routing.json" "$RUNTIME_TMP" &&
      mv "$RUNTIME_TMP" "${WORK_DIR}/conf/03_routing.json" &&
      rm -f "${WORK_DIR}/conf/01_outbounds.json" "${WORK_DIR}/conf/02_endpoints.json" "${WORK_DIR}/conf/03_route.json" "${WORK_DIR}/conf/08_custom_route.json" &&
      { routing_write_state || true; }
    RC=$?
  fi
  return "$RC"
)

routing_reload() {
  cmd_systemctl reload sing-box
}

# 更新 Hysteria2 服务端 Realm 模块
set_hy2_realm_config() {
  local ACTION=$1
  local HY2_CONF
  HY2_CONF=$(ls ${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json 2>/dev/null | sed -n '1p') || true
  [ -z "$HY2_CONF" ] && return
  local TMP_FILE="${HY2_CONF}.tmp"
  HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]:-${UUID_CONFIRM}}}"

  if [ "$ACTION" = 'enable' ]; then
    jq_exec --arg rid "$HY2_REALM_ID" '.inbounds |= map(if .type == "hysteria2" then .realm = {"server_url":"https://realm.hy2.io","token":"public","realm_id":$rid,"stun_servers":["turn.cloudflare.com:3478","stun.nextcloud.com:3478","stun.sip.us:3478","global.stun.twilio.com:3478"]} else . end)' "$HY2_CONF" > "$TMP_FILE" && mv "$TMP_FILE" "$HY2_CONF"
    IS_HY2_REALM=is_hy2_realm
  else
    jq_exec '.inbounds |= map(if .type == "hysteria2" then del(.realm) else . end)' "$HY2_CONF" > "$TMP_FILE" && mv "$TMP_FILE" "$HY2_CONF"
    unset IS_HY2_REALM HY2_REALM_ID
  fi
}


# 输入 Reality 密钥
input_reality_key() {
  [[ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' && "$IS_FAST_INSTALL" != 'is_fast_install' ]] && [ -z "$REALITY_PRIVATE" ] && reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 70) " REALITY_PRIVATE
  [ -z "$REALITY_PRIVATE" ] && unset REALITY_PRIVATE && return

  local PRIVATEKEY_ERROR_TIME=5
  until valid_reality_private_format "$REALITY_PRIVATE" || [ -z "$REALITY_PRIVATE" ]; do
    (( PRIVATEKEY_ERROR_TIME-- )) || true
    [ "$PRIVATEKEY_ERROR_TIME" = 0 ] && unset REALITY_PRIVATE && hint "\n $(text 113) \n" && break
    warning "\n $(text 114) "
    reading "\n $(text 70) " REALITY_PRIVATE
    # 即使 REALITY_PRIVATE 为空值，但 REALITY_PRIVATE 数组数量 ${REALITY_PRIVATE[@]} 为 1，影响后续的处理，所以要置空
    [ -z "$REALITY_PRIVATE" ] && unset REALITY_PRIVATE && break
  done
}

# 输入 Argo 域名和认证信息
input_argo_auth() {
  local IS_CHANGE_ARGO=$1
  [ -n "$IS_CHANGE_ARGO" ] && local EMPTY_ERROR_TIME=5
  local DOMAIN_ERROR_TIME=6

  # 处理可能输入的错误，去掉开头和结尾的空格，去掉最后的 :
  if [ "$IS_CHANGE_ARGO" = 'is_change_argo' ]; then
    until [ -n "$ARGO_DOMAIN" ]; do
      (( EMPTY_ERROR_TIME-- )) || true
      [ "$EMPTY_ERROR_TIME" = 0 ] && error "\n $(text 3) \n"
      reading "\n $(text 88) " ARGO_DOMAIN
      [ -n "$IS_CHANGE_ARGO" ] && ARGO_DOMAIN=$(sed 's/[ ]*//g; s/:[ ]*//' <<< "$ARGO_DOMAIN")
    done
  elif [[ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' && "$IS_FAST_INSTALL" != 'is_fast_install' ]]; then
    [ -z "$ARGO_DOMAIN" ] && reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 87) " ARGO_DOMAIN
    ARGO_DOMAIN=$(sed 's/[ ]*//g; s/:[ ]*//' <<< "$ARGO_DOMAIN")
  fi

  if [[ ( -z "$ARGO_DOMAIN" || "$ARGO_DOMAIN" =~ trycloudflare\.com$ ) && ( "$IS_CHANGE_ARGO" = 'is_add_protocols' || "$IS_CHANGE_ARGO" = 'is_install' || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ) ]]; then
    ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --no-autoupdate --url http://localhost:$PORT_NGINX"
  elif [ -n "${ARGO_DOMAIN}" ]; then
    if [ -z "${ARGO_AUTH}" ]; then
      until [[ "$ARGO_AUTH" =~ TunnelSecret || "$ARGO_AUTH" =~ [A-Z0-9a-z=]{120,250}$ || "${#ARGO_AUTH}" =~ ^[3-6][0-9]$ ]]; do
        [ "$DOMAIN_ERROR_TIME" != 6 ] && warning "\n $(text 86) \n"
      (( DOMAIN_ERROR_TIME-- )) || true
        [ "$DOMAIN_ERROR_TIME" != 0 ] && hint "\n $(text 85) \n " && reading "\n $(text 118) " ARGO_AUTH || error "\n $(text 3) \n"
      done
    fi

    # 根据 ARGO_AUTH 的内容，自行判断是 Json， Token 还是 API 申请
    if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
      ARGO_TYPE=is_json_argo
      ARGO_JSON=${ARGO_AUTH//[ ]/}
      [ "$IS_CHANGE_ARGO" = 'is_install' ] && export_argo_json_file $TEMP_DIR || export_argo_json_file ${WORK_DIR}
      ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --config ${WORK_DIR}/tunnel.yml run"
    elif [[ "${ARGO_AUTH}" =~ [A-Z0-9a-z=]{120,250}$ ]]; then
      ARGO_TYPE=is_token_argo
      ARGO_TOKEN=$(awk '{print $NF}' <<< "$ARGO_AUTH")
      ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}"
    elif [[ "${#ARGO_AUTH}" =~ ^[3-6][0-9]$ ]]; then
      hint "\n $(text 119) \n "
      create_argo_tunnel "${ARGO_AUTH}" "${ARGO_DOMAIN}" "${PORT_NGINX}"
      if [[ "$ARGO_JSON" =~ TunnelSecret ]]; then
        ARGO_TYPE=is_json_argo
        [ "$IS_CHANGE_ARGO" = 'is_install' ] && export_argo_json_file $TEMP_DIR || export_argo_json_file ${WORK_DIR}
        ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --config ${WORK_DIR}/tunnel.yml run"
      elif [[ "${#ARGO_TOKEN}" =~ ^[0-9]+$ && "${#ARGO_TOKEN}" -ge 120 && "${#ARGO_TOKEN}" -le 250 ]]; then
        ARGO_TYPE=is_token_argo
        ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}"
      else
        # 创建隧道失败，回退到使用临时隧道
        hint "\n $(text 117) \n "
        unset ARGO_DOMAIN
        ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --no-autoupdate --url http://localhost:$PORT_NGINX"
      fi
    fi
  fi
}

# 更换 Argo 隧道类型
change_argo() {
  check_install
  if [ "${STATUS[0]}" =  "$(text 26)" ]; then
    error "\n $(text 39) "
  elif [ "${STATUS[1]}" = "$(text 26)" ]; then
    error "\n $(text 61) "
  fi

  # 根据系统类型检查 Argo 服务配置
  local ARGO_CONFIG=$(grep -E '^(command_args=|ExecStart=)' ${ARGO_DAEMON_FILE})

  case "$ARGO_CONFIG" in
    *--config* )
      ARGO_TYPE='Json'
      ;;
    *--token* )
      ARGO_TYPE='Token'
      ;;
    * )
      ARGO_TYPE='Try'
      cmd_systemctl enable argo || service_action_failed Argo argo enable
      sleep 2
      cmd_systemctl status argo &>/dev/null && fetch_quicktunnel_domain || service_action_failed Argo argo enable
  esac

  fetch_nodes_value
  hint "\n $(text 90) \n"
  unset ARGO_DOMAIN
  hint " $(text 91) \n" && reading " $(text 24) " CHANGE_TO

  case "$CHANGE_TO" in
    1 )
      cmd_systemctl disable argo || service_action_failed Argo argo disable
      [ -s ${WORK_DIR}/tunnel.json ] && rm -f ${WORK_DIR}/tunnel.{json,yml}

      # 根据系统类型修改配置文件
      [ "$SYSTEM" = 'Alpine' ] && sed -i "s@^command_args=.*@command_args=\"--edge-ip-version auto --no-autoupdate --url http://localhost:$PORT_NGINX\"@g" ${ARGO_DAEMON_FILE} || sed -i "s@ExecStart=.*@ExecStart=${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --no-autoupdate --url http://localhost:$PORT_NGINX@g" ${ARGO_DAEMON_FILE}
      ;;
    2 )
      [ -s ${WORK_DIR}/tunnel.json ] && rm -f ${WORK_DIR}/tunnel.{json,yml}
      input_argo_auth is_change_argo
      cmd_systemctl disable argo || service_action_failed Argo argo disable

      if [ -n "$ARGO_TOKEN" ]; then
        [ "$SYSTEM" = 'Alpine' ] && sed -i "s@^command_args=.*@command_args=\"--edge-ip-version auto run --token ${ARGO_TOKEN}\"@g" ${ARGO_DAEMON_FILE} || sed -i "s@ExecStart=.*@ExecStart=${WORK_DIR}/cloudflared tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}@g" ${ARGO_DAEMON_FILE}
      elif [ -n "$ARGO_JSON" ]; then
        [ "$SYSTEM" = 'Alpine' ] && sed -i "s@^command_args=.*@command_args=\"--edge-ip-version auto --config ${WORK_DIR}/tunnel.yml run\"@g" ${ARGO_DAEMON_FILE} || sed -i "s@ExecStart=.*@ExecStart=${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --config ${WORK_DIR}/tunnel.yml run@g" ${ARGO_DAEMON_FILE}
      fi

      # 更新相关配置文件中的域名
      [ -s ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json ] && sed -i "s/VMESS_HOST_DOMAIN.*/VMESS_HOST_DOMAIN\": \"$ARGO_DOMAIN\"/" ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json
      [ -s ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json ] && sed -i "s/\"server_name\":.*/\"server_name\": \"$ARGO_DOMAIN\",/" ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json
      ;;
    * )
      exit 0
  esac

  # 启用 Argo 服务
  cmd_systemctl enable argo || service_action_failed Argo argo enable
  sleep 2
  cmd_systemctl status argo &>/dev/null || service_action_failed Argo argo enable

  # 更新节点信息和配置
  fetch_nodes_value
  export_nginx_conf_file
  export_list
}
