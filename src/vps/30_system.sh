check_root() {
  [ "$(id -u)" != 0 ] && error "\n $(text 43) \n"
}

# 判断处理器架构
check_arch() {
  [ "$SYSTEM" = 'Alpine' ] && local IS_MUSL='-musl'

  case "$(uname -m)" in
    aarch64|arm64 )
      SING_BOX_ARCH=arm64${IS_MUSL}; JQ_ARCH=arm64; QRENCODE_ARCH=arm64; ARGO_ARCH=arm64
      ;;
    x86_64|amd64 )
      SING_BOX_ARCH=amd64${IS_MUSL}; JQ_ARCH=amd64; QRENCODE_ARCH=amd64; ARGO_ARCH=amd64
      ;;
    armv7l )
      SING_BOX_ARCH=armv7${IS_MUSL}; JQ_ARCH=armhf; QRENCODE_ARCH=arm; ARGO_ARCH=arm
      ;;
    * )
      error " $(text 25) "
  esac
}

# 检查系统是否已经安装 tcp-brutal
check_brutal() {
  IS_BRUTAL=false && command -v lsmod >/dev/null 2>&1 && lsmod 2>/dev/null | grep -q 'brutal' && IS_BRUTAL=true
  [ "$IS_BRUTAL" = 'false' ] && command -v modprobe >/dev/null 2>&1 && modprobe brutal 2>/dev/null && IS_BRUTAL=true
}

download_file() {
  local URL=$1
  local OUTPUT=$2
  local DIRECT_URL=${3:-$URL}

  rm -f "$OUTPUT"
  wget --no-check-certificate --continue -qO "$OUTPUT" "$URL" 2>/dev/null ||
  { [ "$DIRECT_URL" != "$URL" ] && wget --no-check-certificate --continue -qO "$OUTPUT" "$DIRECT_URL" 2>/dev/null; }
}

download_sing_box_binary() {
  local ONLINE
  ONLINE=$(get_sing_box_version)
  local ARCHIVE="sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz"
  local SB_DIR="$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH"
  local SB_BIN="$SB_DIR/sing-box"
  local URL="${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/v$ONLINE/$ARCHIVE"
  local DIRECT_URL="https://github.com/SagerNet/sing-box/releases/download/v$ONLINE/$ARCHIVE"

  rm -rf "$SB_DIR" "$TEMP_DIR/sing-box"
  wget --no-check-certificate --continue -qO- "$URL" 2>/dev/null | tar xz -C "$TEMP_DIR" 2>/dev/null ||
  wget --no-check-certificate --continue -qO- "$DIRECT_URL" 2>/dev/null | tar xz -C "$TEMP_DIR" 2>/dev/null
  [ -s "$SB_BIN" ] && mv "$SB_BIN" "$TEMP_DIR/sing-box" && chmod +x "$TEMP_DIR/sing-box"

  if ! "$TEMP_DIR/sing-box" version >/dev/null 2>&1; then
    rm -rf "$SB_DIR" "$TEMP_DIR/sing-box"
    wget --no-check-certificate --continue -qO- "$DIRECT_URL" 2>/dev/null | tar xz -C "$TEMP_DIR" 2>/dev/null
    [ -s "$SB_BIN" ] && mv "$SB_BIN" "$TEMP_DIR/sing-box" && chmod +x "$TEMP_DIR/sing-box"
  fi
}

# 查安装及运行状态，下标0: sing-box，下标1: argo，下标2: nginx；状态码: 26 未安装， 27 已安装未运行， 28 运行中
check_install() {
  local PS_LIST=$(ps -eo pid,args | grep -E "$WORK_DIR.*([s]ing-box|[c]loudflared|[n]ginx)" | sed 's/^[ ]\+//g')

  [[ "$IS_SUB" = 'is_sub' || -s ${WORK_DIR}/subscribe/qr ]] && IS_SUB=is_sub || IS_SUB=no_sub
  if ls ${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json >/dev/null 2>&1; then
    check_port_hopping_nat
    [ -n "$PORT_HOPPING_END" ] && IS_HOPPING=is_hopping || IS_HOPPING=no_hopping
  fi

  if [ "$SYSTEM" = 'Alpine' ]; then
    # Alpine 系统使用 OpenRC 检查服务
    if [ -s ${SINGBOX_DAEMON_FILE} ]; then
      local OPENRC_EXECSTART=$(grep '^command=' ${SINGBOX_DAEMON_FILE})
      case "$OPENRC_EXECSTART" in
        *"${WORK_DIR}/sing-box"* )
          if rc-service sing-box status &>/dev/null; then
            STATUS[0]=$(text 28)
          else
            STATUS[0]=$(text 27)
          fi
          ;;
        * )
          SING_BOX_SCRIPT='Unknown or customized sing-box' && error "\n $(text 99) \n"
      esac
    else
      STATUS[0]=$(text 26)
    fi
  else
    # 非 Alpine 系统使用 systemd 检查服务
    if [ -s ${SINGBOX_DAEMON_FILE} ]; then
      SYSTEMD_EXECSTART=$(grep '^ExecStart=' ${SINGBOX_DAEMON_FILE})
      case "$SYSTEMD_EXECSTART" in
        "ExecStart=${WORK_DIR}/sing-box run -C ${WORK_DIR}/conf/" | "ExecStart=${WORK_DIR}/sing-box run -C ${WORK_DIR}/conf" )
          [ "$(systemctl is-active sing-box)" = 'active' ] && STATUS[0]=$(text 28) || STATUS[0]=$(text 27)
          ;;
        'ExecStart=/etc/v2ray-agent/sing-box/sing-box run -c /etc/v2ray-agent/sing-box/conf/config.json' )
          SING_BOX_SCRIPT='mack-a/v2ray-agent' && error "\n $(text 99) \n"
          ;;
        'ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json' )
          SING_BOX_SCRIPT='yonggekkk/sing-box_hysteria2_tuic_argo_reality' && error "\n $(text 99) \n"
          ;;
        'ExecStart=/usr/local/s-ui/bin/runSingbox.sh' )
          SING_BOX_SCRIPT='alireza0/s-ui' && error "\n $(text 99) \n"
          ;;
        'ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json' )
          SING_BOX_SCRIPT='FranzKafkaYu/sing-box-yes' && error "\n $(text 99) \n"
          ;;
        * )
          # 检查是否是自己的脚本安装的，但路径略有不同
          if [[ "$SYSTEMD_EXECSTART" =~ "ExecStart=${WORK_DIR}/sing-box run" ]]; then
            [ "$(systemctl is-active sing-box)" = 'active' ] && STATUS[0]=$(text 28) || STATUS[0]=$(text 27)
          else
            SING_BOX_SCRIPT='Unknown or customized sing-box' && error "\n $(text 99) \n"
          fi
      esac
    elif [ -s /lib/systemd/system/sing-box.service ]; then
      SYSTEMD_EXECSTART=$(grep '^ExecStart=' /lib/systemd/system/sing-box.service)
      case "$SYSTEMD_EXECSTART" in
        'ExecStart=/etc/sing-box/bin/sing-box run -c /etc/sing-box/config.json -C /etc/sing-box/conf' )
          SING_BOX_SCRIPT='233boy/sing-box' && error "\n $(text 99) \n"
          ;;
        * )
          # 检查是否是自己的脚本安装的，但路径略有不同
          if [[ "$SYSTEMD_EXECSTART" =~ "ExecStart=${WORK_DIR}/sing-box run" ]]; then
            [ "$(systemctl is-active sing-box)" = 'active' ] && STATUS[0]=$(text 28) || STATUS[0]=$(text 27)
          else
            SING_BOX_SCRIPT='Unknown or customized sing-box' && error "\n $(text 99) \n"
          fi
      esac
    else
      STATUS[0]=$(text 26)
    fi
  fi

  # 并发下载订阅模板 (clash, clash2, sing-box-template)，在新安装和更换协议时会用到
  {
    download_file "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/clash" "$TEMP_DIR/clash" "${SUBSCRIBE_TEMPLATE}/clash" &
    download_file "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/clash2" "$TEMP_DIR/clash2" "${SUBSCRIBE_TEMPLATE}/clash2" &
    download_file "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/sing-box" "$TEMP_DIR/sing-box-template" "${SUBSCRIBE_TEMPLATE}/sing-box" &
    wait
  } &

  # 如果有需要，后台静默下载 sing-box
  if [[ "${STATUS[0]}" = "$(text 26)" || "$CONFIG_UPDATE_INSTALL" = 'config_update_install' ]] && [ ! -s "$TEMP_DIR/sing-box" ]; then
    # 任务 1: 下载 sing-box
    if [ -s "${WORK_DIR}/sing-box" ]; then
      cp "${WORK_DIR}/sing-box" "$TEMP_DIR/sing-box" && chmod +x "$TEMP_DIR/sing-box"
    else
      download_sing_box_binary &
    fi

    # 任务 2: 下载 jq
    {
      if [ -s "${WORK_DIR}/jq" ]; then
        cp "${WORK_DIR}/jq" "$TEMP_DIR/jq" && chmod +x "$TEMP_DIR/jq"
      else
        download_file "${GH_PROXY}https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$JQ_ARCH" "$TEMP_DIR/jq" "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$JQ_ARCH" && chmod +x "$TEMP_DIR/jq"
      fi
      "$TEMP_DIR/jq" --version >/dev/null 2>&1 || {
        download_file "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$JQ_ARCH" "$TEMP_DIR/jq"
        chmod +x "$TEMP_DIR/jq" 2>/dev/null || true
      }
    } &

    # 任务 3: 下载 qrencode
    {
      if [ -s "${WORK_DIR}/qrencode" ]; then
        cp "${WORK_DIR}/qrencode" "$TEMP_DIR/qrencode" && chmod +x "$TEMP_DIR/qrencode"
      else
        download_file "${GH_PROXY}https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-$QRENCODE_ARCH" "$TEMP_DIR/qrencode" "https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-$QRENCODE_ARCH" && chmod +x "$TEMP_DIR/qrencode"
      fi
    } &

  elif [ "${STATUS[0]}" != "$(text 26)" ]; then
    # 查 sing-box 进程号，运行时长和内存占用，占用的端口
    SING_BOX_VERSION="Version: $(${WORK_DIR}/sing-box version | awk '/version/{print $NF}')"
    [ "${STATUS[0]}" = "$(text 28)" ] && SING_BOX_PID=$(awk '/sing-box run/{print $1}' <<< "$PS_LIST") && [[ "$SING_BOX_PID" =~ ^[0-9]+$ ]] && SING_BOX_MEMORY_USAGE="$(text 58): $(awk '/VmRSS/{printf "%.1f\n", $2/1024}' /proc/$SING_BOX_PID/status) MB"

    NOW_PORTS=$(awk -F ':|,' '/listen_port/{print $2}' ${WORK_DIR}/conf/*)
    NOW_START_PORT=$(awk 'NR == 1 { min = $0 } { if ($0 < min) min = $0; count++ } END {print min}' <<< "$NOW_PORTS")
    NOW_CONSECUTIVE_PORTS=$(awk 'END { print NR }' <<< "$NOW_PORTS")
  fi

  if [ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' ]; then
    # 检查 Argo 服务状态
    STATUS[1]=$(text 26) && IS_ARGO=no_argo
    [ -s ${ARGO_DAEMON_FILE} ] && IS_ARGO=is_argo && STATUS[1]=$(text 27)
    cmd_systemctl status argo &>/dev/null && STATUS[1]=$(text 28)
  fi

  # 检查 Argo 服务类型
  if [ "$SYSTEM" = 'Alpine' ]; then
    if [ -s ${ARGO_DAEMON_FILE} ]; then
      local ARGO_CONTENT=$(grep '^command_args=' ${ARGO_DAEMON_FILE})
      if grep -Fq -- '--token' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_token_argo
      elif grep -Fq -- '--config' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_json_argo
      elif grep -Fq -- '--url' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_quicktunnel_argo
      fi
    fi
  else
    if [ -s ${ARGO_DAEMON_FILE} ]; then
      local ARGO_CONTENT=$(grep '^ExecStart' ${ARGO_DAEMON_FILE})
      if grep -Fq -- '--token' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_token_argo
      elif grep -Fq -- '--config' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_json_argo
      elif grep -Fq -- '--url' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_quicktunnel_argo
      fi
    fi
  fi

  # 如果有需要，后台静默下载 cloudflared
  if [[ "${STATUS[1]}" = "$(text 26)" || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]] && [ ! -s ${WORK_DIR}/cloudflared ]; then
    {
      download_file "${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH" "$TEMP_DIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH" && chmod +x "$TEMP_DIR/cloudflared"
      "$TEMP_DIR/cloudflared" -v >/dev/null 2>&1 || {
        download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH" "$TEMP_DIR/cloudflared"
        chmod +x "$TEMP_DIR/cloudflared" 2>/dev/null || true
      }
    }&
  elif [ "${STATUS[1]}" != "$(text 26)" ]; then
    # 查 Argo 进程号，运行时长和内存占用
    ARGO_VERSION=$(${WORK_DIR}/cloudflared -v | awk '{print $3}' | sed "s@^@Version: &@g")
    [ "${STATUS[1]}" = "$(text 28)" ] && ARGO_PID=$(awk '/cloudflared/{print $1}' <<< "$PS_LIST") && [[ "$ARGO_PID" =~ ^[0-9]+$ ]] && ARGO_MEMORY_USAGE="$(text 58): $(awk '/VmRSS/{printf "%.1f\n", $2/1024}' /proc/$ARGO_PID/status) MB"
  fi

  # 检查 Nginx 状态
  if ! command -v nginx >/dev/null 2>&1; then
    STATUS[2]=$(text 26)
  elif [ -s ${WORK_DIR}/nginx.conf ]; then
    # 查 Nginx 进程号，运行时长和内存占用
    NGINX_VERSION=$(nginx -v 2>&1 | sed "s#.*/##; s/ ([^)]*)//" | sed "s@^@Version: &@g")
    NGINX_PID=$(awk '/nginx/{print $1}' <<< "${PS_LIST}")
    if [[ "$NGINX_PID" =~ ^[0-9]+$ ]]; then
      STATUS[2]=$(text 28)
      NGINX_MEMORY_USAGE="$(text 58): $(awk '/VmRSS/{printf "%.1f\n", $2/1024}' /proc/$NGINX_PID/status) MB"
    else
      STATUS[2]=$(text 27)
    fi
  else
    STATUS[2]=$(text 27)
  fi
}

# 为了适配 alpine，定义 cmd_systemctl 的函数
cmd_systemctl() {
  local _action=$1 _service=${2:-systemctl} _log_file _rc=0 _runlevel_rc=0
  _log_file=$(service_command_log_file "$_service" "$_action")
  : > "$_log_file" 2>/dev/null || true

  nginx_run() {
    local _nginx_bin
    _nginx_bin=$(command -v nginx) || return 1
    "$_nginx_bin" -c "$WORK_DIR/nginx.conf" >> "$_log_file" 2>&1
  }

  nginx_stop() {
    local NGINX_PID NGINX_LISTEN_PIDS
    NGINX_PID=$(ps -eo pid,args | awk -v work_dir="$WORK_DIR" '$0~(work_dir"/nginx.conf"){print $1;exit}')
    [ -n "$NGINX_PID" ] || return 0
    NGINX_LISTEN_PIDS=$(ss -nltp | sed -n "/pid=$NGINX_PID,/ s/,/ /gp" | grep -oP 'pid=\K\S+' | sort -u)
    [ -n "$NGINX_LISTEN_PIDS" ] || return 0
    xargs kill -9 >> "$_log_file" 2>&1 <<< "$NGINX_LISTEN_PIDS"
  }

  if [ "$SYSTEM" = 'Alpine' ]; then
    case "$1" in
      enable )
        rc-update add "$2" default >> "$_log_file" 2>&1
        _rc=$?
        rc-service "$2" start >> "$_log_file" 2>&1 || _rc=$?
        return "$_rc"
        ;;
      disable )
        rc-service "$2" stop >> "$_log_file" 2>&1
        _rc=$?
        if [ "$_rc" -ne 0 ] && [ -e "/etc/init.d/$2" ] && rc-service "$2" status 2>&1 | grep -q 'status: stopped'; then
          _rc=0
        fi
        rc-update del "$2" default >> "$_log_file" 2>&1
        _runlevel_rc=$?
        if [ "$_runlevel_rc" -ne 0 ] && ! rc-update show default 2>/dev/null | awk -v service="$2" '$1 == service { found=1 } END { exit !found }'; then
          _runlevel_rc=0
        fi
        [ "$_rc" -eq 0 ] || return "$_rc"
        [ "$_runlevel_rc" -eq 0 ] || return "$_runlevel_rc"
        return "$_rc"
        ;;
      restart )
        rc-service "$2" restart >> "$_log_file" 2>&1
        return $?
        ;;
      status )
        rc-service "$2" status
        ;;
    esac
  else
    systemctl daemon-reload
    case "$1" in
      enable | disable )
        systemctl "$1" --now "$2" >> "$_log_file" 2>&1
        _rc=$?
        if [ "$IS_CENTOS" = 'CentOS7' ] && [ "$2" = 'sing-box' ] && [ -s $WORK_DIR/nginx.conf ]; then
          if [ "$1" = 'enable' ]; then
            nginx_run || _rc=$?
          else
            nginx_stop || _rc=$?
          fi
        fi
        return "$_rc"
        ;;
      restart )
        [ "$IS_CENTOS" = 'CentOS7' ] && [ "$2" = 'sing-box' ] && [ -s "$WORK_DIR/nginx.conf" ] && nginx_stop
        systemctl restart "$2" >> "$_log_file" 2>&1
        _rc=$?
        if [ "$IS_CENTOS" = 'CentOS7' ] && [ "$2" = 'sing-box' ] && [ -s "$WORK_DIR/nginx.conf" ]; then
          nginx_run || _rc=$?
        fi
        return "$_rc"
        ;;
      status )
        systemctl is-active "$2"
        ;;
      * )
        systemctl "$@" >> "$_log_file" 2>&1
        ;;
    esac
  fi
}

check_system_info() {
  [ -s /etc/os-release ] && SYS="$(awk -F '"' 'tolower($0) ~ /pretty_name/{print $2}' /etc/os-release)"
  [ -s /etc/os-release ] && OS_ID="$(awk -F '=' 'tolower($1) == "id" {gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)"
  [ -s /etc/os-release ] && OS_LIKE="$(awk -F '=' 'tolower($1) == "id_like" {gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)"
  [[ -z "$SYS" ]] && command -v hostnamectl >/dev/null 2>&1 && SYS="$(hostnamectl | awk -F ': ' 'tolower($0) ~ /operating system/{print $2}')"
  [[ -z "$SYS" ]] && command -v lsb_release >/dev/null 2>&1 && SYS="$(lsb_release -sd)"
  [[ -z "$SYS" && -s /etc/lsb-release ]] && SYS="$(awk -F '"' 'tolower($0) ~ /distrib_description/{print $2}' /etc/lsb-release)"
  [[ -z "$SYS" && -s /etc/redhat-release ]] && SYS="$(cat /etc/redhat-release)"
  [[ -z "$SYS" && -s /etc/issue ]] && SYS="$(sed -E '/^$|^\\/d; s/\\.*//; s/[ ]*$//g; q' /etc/issue)"

  REGEX=("debian" "ubuntu" "centos|red hat|kernel|alma|rocky" "arch linux" "alpine" "fedora")
  RELEASE=("Debian" "Ubuntu" "CentOS" "Arch" "Alpine" "Fedora")
  EXCLUDE=("")
  MAJOR=("9" "16" "7" "3" "" "37")
  PACKAGE_UPDATE=("apt -y update" "apt -y update" "yum -y update --skip-broken" "pacman -Sy" "apk update -f" "dnf -y update")
  PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "pacman -S --noconfirm" "apk add --no-cache" "dnf -y install")
  PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "pacman -Rcnsu --noconfirm" "apk del -f" "dnf -y autoremove")

  if [ "$OS_ID" = 'armbian' ]; then
    if [[ "$OS_LIKE" =~ ubuntu ]]; then
      SYSTEM='Ubuntu'
      int=1
    else
      SYSTEM='Debian'
      int=0
    fi
    SYS="${SYS:-Armbian}"
  else
    for int in "${!REGEX[@]}"; do
      [[ "${SYS,,}" =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && break
    done
  fi

  # 针对各厂商的订制系统
  if [ -z "$SYSTEM" ]; then
    command -v yum >/dev/null 2>&1 && int=2 && SYSTEM='CentOS' || error " $(text 5) "
  fi

  # 先排除 EXCLUDE 里包括的特定系统，其他系统需要作大发行版本的比较
  for ex in "${EXCLUDE[@]}"; do [[ ! "{$SYS,,}"  =~ $ex ]]; done &&
  [[ "$(sed -E 's/[^0-9.]//g; s/\..*//' <<< "$SYS")" -lt "${MAJOR[int]}" ]] && error " $(text 6) "

  # 针对部分系统作特殊处理，CentOS7 使用 yum，以上使用 dnf
  ARGO_DAEMON_FILE='/etc/systemd/system/argo.service'; SINGBOX_DAEMON_FILE='/etc/systemd/system/sing-box.service'
  if [ "$SYSTEM" = 'CentOS' ]; then
    IS_CENTOS="CentOS$(sed -E 's/[^0-9.]//g; s/\..*//' <<< "$SYS")"
    [ "$IS_CENTOS" != 'CentOS7' ] && int=5
  elif [ "$SYSTEM" = 'Alpine' ]; then
    ARGO_DAEMON_FILE='/etc/init.d/argo'; SINGBOX_DAEMON_FILE='/etc/init.d/sing-box'
  fi

  # 判断虚拟化
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT=$(systemd-detect-virt)
  elif grep -qa container= /proc/1/environ 2>/dev/null; then
    VIRT=$(tr '\0' '\n' </proc/1/environ | awk -F= '/container=/{print $2; exit}')
  elif grep -Eq '(lxc|docker|kubepods|containerd)' /proc/1/cgroup 2>/dev/null; then
    VIRT=$(grep -Eo '(lxc|docker|kubepods|containerd)' /proc/1/cgroup | sed -n 1p)
  elif command -v hostnamectl >/dev/null 2>&1; then
    VIRT=$(hostnamectl | awk '/Virtualization/{print $NF}')
  else
    command -v virt-what >/dev/null 2>&1 && ${PACKAGE_INSTALL[int]} virt-what >/dev/null 2>&1
    command -v virt-what >/dev/null 2>&1 && VIRT=$(virt-what | sed -n 1p) || VIRT=unknown
  fi
}

# 获取 sing-box 最新版本
get_sing_box_version() {
  # FORCE_VERSION 用于在 sing-box 某个主程序出现 bug 时，强制为指定版本，以防止运行出错
  local FORCE_VERSION=$(wget --no-check-certificate --tries=2 --timeout=3 -qO- ${GH_PROXY}https://raw.githubusercontent.com/qqqasdwx/sing-box/refs/heads/release/force_version | sed 's/^[vV]//g; s/\r//g')
  if grep -q '.' <<< "$FORCE_VERSION"; then
    local RESULT_VERSION="$FORCE_VERSION"
  else
    # 先判断 github api 返回 http 状态码是否为 200，有时候 IP 会被限制，导致获取不到最新版本
    local API_RESPONSE=$(wget --no-check-certificate --server-response --tries=2 --timeout=3 -qO- "${GH_PROXY}https://api.github.com/repos/SagerNet/sing-box/releases" 2>&1 | grep -E '^[ ]+HTTP/|tag_name')
    if grep -q 'HTTP.* 200' <<< "$API_RESPONSE"; then
      local VERSION_LATEST=$(awk -F '["v-]' '/tag_name/{print $5}' <<< "$API_RESPONSE" | sort -Vr | sed -n '1p')
      local RESULT_VERSION=$(awk -F '["v]' -v var="tag_name.*$VERSION_LATEST" '$0 ~ var {print $5; exit}' <<< "$API_RESPONSE")
    else
      local RESULT_VERSION="$DEFAULT_NEWEST_VERSION"
    fi
  fi
  echo "$RESULT_VERSION"
}

# 添加端口跳跃
add_port_hopping_nat() {
  local PORT_HOPPING_START=$1
  local PORT_HOPPING_END=$2
  local PORT_HOPPING_TARGET=$3
  local COMMENT="NAT ${PORT_HOPPING_START}:${PORT_HOPPING_END} to ${PORT_HOPPING_TARGET} (Sing-box Family Bucket)"
  local FW_BACKEND
  local FW_CHECK=() FW_INSTALL=() FW_TO_INSTALL=()

  FW_BACKEND=$(check_port_hopping_firewall)

  case "$FW_BACKEND" in
    ufw )
      info "\n $(text 144) \n"
      ;;
    alpine-iptables )
      command -v iptables >/dev/null 2>&1 || FW_TO_INSTALL+=("iptables")
      ;;
    firewalld )
      command -v firewall-cmd >/dev/null 2>&1 || FW_TO_INSTALL+=("firewalld")
      ;;
    * )
      command -v iptables >/dev/null 2>&1 || FW_TO_INSTALL+=("iptables")
      if ! command -v netfilter-persistent >/dev/null 2>&1 ||
         ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        FW_TO_INSTALL+=("iptables-persistent")
      fi
      ;;
  esac

  if [ "${#FW_TO_INSTALL[@]}" -gt 0 ]; then
    FW_TO_INSTALL=($(printf "%s\n" "${FW_TO_INSTALL[@]}" | sort -u))
    info "\n $(text 7) $(sed "s/ /,&/g" <<< "${FW_TO_INSTALL[*]}") \n"
    [ "$SYSTEM" != 'CentOS' ] && ${PACKAGE_UPDATE[int]} >/dev/null 2>&1
    ${PACKAGE_INSTALL[int]} "${FW_TO_INSTALL[@]}" >/dev/null 2>&1
  fi

  if [ "$FW_BACKEND" = 'firewalld' ]; then
    [ "$(systemctl is-active firewalld 2>/dev/null)" != 'active' ] && cmd_systemctl enable firewalld >/dev/null 2>&1
    [ "$(firewall-cmd --zone=public --get-target 2>/dev/null)" != 'ACCEPT' ] && firewall-cmd --zone=public --set-target=ACCEPT --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
  fi

  if [ "$FW_BACKEND" = 'ufw' ]; then
    add_port_hopping_ufw_rules "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$PORT_HOPPING_TARGET" || warning "\n $(text 146) \n"

  elif [ "$SYSTEM" = 'Alpine' ]; then
    # 添加防火墙规则
    iptables  --table nat -A PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    ip6tables --table nat -A PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null

    # 将 iptables, ip6tables 添加到默认运行级别
    rc-update show default | grep -q 'iptables'  || rc-update add iptables  >/dev/null 2>&1
    rc-update show default | grep -q 'ip6tables' || rc-update add ip6tables >/dev/null 2>&1
    rc-update show default | grep -q 'iptables' && rc-update show default | grep -q 'ip6tables' || warning "\n $(text 96) \n"

    # 保存当前的 iptables, ip6tables 规则集，以便在开机时恢复
    rc-service iptables  save >/dev/null 2>&1
    rc-service ip6tables save >/dev/null 2>&1

  elif command -v firewall-cmd >/dev/null 2>&1 || [ "$SYSTEM" = 'CentOS' ]; then
    if [ "$(firewall-cmd --zone=public --query-masquerade --permanent 2>/dev/null)" != 'yes' ]; then
      firewall-cmd --zone=public --add-masquerade --permanent >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
      [ "$(firewall-cmd --zone=public --query-masquerade --permanent 2>/dev/null)" = 'yes' ] && info "\n firewalld masquerade $(text 28) $(text 37) \n" || warning "\n firewalld masquerade $(text 28) $(text 38) \n"
    fi

    # 添加防火墙规则
    firewall-cmd --zone=public --add-forward-port=port=${PORT_HOPPING_START}-${PORT_HOPPING_END}:proto=udp:toport=${PORT_HOPPING_TARGET} --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1

  else
    # 添加防火墙规则
    iptables  --table nat -A PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    ip6tables --table nat -A PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null

    # 保存当前的 iptables, ip6tables 规则集，以便在开机时恢复
    [ "$(systemctl is-active netfilter-persistent)" != 'active' ] && warning "\n $(text 96) \n" || netfilter-persistent save 2>/dev/null
  fi
}

# 删除端口跳跃
del_port_hopping_nat() {
  local FW_BACKEND
  FW_BACKEND=$(check_port_hopping_firewall)

  check_port_hopping_nat
  [ -z "$PORT_HOPPING_START" ] && return

  if [ "$FW_BACKEND" = 'ufw' ]; then
    del_port_hopping_ufw_rules || warning "\n $(text 146) \n"

  elif [ "$SYSTEM" = 'Alpine' ]; then
    local COMMENT="NAT ${PORT_HOPPING_START}:${PORT_HOPPING_END} to ${PORT_HOPPING_TARGET} (Sing-box Family Bucket)"
    iptables  --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    ip6tables --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null

  elif command -v firewall-cmd >/dev/null 2>&1 || [ "$SYSTEM" = 'CentOS' ]; then
    firewall-cmd --zone=public --permanent --remove-forward-port=port=${PORT_HOPPING_START}-${PORT_HOPPING_END}:proto=udp:toport=${PORT_HOPPING_TARGET} >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1

  else
    local COMMENT="NAT ${PORT_HOPPING_START}:${PORT_HOPPING_END} to ${PORT_HOPPING_TARGET} (Sing-box Family Bucket)"
    iptables  --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    ip6tables --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    [ "$(systemctl is-active netfilter-persistent)" = 'active' ] && netfilter-persistent save 2>/dev/null
  fi
}

# 查端口跳跃的 dnat 端口
check_port_hopping_nat() {
  local FW_BACKEND
  FW_BACKEND=$(check_port_hopping_firewall)

  unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
  PORT_HOPPING_TARGET=$(awk -F '[:,]' '/"listen_port"/{print $2; exit}' ${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json 2>/dev/null | tr -d ' ')

  if [ "$FW_BACKEND" = 'ufw' ]; then
    check_port_hopping_ufw_rules

  elif [ "$SYSTEM" = 'Alpine' ]; then
    local IPTABLES_PREROUTING_LIST=$(iptables --table nat --list-rules PREROUTING 2>/dev/null | grep 'Sing-box Family Bucket')
    [ -n "$IPTABLES_PREROUTING_LIST" ] && \
      HY2_PORT_HOPPING_RANGE=$(awk '{for (i=1; i<=NF; i++) if ($i=="--dport") {print $(i+1); exit}}' <<< "$IPTABLES_PREROUTING_LIST") && \
      PORT_HOPPING_TARGET=$(awk '{for (i=1; i<=NF; i++) if ($i=="--to-destination") {gsub(/^:/,"",$(i+1)); print $(i+1); exit}}' <<< "$IPTABLES_PREROUTING_LIST")
    [ -n "$HY2_PORT_HOPPING_RANGE" ] && PORT_HOPPING_START=${HY2_PORT_HOPPING_RANGE%:*} && PORT_HOPPING_END=${HY2_PORT_HOPPING_RANGE#*:}

  elif command -v firewall-cmd >/dev/null 2>&1 || [ "$SYSTEM" = 'CentOS' ]; then
    local FIREWALL_LIST=$(firewall-cmd --zone=public --list-forward-ports --permanent 2>/dev/null | grep "toport=${PORT_HOPPING_TARGET}")
    [ -n "$FIREWALL_LIST" ] && \
      PORT_HOPPING_START=$(sed "s/.*port=\([0-9]\+\)-.*/\1/" <<< "$FIREWALL_LIST") && \
      PORT_HOPPING_END=$(sed "s/.*port=${PORT_HOPPING_START}-\([0-9]\+\):.*/\1/" <<< "$FIREWALL_LIST") && \
      PORT_HOPPING_TARGET=$(sed "s/.*toport=\([0-9]\+\).*/\1/" <<< "$FIREWALL_LIST")

  else
    local IPTABLES_PREROUTING_LIST=$(iptables --table nat --list-rules PREROUTING 2>/dev/null | grep 'Sing-box Family Bucket')
    [ -n "$IPTABLES_PREROUTING_LIST" ] && \
      HY2_PORT_HOPPING_RANGE=$(awk '{for (i=1; i<=NF; i++) if ($i=="--dport") {print $(i+1); exit}}' <<< "$IPTABLES_PREROUTING_LIST") && \
      PORT_HOPPING_TARGET=$(awk '{for (i=1; i<=NF; i++) if ($i=="--to-destination") {gsub(/^:/,"",$(i+1)); print $(i+1); exit}}' <<< "$IPTABLES_PREROUTING_LIST")
    [ -n "$HY2_PORT_HOPPING_RANGE" ] && PORT_HOPPING_START=${HY2_PORT_HOPPING_RANGE%:*} && PORT_HOPPING_END=${HY2_PORT_HOPPING_RANGE#*:}
  fi

  [ -n "$PORT_HOPPING_START" ] && [ -n "$PORT_HOPPING_END" ] && HY2_PORT_HOPPING_RANGE="${PORT_HOPPING_START}:${PORT_HOPPING_END}"
}

# 检测 IPv4 IPv6 信息
check_system_ip() {
  [ "$L" = 'C' ] && local IS_CHINESE='?lang=zh-CN'
  local DEFAULT_LOCAL_INTERFACE4=$(ip -4 route show default | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
  local DEFAULT_LOCAL_INTERFACE6=$(ip -6 route show default | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
  if [ -n "${DEFAULT_LOCAL_INTERFACE4}${DEFAULT_LOCAL_INTERFACE6}" ]; then
    local DEFAULT_LOCAL_IP4=$(ip -4 addr show $DEFAULT_LOCAL_INTERFACE4 | sed -n 's#.*inet \([^/]\+\)/[0-9]\+.*global.*#\1#gp')
    local DEFAULT_LOCAL_IP6=$(ip -6 addr show $DEFAULT_LOCAL_INTERFACE6 | sed -n 's#.*inet6 \([^/]\+\)/[0-9]\+.*global.*#\1#gp')
    [ -n "$DEFAULT_LOCAL_IP4" ] && local BIND_ADDRESS4="--bind-address=$DEFAULT_LOCAL_IP4"
    [ -n "$DEFAULT_LOCAL_IP6" ] && local BIND_ADDRESS6="--bind-address=$DEFAULT_LOCAL_IP6"
  fi

  # 并行检测 IPv4 和 IPv6 信息
  {
    local CHECK_IP4=$(wget $BIND_ADDRESS4 -4 -qO- --no-check-certificate --tries=2 --timeout=2 https://ip.cloudflare.now.cc${IS_CHINESE})
    grep -q '.' <<< "$CHECK_IP4" && echo "$CHECK_IP4" > $TEMP_DIR/ip4.json
  }&

  {
    local CHECK_IP6=$(wget $BIND_ADDRESS6 -6 -qO- --no-check-certificate --tries=2 --timeout=2 https://ip.cloudflare.now.cc${IS_CHINESE})
    grep -q '.' <<< "$CHECK_IP6" && echo "$CHECK_IP6" > $TEMP_DIR/ip6.json
  }&

  wait

  [ -s $TEMP_DIR/ip4.json ] &&
  local IP4_JSON=$(cat $TEMP_DIR/ip4.json) &&
  WAN4=$(awk -F '"' '/"ip"/{print $4}' <<< "$IP4_JSON") &&
  COUNTRY4=$(awk -F '"' '/"country"/{print $4}' <<< "$IP4_JSON") &&
  EMOJI4=$(awk -F '"' '/"emoji"/{print $4}' <<< "$IP4_JSON") &&
  ASNORG4=$(awk -F '"' '/"isp"/{print $4}' <<< "$IP4_JSON") &&
  rm -f $TEMP_DIR/ip4.json

  [ -s $TEMP_DIR/ip6.json ] &&
  local IP6_JSON=$(cat $TEMP_DIR/ip6.json) &&
  WAN6=$(awk -F '"' '/"ip"/{print $4}' <<< "$IP6_JSON") &&
  COUNTRY6=$(awk -F '"' '/"country"/{print $4}' <<< "$IP6_JSON") &&
  EMOJI6=$(awk -F '"' '/"emoji"/{print $4}' <<< "$IP6_JSON") &&
  ASNORG6=$(awk -F '"' '/"isp"/{print $4}' <<< "$IP6_JSON") &&
  rm -f $TEMP_DIR/ip6.json
}

# 输入起始 port 函数
input_start_port() {
  local NUM=$1
  local PORT_ERROR_TIME=6
  while true; do
    [ "$PORT_ERROR_TIME" -lt 6 ] && unset IN_USED START_PORT
    (( PORT_ERROR_TIME-- )) || true
    if [ "$PORT_ERROR_TIME" = 0 ]; then
      error "\n $(text 3) \n"
    else
      [ -z "$START_PORT" ] && reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 11) " START_PORT
    fi
    START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
    if [[ "$START_PORT" =~ ^[1-9][0-9]{2,4}$ && "$START_PORT" -ge "$MIN_PORT" && "$START_PORT" -le "$MAX_PORT" ]]; then
      for port in $(eval echo {$START_PORT..$[START_PORT+NUM-1]}); do
        ss -nltup | grep -q ":$port" && IN_USED+=("$port")
      done
      [ "${#IN_USED[*]}" -eq 0 ] && break || warning "\n $(text 44) \n"
    fi
  done
}

# 定义 Sing-box 变量
sing-box_variables() {
  STEP_NUM=0
  # 预先用全选协议计算最大总步骤数，用于协议选择提示时显示 (1/?)
  local _saved_protocols=("${INSTALL_PROTOCOLS[@]}")
  INSTALL_PROTOCOLS=(b c d e f g h i j k l m)
  calc_install_steps
  INSTALL_PROTOCOLS=("${_saved_protocols[@]}")

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

  # 选择安装的协议，由于选项 a 为全部协议，所以选项数不是从 a 开始，而是从 b 开始，处理输入：把大写全部变为小写，把不符合的选项去掉，把重复的选项合并
  (( STEP_NUM++ )) || true
  if [ -z "$CHOOSE_PROTOCOLS" ]; then
    hint "\n (${STEP_NUM}/${TOTAL_STEPS:-?}) $(text 49) "
    for e in "${!PROTOCOL_LIST[@]}"; do
      hint " $(asc $(( e+98 ))). ${PROTOCOL_LIST[e]} "
    done
    reading "\n $(text 24) " CHOOSE_PROTOCOLS
  fi

  # 对选择协议的输入处理逻辑：先把所有的大写转为小写，并把所有没有去选项剔除掉，最后按输入的次序排序。如果选项为 a(all) 和其他选项并存，将会忽略 a，如 abc 则会处理为 bc
  normalize_install_protocols

  # 协议已确定，按实际选择重新计算总步骤数
  calc_install_steps

  # 显示选择协议及其次序，输入开始端口号
  if [ -z "$START_PORT" ]; then
    (( STEP_NUM++ )) || true
    hint "\n $(text 60) "
    for w in "${!INSTALL_PROTOCOLS[@]}"; do
      [ "$w" -ge 9 ] && hint " $(( w+1 )). ${PROTOCOL_LIST[$(($(asc ${INSTALL_PROTOCOLS[w]}) - 98))]} " || hint " $(( w+1 )) . ${PROTOCOL_LIST[$(($(asc ${INSTALL_PROTOCOLS[w]}) - 98))]} "
    done
    input_start_port ${#INSTALL_PROTOCOLS[@]}
  fi
  resolve_protocol_ports

  # 输出模式选择，输入用于订阅的 Nginx 服务端口号， 后台根据选择安装依赖
  if [[ "$IS_SUB" = 'is_sub' || "$IS_ARGO" = 'is_argo' ]]; then
    (( STEP_NUM++ )) || true
    [[ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' && -z "$PORT_NGINX" ]] && PORT_NGINX=$(default_service_port)
    input_nginx_port
    validate_nginx_port
  fi

  # Argo 是订阅和 WebSocket 可复用的全局隧道，不依赖是否选择了 WS 协议。
  if [ "$IS_ARGO" = 'is_argo' ]; then
    (( STEP_NUM++ )) || true
    input_argo_auth is_install
    [ -n "$ARGO_RUNS" ] && local ARGO_READY=argo_ready
  fi

  # 输入服务器 IP,默认为检测到的服务器 IP，如果全部为空，则提示并退出脚本
  if [ "$IS_FAST_INSTALL" = 'is_fast_install' ]; then
    grep -q '^$' <<< "$SERVER_IP" && grep -q '.' <<< "$WAN4" && SERVER_IP=$WAN4
    grep -q '^$' <<< "$SERVER_IP" && grep -q '.' <<< "$WAN6" && SERVER_IP=$WAN6
  fi
  if [ -z "$SERVER_IP" ]; then
    if [[ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' || "$IS_FAST_INSTALL" = 'is_fast_install' ]]; then
      SERVER_IP="$SERVER_IP_DEFAULT"
    else
      (( STEP_NUM++ )) || true
      reading "\n (${STEP_NUM}/${TOTAL_STEPS}) $(text 10) " SERVER_IP
    fi
  fi
  SERVER_IP=${SERVER_IP:-"$SERVER_IP_DEFAULT"} && WS_SERVER_IP_SHOW=$SERVER_IP
  [ -z "$SERVER_IP" ] && error " $(text 47) "

  # 根据 IPv4 和 IPv6 的网络状态，使不同的 DNS 策略
  command -v ping >/dev/null 2>&1 && for i in {1..3}; do
    ping -c 1 -W 1 "151.101.1.91" &>/dev/null && local IS_IPV4=is_ipv4 && break
  done

  if command -v ping6 >/dev/null 2>&1; then
    for i in {1..3}; do
      ping6 -c 1 -W 1 "2a04:4e42:200::347" &>/dev/null && local IS_IPV6=is_ipv6 && break
    done
  elif command -v ping >/dev/null 2>&1; then
    for i in {1..3}; do
      ping -c 1 -W 1 "2a04:4e42:200::347" &>/dev/null && local IS_IPV6=is_ipv6 && break
    done
  fi

  case "${IS_IPV4}@${IS_IPV6}" in
    is_ipv4@is_ipv6)
      STRATEGY=prefer_ipv4
      ;;
    is_ipv4@)
      STRATEGY=ipv4_only
      ;;
    @is_ipv6)
      STRATEGY=ipv6_only
      ;;
    *)
      STRATEGY=prefer_ipv4
      ;;
  esac

  # 检测是否解锁 chatGPT
  CHATGPT_OUT=warp-ep;
  [ "$(check_chatgpt $(grep -oE '[46]' <<< "$STRATEGY"))" = 'unlock' ] && CHATGPT_OUT=direct

  # 如果选择有 b j k 这些 reality 协议，自定义 reality 公私钥，如果没有则自动生成
  if [ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' ] && array_contains_any INSTALL_PROTOCOLS b j k; then
    (( STEP_NUM++ )) || true
    input_reality_key
  fi

  # 如选择有 c. hysteria2 时，先选择 Realm / WARP，再选择是否使用端口跳跃。
  # 这三项属于 Hysteria2 子选项，不计入安装总步骤，也不显示步骤编号。
  if array_contains c "${INSTALL_PROTOCOLS[@]}"; then
    input_hy2_realm
    local _SAVED_TOTAL_STEPS="$TOTAL_STEPS"
    TOTAL_STEPS=''
    input_hopping_port
    TOTAL_STEPS="$_SAVED_TOTAL_STEPS"
  fi

  # 如选择有 h. vmess + ws 或 i. vless + ws 时，先检测是否有支持的 http 端口可用，如有则要求输入域名和 cdn
  if array_contains h "${INSTALL_PROTOCOLS[@]}"; then
    if [ "$IS_ARGO" != 'is_argo' ]; then
      local DOMAIN_ERROR_TIME=5
      until [ -n "$VMESS_HOST_DOMAIN" ]; do
        (( DOMAIN_ERROR_TIME-- )) || true
        [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VMESS && reading "\n $(text 50) " VMESS_HOST_DOMAIN || error "\n $(text 3) \n"
      done
    fi
  fi

  if array_contains i "${INSTALL_PROTOCOLS[@]}"; then
    if [ "$IS_ARGO" != 'is_argo' ]; then
      local DOMAIN_ERROR_TIME=5
      until [ -n "$VLESS_HOST_DOMAIN" ]; do
        (( DOMAIN_ERROR_TIME-- )) || true
        [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VLESS && reading "\n $(text 50) " VLESS_HOST_DOMAIN || error "\n $(text 3) \n"
      done
    fi
  fi

  # 选择或者输入 cdn
  if [[ -z "$CDN" ]] && array_contains_any INSTALL_PROTOCOLS h i; then
    (( STEP_NUM++ )) || true
    input_cdn
  fi

  # 确认 UUID
  input_uuid

  # 输入节点名，以系统的 hostname 作为默认
  local EMOJI="${EMOJI4:-$EMOJI6}"
  local EMOJI="${EMOJI}${EMOJI:+ }"
  if [ -z "$NODE_NAME_CONFIRM" ]; then
    if command -v hostname >/dev/null 2>&1; then
      local NODE_NAME_DEFAULT="${EMOJI}$(hostname)"
    elif [ -s /etc/hostname ]; then
      local NODE_NAME_DEFAULT="${EMOJI}$(cat /etc/hostname)"
    else
      local NODE_NAME_DEFAULT="${EMOJI}Sing-Box"
    fi
    [[ "$IS_FAST_INSTALL" = 'is_fast_install' || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]] && NODE_NAME_CONFIRM="${NODE_NAME_DEFAULT}"
    if [ -z "$NODE_NAME_CONFIRM" ]; then
      (( STEP_NUM++ )) || true
      reading "\n (${STEP_NUM}/${TOTAL_STEPS}) $(text 13) " NODE_NAME
    fi
    grep -q '^$' <<< "$NODE_NAME" && NODE_NAME_CONFIRM="$NODE_NAME_DEFAULT" || NODE_NAME_CONFIRM="${EMOJI}${NODE_NAME}"
  fi
}

check_dependencies() {
  local DEPS=() DEPS_CHECK=() DEPS_INSTALL=()

  # 1. Alpine 特有处理：检查 BusyBox wget，设置 IS_PREFER_GO
  if [ "$SYSTEM" = 'Alpine' ]; then
    IS_PREFER_GO=true
    local CHECK_WGET=$(wget 2>&1 | sed -n 1p)
    grep -qi 'busybox' <<< "$CHECK_WGET" && DEPS+=("wget")

    DEPS_CHECK+=("bash" "rc-update")
    DEPS_INSTALL+=("bash" "openrc")
  else
    # 非 Alpine 系统，检查 systemd-resolved 状态，用于 DNS 配置里的 prefer_go 字段
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved && IS_PREFER_GO=false || IS_PREFER_GO=true
  fi

  # 2. 基础通用依赖（不含防火墙，防火墙仅端口跳跃时按需安装）
  DEPS_CHECK+=("wget" "curl" "tar" "ss"  "ip"        "bash" "openssl" "ping")
  DEPS_INSTALL+=("wget" "curl" "tar" "iproute2" "iproute2" "bash" "openssl" "iputils-ping")

  [ "$SYSTEM" != 'Alpine' ] && DEPS_CHECK+=("systemctl") && DEPS_INSTALL+=("systemctl")

  # CentOS7 需要 epel-release
  [ "$SYSTEM" = 'CentOS' ] && [ "$IS_CENTOS" = 'CentOS7' ] && \
    yum repolist 2>/dev/null | grep -q epel || { [ "$SYSTEM" = 'CentOS' ] && [ "$IS_CENTOS" = 'CentOS7' ] && DEPS+=("epel-release"); }

  for g in "${!DEPS_CHECK[@]}"; do
    ! command -v "${DEPS_CHECK[g]}" >/dev/null 2>&1 && DEPS+=("${DEPS_INSTALL[g]}")
  done

  # 3. 去重并安装
  DEPS=($(printf "%s\n" "${DEPS[@]}" | sort -u))
  if [ "${#DEPS[@]}" -gt 0 ]; then
    info "\n $(text 7) $(sed "s/ /,&/g" <<< "${DEPS[*]}") \n"
    [[ ! "$SYSTEM" =~ Alpine|CentOS ]] && ${PACKAGE_UPDATE[int]} >/dev/null 2>&1
    ${PACKAGE_INSTALL[int]} "${DEPS[@]}" >/dev/null 2>&1
  else
    info "\n $(text 8) \n"
  fi

  # 4. 对于 Alpine 系统，确保 OpenRC 服务已启动
  if [ "$SYSTEM" = 'Alpine' ]; then
    if ! rc-service --list | grep -q "^openrc"; then
      rc-update add openrc boot >/dev/null 2>&1
      rc-service openrc start >/dev/null 2>&1
    fi
  fi
}

# 生成 UFW PortHopping 备注
add_port_hopping_ufw_rules() {
  local PORT_HOPPING_START=$1
  local PORT_HOPPING_END=$2
  local PORT_HOPPING_TARGET=$3
  local TARGET_PORT="$3"
  local COMMENT="Sing-box Family Bucket UFW NAT ${PORT_HOPPING_START}:${PORT_HOPPING_END} -> ${TARGET_PORT}"

  [ -z "$PORT_HOPPING_START" ] && return 1
  [ -z "$PORT_HOPPING_END" ] && return 1
  [ -z "$TARGET_PORT" ] && return 1

  local UFW_BEFORE_RULES='/etc/ufw/before.rules'
  local UFW_BEFORE6_RULES='/etc/ufw/before6.rules'
  local UFW_IPV4_BLOCK_BEGIN="# ${COMMENT} IPv4 BEGIN"
  local UFW_IPV4_BLOCK_END="# ${COMMENT} IPv4 END"
  local UFW_IPV6_BLOCK_BEGIN="# ${COMMENT} IPv6 BEGIN"
  local UFW_IPV6_BLOCK_END="# ${COMMENT} IPv6 END"

  # 先清理所有历史残留规则，确保文件和 numbered 规则都干净
  del_port_hopping_ufw_rules >/dev/null 2>&1

  # 注意：这里必须用 TARGET_PORT，不能再用可能被下游函数改掉的 PORT_HOPPING_TARGET
  add_port_hopping_ufw_block "$UFW_BEFORE_RULES"  "$UFW_IPV4_BLOCK_BEGIN" "$UFW_IPV4_BLOCK_END" "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$TARGET_PORT" "$COMMENT" || return 1
  add_port_hopping_ufw_block "$UFW_BEFORE6_RULES" "$UFW_IPV6_BLOCK_BEGIN" "$UFW_IPV6_BLOCK_END" "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$TARGET_PORT" "$COMMENT" || return 1

  ufw delete allow ${PORT_HOPPING_START}:${PORT_HOPPING_END}/udp >/dev/null 2>&1 || true
  ufw allow ${PORT_HOPPING_START}:${PORT_HOPPING_END}/udp comment "$COMMENT" >/dev/null 2>&1 || return 1
  ufw reload >/dev/null 2>&1 || return 1

  [ "$(ufw status 2>/dev/null | awk '/^Status/{print $NF; exit}')" != 'active' ] && warning "\n $(text 145) \n"

  return 0
}

# 向指定的 UFW 规则文件写入 PortHopping NAT 规则块
add_port_hopping_ufw_block() {
  local RULES_FILE=$1
  local BLOCK_BEGIN=$2
  local BLOCK_END=$3
  local PORT_HOPPING_START=$4
  local PORT_HOPPING_END=$5
  local PORT_HOPPING_TARGET=$6
  local COMMENT=$7

  [ ! -e "$RULES_FILE" ] && return 0
  [ -z "$PORT_HOPPING_START" ] && return 1
  [ -z "$PORT_HOPPING_END" ] && return 1
  [ -z "$PORT_HOPPING_TARGET" ] && return 1
  [ -z "$COMMENT" ] && return 1

  awk \
    -v begin="$BLOCK_BEGIN" \
    -v end="$BLOCK_END" \
    -v start="$PORT_HOPPING_START" \
    -v finish="$PORT_HOPPING_END" \
    -v target="$PORT_HOPPING_TARGET" \
    -v comment="$COMMENT" '
    BEGIN { inserted=0 }
    {
      if ($0 ~ /^\*filter/ && inserted==0) {
        print begin
        print "*nat"
        print ":PREROUTING ACCEPT [0:0]"
        print "-A PREROUTING -p udp --dport " start ":" finish " -m comment --comment \"" comment "\" -j DNAT --to-destination :" target
        print "COMMIT"
        print end
        inserted=1
      }
      print
    }
    END {
      if (inserted==0) {
        print begin
        print "*nat"
        print ":PREROUTING ACCEPT [0:0]"
        print "-A PREROUTING -p udp --dport " start ":" finish " -m comment --comment \"" comment "\" -j DNAT --to-destination :" target
        print "COMMIT"
        print end
      }
    }
  ' "$RULES_FILE" > "${TEMP_DIR}/$(basename "$RULES_FILE")" && mv "${TEMP_DIR}/$(basename "$RULES_FILE")" "$RULES_FILE"
}

# 删除指定 UFW 规则文件中的 PortHopping NAT 规则块
del_port_hopping_ufw_block() {
  local RULES_FILE=$1
  local IP_VERSION=$2
  local TEMP_RULES_FILE

  [ ! -e "$RULES_FILE" ] && return 0

  TEMP_RULES_FILE="${TEMP_DIR}/$(basename "$RULES_FILE")"

  awk -v ip_version="$IP_VERSION" '
    BEGIN { in_block=0 }
    {
      if ($0 ~ "^# Sing-box Family Bucket UFW NAT .* " ip_version " BEGIN$") {
        in_block=1
        next
      }
      if (in_block==1 && $0 ~ "^# Sing-box Family Bucket UFW NAT .* " ip_version " END$") {
        in_block=0
        next
      }
      if (in_block==0) print
    }
  ' "$RULES_FILE" > "$TEMP_RULES_FILE" && mv "$TEMP_RULES_FILE" "$RULES_FILE"
}

# 删除 UFW PortHopping NAT 规则
del_port_hopping_ufw_rules() {
  local UFW_BEFORE_RULES='/etc/ufw/before.rules'
  local UFW_BEFORE6_RULES='/etc/ufw/before6.rules'
  local COMMENT_PREFIX='Sing-box Family Bucket UFW NAT'
  local RULE_NUM
  local OLD_START OLD_END

  check_port_hopping_ufw_rules
  OLD_START="$PORT_HOPPING_START"
  OLD_END="$PORT_HOPPING_END"

  del_port_hopping_ufw_block "$UFW_BEFORE_RULES" "IPv4" >/dev/null 2>&1
  del_port_hopping_ufw_block "$UFW_BEFORE6_RULES" "IPv6" >/dev/null 2>&1

  if [ -n "$OLD_START" ] && [ -n "$OLD_END" ]; then
    ufw delete allow ${OLD_START}:${OLD_END}/udp >/dev/null 2>&1 || true
  fi

  while read -r RULE_NUM; do
    [ -n "$RULE_NUM" ] && ufw --force delete "$RULE_NUM" >/dev/null 2>&1 || true
  done < <(
    ufw status numbered 2>/dev/null | \
    grep "$COMMENT_PREFIX" | \
    awk -F'[][]' '{print $2}' | sort -rn
  )

  ufw reload >/dev/null 2>&1 || return 1

  unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
  return 0
}

# 检查 UFW PortHopping NAT 规则
check_port_hopping_ufw_rules() {
  unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
  local DETECTED_TARGET
  local UFW_BEFORE_RULES='/etc/ufw/before.rules'
  local UFW_BEFORE6_RULES='/etc/ufw/before6.rules'
  local UFW_RULE

  DETECTED_TARGET=$(awk -F '[:,]' '/"listen_port"/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json 2>/dev/null)

  if [ -s "$UFW_BEFORE_RULES" ]; then
    UFW_RULE=$(awk '
      /Sing-box Family Bucket UFW NAT .* IPv4 BEGIN/ { in_block=1; next }
      /Sing-box Family Bucket UFW NAT .* IPv4 END/   { in_block=0 }
      in_block && /-A PREROUTING -p udp/ { print; exit }
    ' "$UFW_BEFORE_RULES")
  fi

  if [ -z "$UFW_RULE" ] && [ -s "$UFW_BEFORE6_RULES" ]; then
    UFW_RULE=$(awk '
      /Sing-box Family Bucket UFW NAT .* IPv6 BEGIN/ { in_block=1; next }
      /Sing-box Family Bucket UFW NAT .* IPv6 END/   { in_block=0 }
      in_block && /-A PREROUTING -p udp/ { print; exit }
    ' "$UFW_BEFORE6_RULES")
  fi

  [ -z "$UFW_RULE" ] && {
    PORT_HOPPING_TARGET="$DETECTED_TARGET"
    return 0
  }

  if [[ "$UFW_RULE" =~ --dport[[:space:]]+([0-9]+):([0-9]+) ]]; then
    PORT_HOPPING_START="${BASH_REMATCH[1]}"
    PORT_HOPPING_END="${BASH_REMATCH[2]}"
    HY2_PORT_HOPPING_RANGE="${PORT_HOPPING_START}:${PORT_HOPPING_END}"
  fi

  if [[ "$UFW_RULE" =~ --to-destination[[:space:]]+:([0-9]+) ]]; then
    PORT_HOPPING_TARGET="${BASH_REMATCH[1]}"
  else
    PORT_HOPPING_TARGET="$DETECTED_TARGET"
  fi
}

# 检测防火墙后端
check_firewall_backend() {
  local UFW_STATUS

  if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status 2>/dev/null | awk '/^Status/{print $NF; exit}')
    [ "$UFW_STATUS" = 'active' ] && {
      echo 'ufw'
      return
    }
  fi

  if [ "$SYSTEM" = 'Alpine' ]; then
    echo 'alpine-iptables'
  elif command -v firewall-cmd >/dev/null 2>&1 || [ "$SYSTEM" = 'CentOS' ]; then
    echo 'firewalld'
  else
    echo 'iptables'
  fi
}

# 兼容旧调用
check_port_hopping_firewall() {
  check_firewall_backend
}

# 初始化防火墙状态目录
init_firewall_state_dir() {
  [ ! -d "$FIREWALL_STATE_DIR" ] && mkdir -p "$FIREWALL_STATE_DIR"
}

# 读取上一次由脚本管理的普通端口规则
append_unique_port() {
  local ARRAY_NAME=$1
  local PORT=$2
  local -n ARRAY_REF="$ARRAY_NAME"

  [ -z "$PORT" ] && return 0
  [[ ! "$PORT" =~ ^[0-9]+$ ]] && return 0

  local ITEM
  for ITEM in "${ARRAY_REF[@]}"; do
    [ "$ITEM" = "$PORT" ] && return 0
  done

  ARRAY_REF+=("$PORT")
}

# 收集当前应该对外开放的普通端口
collect_exposed_ports() {
  EXPOSED_TCP_PORTS=()
  EXPOSED_UDP_PORTS=()

  local FILE BASENAME PORT NGINX_PORT HAS_NGINX=false

  if [ -s "${WORK_DIR}/nginx.conf" ]; then
    HAS_NGINX=true
    NGINX_PORT=$(awk '
      /listen[[:space:]]+[0-9]+[[:space:]]*;/ && $2 !~ /^\[/ {
        gsub(/;/, "", $2)
        print $2
        exit
      }
    ' "${WORK_DIR}/nginx.conf")
    append_unique_port EXPOSED_TCP_PORTS "$NGINX_PORT"
  fi

  for FILE in ${WORK_DIR}/conf/*_inbounds.json; do
    [ ! -s "$FILE" ] && continue
    BASENAME=$(basename "$FILE")
    PORT=$(awk -F '[:,]' '/"listen_port"/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$FILE")
    [ -z "$PORT" ] && continue

    case "$BASENAME" in
      *hysteria2_inbounds.json|*tuic_inbounds.json )
        append_unique_port EXPOSED_UDP_PORTS "$PORT"
        ;;
      *naive_inbounds.json )
        append_unique_port EXPOSED_TCP_PORTS "$PORT"
        append_unique_port EXPOSED_UDP_PORTS "$PORT"
        ;;
      *vmess-ws_inbounds.json|*vless-ws-tls_inbounds.json )
        [ "$HAS_NGINX" = false ] && append_unique_port EXPOSED_TCP_PORTS "$PORT"
        ;;
      * )
        append_unique_port EXPOSED_TCP_PORTS "$PORT"
        ;;
    esac
  done
}

# UFW 普通端口规则备注
service_port_ufw_comment() {
  local PROTO=$1
  local PORT=$2
  echo "Sing-box Family Bucket UFW PORT ${PROTO} ${PORT}"
}

# 添加 UFW 普通端口规则
add_service_port_rule_ufw() {
  local PROTO=$1
  local PORT=$2
  local COMMENT
  COMMENT=$(service_port_ufw_comment "$PROTO" "$PORT")

  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 1
  ufw allow ${PORT}/${PROTO} comment "$COMMENT" >/dev/null 2>&1
}

# 删除 UFW 普通端口规则
del_service_port_rule_ufw() {
  local PROTO=$1
  local PORT=$2
  local COMMENT_PREFIX='Sing-box Family Bucket UFW PORT'
  local RULE_NUM

  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 0

  ufw --force delete allow ${PORT}/${PROTO} >/dev/null 2>&1 || true

  while read -r RULE_NUM; do
    [ -n "$RULE_NUM" ] && ufw --force delete "$RULE_NUM" >/dev/null 2>&1 || true
  done < <(
    ufw status numbered 2>/dev/null | \
    grep "$COMMENT_PREFIX ${PROTO} ${PORT}" | \
    awk -F'[][]' '{print $2}' | sort -rn
  )
}

# 清理所有由脚本管理的 UFW 普通端口规则
purge_service_port_rules_ufw() {
  local RULE_NUM
  local COMMENT_PREFIX='Sing-box Family Bucket UFW PORT'

  while read -r RULE_NUM; do
    [ -n "$RULE_NUM" ] && ufw --force delete "$RULE_NUM" >/dev/null 2>&1 || true
  done < <(
    ufw status numbered 2>/dev/null | \
    grep "$COMMENT_PREFIX" | \
    awk -F'[][]' '{print $2}' | sort -rn
  )

  ufw reload >/dev/null 2>&1 || true
}

# 添加 firewalld 普通端口规则
add_service_port_rule_firewalld() {
  local PROTO=$1
  local PORT=$2
  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 1
  firewall-cmd --zone=public --add-port=${PORT}/${PROTO} --permanent >/dev/null 2>&1
}

# 删除 firewalld 普通端口规则
del_service_port_rule_firewalld() {
  local PROTO=$1
  local PORT=$2
  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 0
  firewall-cmd --zone=public --remove-port=${PORT}/${PROTO} --permanent >/dev/null 2>&1
}

# iptables 普通端口规则备注
add_service_port_rule_iptables() {
  local PROTO=$1
  local PORT=$2
  local COMMENT="Sing-box Family Bucket PORT ${PROTO} ${PORT}"

  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 1

  iptables -C INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || \
  iptables -A INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1

  ip6tables -C INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || \
  ip6tables -A INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1
}

# 删除 iptables 普通端口规则
del_service_port_rule_iptables() {
  local PROTO=$1
  local PORT=$2
  local COMMENT="Sing-box Family Bucket PORT ${PROTO} ${PORT}"

  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 0

  iptables -D INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || true
  ip6tables -D INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || true
}

# 按后端保存 / 重载防火墙规则
reload_or_save_firewall_rules() {
  local FW_BACKEND
  FW_BACKEND=$(check_firewall_backend)

  case "$FW_BACKEND" in
    ufw )
      ufw reload >/dev/null 2>&1 || true
      ;;
    firewalld )
      firewall-cmd --reload >/dev/null 2>&1 || true
      ;;
    alpine-iptables )
      rc-service iptables save >/dev/null 2>&1 || true
      rc-service ip6tables save >/dev/null 2>&1 || true
      ;;
    * )
      [ "$(systemctl is-active netfilter-persistent 2>/dev/null)" = 'active' ] && netfilter-persistent save >/dev/null 2>&1 || true
      ;;
  esac
}

# 清理上一次由脚本管理的普通端口规则
purge_service_firewall_rules() {
  local FW_BACKEND
  FW_BACKEND=$(check_firewall_backend)

  init_firewall_state_dir
  MANAGED_TCP_PORTS=()
  MANAGED_UDP_PORTS=()

  [ ! -s "$SERVICE_FIREWALL_STATE_FILE" ] || while read -r PROTO PORT; do
    case "$PROTO" in
      tcp ) MANAGED_TCP_PORTS+=("$PORT") ;;
      udp ) MANAGED_UDP_PORTS+=("$PORT") ;;
    esac
  done < "$SERVICE_FIREWALL_STATE_FILE"

  case "$FW_BACKEND" in
    ufw )
      purge_service_port_rules_ufw
      ;;
    firewalld )
      local PORT
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do
        del_service_port_rule_firewalld tcp "$PORT"
      done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do
        del_service_port_rule_firewalld udp "$PORT"
      done
      ;;
    alpine-iptables|iptables )
      local PORT
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do
        del_service_port_rule_iptables tcp "$PORT"
      done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do
        del_service_port_rule_iptables udp "$PORT"
      done
      ;;
  esac

  : > "$SERVICE_FIREWALL_STATE_FILE"
  reload_or_save_firewall_rules
}

# 同步普通服务端口规则
# 同步所有防火墙规则
sync_firewall_rules() {
  local FW_BACKEND
  local PORT
  local HY2_FILE="${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json"
  local HY2_TARGET DESIRED_START DESIRED_END
  local EXISTING_START EXISTING_END EXISTING_TARGET
  local FILE BASENAME NGINX_PORT HAS_NGINX=false

  EXPOSED_TCP_PORTS=()
  EXPOSED_UDP_PORTS=()

  if [ -s "${WORK_DIR}/nginx.conf" ]; then
    HAS_NGINX=true
    NGINX_PORT=$(awk '
      /listen[[:space:]]+[0-9]+[[:space:]]*;/ && $2 !~ /^\[/ {
        gsub(/;/, "", $2)
        print $2
        exit
      }
    ' "${WORK_DIR}/nginx.conf")
    append_unique_port EXPOSED_TCP_PORTS "$NGINX_PORT"
  fi

  for FILE in ${WORK_DIR}/conf/*_inbounds.json; do
    [ ! -s "$FILE" ] && continue
    BASENAME=$(basename "$FILE")
    PORT=$(awk -F '[:,]' '/"listen_port"/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$FILE")
    [ -z "$PORT" ] && continue

    case "$BASENAME" in
      *hysteria2_inbounds.json|*tuic_inbounds.json )
        append_unique_port EXPOSED_UDP_PORTS "$PORT"
        ;;
      *naive_inbounds.json )
        append_unique_port EXPOSED_TCP_PORTS "$PORT"
        append_unique_port EXPOSED_UDP_PORTS "$PORT"
        ;;
      *vmess-ws_inbounds.json|*vless-ws-tls_inbounds.json )
        [ "$HAS_NGINX" = false ] && append_unique_port EXPOSED_TCP_PORTS "$PORT"
        ;;
      * )
        append_unique_port EXPOSED_TCP_PORTS "$PORT"
        ;;
    esac
  done

  FW_BACKEND=$(check_firewall_backend)

  init_firewall_state_dir
  MANAGED_TCP_PORTS=()
  MANAGED_UDP_PORTS=()
  if [ -s "$SERVICE_FIREWALL_STATE_FILE" ]; then
    while read -r PROTO PORT; do
      case "$PROTO" in
        tcp ) MANAGED_TCP_PORTS+=("$PORT") ;;
        udp ) MANAGED_UDP_PORTS+=("$PORT") ;;
      esac
    done < "$SERVICE_FIREWALL_STATE_FILE"
  fi

  case "$FW_BACKEND" in
    ufw )
      purge_service_port_rules_ufw
      ;;
    firewalld )
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do
        del_service_port_rule_firewalld tcp "$PORT"
      done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do
        del_service_port_rule_firewalld udp "$PORT"
      done
      ;;
    alpine-iptables|iptables )
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do
        del_service_port_rule_iptables tcp "$PORT"
      done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do
        del_service_port_rule_iptables udp "$PORT"
      done
      ;;
  esac

  : > "$SERVICE_FIREWALL_STATE_FILE"
  reload_or_save_firewall_rules

  case "$FW_BACKEND" in
    ufw )
      for PORT in "${EXPOSED_TCP_PORTS[@]}"; do
        add_service_port_rule_ufw tcp "$PORT"
      done
      for PORT in "${EXPOSED_UDP_PORTS[@]}"; do
        add_service_port_rule_ufw udp "$PORT"
      done
      ;;
    firewalld )
      for PORT in "${EXPOSED_TCP_PORTS[@]}"; do
        add_service_port_rule_firewalld tcp "$PORT"
      done
      for PORT in "${EXPOSED_UDP_PORTS[@]}"; do
        add_service_port_rule_firewalld udp "$PORT"
      done
      ;;
    alpine-iptables|iptables )
      for PORT in "${EXPOSED_TCP_PORTS[@]}"; do
        add_service_port_rule_iptables tcp "$PORT"
      done
      for PORT in "${EXPOSED_UDP_PORTS[@]}"; do
        add_service_port_rule_iptables udp "$PORT"
      done
      ;;
  esac

  : > "$SERVICE_FIREWALL_STATE_FILE"
  for PORT in "${EXPOSED_TCP_PORTS[@]}"; do
    [ -n "$PORT" ] && echo "tcp $PORT" >> "$SERVICE_FIREWALL_STATE_FILE"
  done
  for PORT in "${EXPOSED_UDP_PORTS[@]}"; do
    [ -n "$PORT" ] && echo "udp $PORT" >> "$SERVICE_FIREWALL_STATE_FILE"
  done
  reload_or_save_firewall_rules

  HY2_TARGET=$(awk -F '[:,]' '/"listen_port"/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ${HY2_FILE} 2>/dev/null)

  check_port_hopping_nat
  EXISTING_START="$PORT_HOPPING_START"
  EXISTING_END="$PORT_HOPPING_END"
  EXISTING_TARGET="$PORT_HOPPING_TARGET"

  DESIRED_START="${PORT_HOPPING_START:-$EXISTING_START}"
  DESIRED_END="${PORT_HOPPING_END:-$EXISTING_END}"

  if [ -z "$HY2_TARGET" ]; then
    [ -n "$EXISTING_START" ] && [ -n "$EXISTING_END" ] && del_port_hopping_nat
    unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE PORT_HOPPING_TARGET
    return 0
  fi

  if [ -z "$DESIRED_START" ] || [ -z "$DESIRED_END" ]; then
    [ -n "$EXISTING_START" ] && [ -n "$EXISTING_END" ] && del_port_hopping_nat
    unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
    PORT_HOPPING_TARGET="$HY2_TARGET"
    return 0
  fi

  if [ "$EXISTING_START" != "$DESIRED_START" ] ||      [ "$EXISTING_END" != "$DESIRED_END" ] ||      [ "$EXISTING_TARGET" != "$HY2_TARGET" ]; then
    [ -n "$EXISTING_START" ] && [ -n "$EXISTING_END" ] && del_port_hopping_nat
    PORT_HOPPING_START="$DESIRED_START"
    PORT_HOPPING_END="$DESIRED_END"
    HY2_PORT_HOPPING_RANGE="${DESIRED_START}:${DESIRED_END}"
    PORT_HOPPING_TARGET="$HY2_TARGET"
    add_port_hopping_nat "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$PORT_HOPPING_TARGET"
  fi
}
export_argo_json_file() {
  local FILE_PATH=$1
  [[ -z "$PORT_NGINX" && -s ${WORK_DIR}/nginx.conf ]] && local PORT_NGINX=$(awk '/listen/{print $2; exit}' ${WORK_DIR}/nginx.conf)
  [ -z "$ARGO_JSON" ] && [ -s "$FILE_PATH/tunnel.json" ] && ARGO_JSON=$(cat "$FILE_PATH/tunnel.json")
  [ ! -s "$FILE_PATH/tunnel.json" ] && echo "$ARGO_JSON" > "$FILE_PATH/tunnel.json"
  cat > "$FILE_PATH/tunnel.yml" << EOF
tunnel: $(awk -F '"' '{print $12}' <<< "$ARGO_JSON")
credentials-file: ${WORK_DIR}/tunnel.json

ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://localhost:${PORT_NGINX}
  - service: http_status:404
EOF
}

# 生成自签证书，区分使用 IPv4 / IPv6 / 域名
# 默认同时更新 cert.pem(36500天) 和 cert_200.pem(200天)
# 传参 naive_only 时，仅检测 cert_200.pem 是否缺失 / 过期 / SNI 不一致，符合条件才更新
ssl_certificate() {
  local TLS_SERVER="$1"
  local CERT_MODE="$2"
  local CERT_200_FILE="${WORK_DIR}/cert/cert_200.pem"
  local CERT_200_SNI

  [ ! -d ${WORK_DIR}/cert ] && mkdir -p ${WORK_DIR}/cert

  if [ "$CERT_MODE" != 'naive_only' ]; then
    openssl ecparam -genkey -name prime256v1 -out ${WORK_DIR}/cert/private.key
  elif [ ! -s ${WORK_DIR}/cert/private.key ] || [ ! -s ${WORK_DIR}/cert/cert.pem ]; then
    CERT_MODE=''
    openssl ecparam -genkey -name prime256v1 -out ${WORK_DIR}/cert/private.key
  fi

  cat > ${WORK_DIR}/cert/cert.conf << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $(awk -F . '{print $(NF-1)"."$NF}' <<< "$TLS_SERVER")

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS = ${TLS_SERVER}
EOF

  if [ "$CERT_MODE" != 'naive_only' ]; then
    openssl req -new -x509 -days 36500 -key ${WORK_DIR}/cert/private.key -out ${WORK_DIR}/cert/cert.pem -config ${WORK_DIR}/cert/cert.conf -extensions v3_req
    openssl req -new -x509 -days 200 -key ${WORK_DIR}/cert/private.key -out ${WORK_DIR}/cert/cert_200.pem -config ${WORK_DIR}/cert/cert.conf -extensions v3_req
  else
    CERT_200_SNI=$(openssl x509 -noout -ext subjectAltName -in "$CERT_200_FILE" 2>/dev/null | awk -F 'DNS:' '/DNS:/{gsub(/,.*/, "", $2); print $2}')
    if [ ! -s "$CERT_200_FILE" ] || ! openssl x509 -checkend 0 -noout -in "$CERT_200_FILE" >/dev/null 2>&1 || [ "$CERT_200_SNI" != "$TLS_SERVER" ]; then
      openssl req -new -x509 -days 200 -key ${WORK_DIR}/cert/private.key -out ${WORK_DIR}/cert/cert_200.pem -config ${WORK_DIR}/cert/cert.conf -extensions v3_req
    fi
  fi

  rm -f ${WORK_DIR}/cert/cert.conf
}

# Nginx 配置文件
export_nginx_conf_file() {
  # 在添加协议，需要用到 nginx 的时候，先检测是否已经安装
  if ! command -v nginx >/dev/null 2>&1; then
    info "\n $(text 7) nginx"
    ${PACKAGE_INSTALL[int]} nginx >/dev/null 2>&1
  fi

  local VMESS_NGINX_PATH="${VMESS_WS_PATH:-${UUID_CONFIRM}-vmess}"
  local VLESS_NGINX_PATH="${VLESS_WS_PATH:-${UUID_CONFIRM}-vless}"

  NGINX_CONF="user  root;
worker_processes  auto;

error_log  /dev/null;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
"
  [ "$IS_SUB" = 'is_sub' ] && NGINX_CONF+="
  map \$http_user_agent \$path1 {
    default                    /;               # 默认路径
    ~*v2rayN                   /v2rayn;         # 匹配 V2rayN 客户端
    ~*clash                    /clash;          # 匹配 Clash 客户端
    ~*Throne|Neko              /throne;         # 匹配 Throne / Neko 客户端
    ~*ShadowRocket             /shadowrocket;   # 匹配 ShadowRocket 客户端
    ~*SFM|SFI|SFA              /sing-box;       # 匹配 Sing-box 官方客户端
#   ~*Chrome|Firefox|Mozilla   /;               # 添加更多的分流规则
  }
  map \$http_user_agent \$path2 {
    default                    /;               # 默认路径
    ~*v2rayN                   /v2rayn;         # 匹配 V2rayN 客户端
    ~*clash                    /clash2;         # 匹配 Clash 客户端
    ~*Throne|Neko              /throne;         # 匹配 Throne / Neko 客户端
    ~*ShadowRocket             /shadowrocket;   # 匹配 ShadowRocket 客户端
    ~*SFM|SFI|SFA              /sing-box;       # 匹配 Sing-box 官方客户端
#   ~*Chrome|Firefox|Mozilla   /;               # 添加更多的分流规则
  }"

  [ "$IS_SUB" = 'is_sub' ] && NGINX_CONF+="
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
"

  NGINX_CONF+="
    access_log  /dev/null;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    #include /etc/nginx/conf.d/*.conf;

  server {
    listen $PORT_NGINX ;  # ipv4
    listen [::]:$PORT_NGINX ;  # ipv6
    server_name localhost;
"

  [[ -n "$PORT_VMESS_WS" && "$IS_ARGO" = 'is_argo' ]] && NGINX_CONF+="
    # 反代 sing-box vmess websocket
    location /${VMESS_NGINX_PATH} {
      if (\$http_upgrade != \"websocket\") {
         return 404;
      }
      proxy_pass                          http://127.0.0.1:${PORT_VMESS_WS};
      proxy_http_version                  1.1;
      proxy_set_header Upgrade            \$http_upgrade;
      proxy_set_header Connection         \"upgrade\";
      proxy_set_header X-Real-IP          \$remote_addr;
      proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
      proxy_set_header Host               \$host;
      proxy_redirect                      off;
    }
"

  [[ -n "$PORT_VLESS_WS" && "$IS_ARGO" = 'is_argo' ]] && NGINX_CONF+="
    # 反代 sing-box vless websocket
    location /${VLESS_NGINX_PATH} {
      if (\$http_upgrade != \"websocket\") {
         return 404;
      }
      proxy_http_version                  1.1;
      proxy_pass                          https://127.0.0.1:${PORT_VLESS_WS};
      proxy_ssl_protocols                 TLSv1.3;
      proxy_set_header Upgrade            \$http_upgrade;
      proxy_set_header Connection         \"upgrade\";
      proxy_set_header X-Real-IP          \$remote_addr;
      proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
      proxy_set_header Host               \$host;
      proxy_redirect                      off;
    }
"

  [ "$IS_SUB" = 'is_sub' ] && NGINX_CONF+="
    # 来自 /auto2 的分流
    location ~ ^/${UUID_CONFIRM}/auto2 {
      default_type 'text/plain; charset=utf-8';
      alias ${WORK_DIR}/subscribe/\$path2;
    }

    # 来自 /auto 的分流
    location ~ ^/${UUID_CONFIRM}/auto {
      default_type 'text/plain; charset=utf-8';
      alias ${WORK_DIR}/subscribe/\$path1;
    }

    location ~ ^/${UUID_CONFIRM}/(.*) {
      autoindex on;
      proxy_set_header X-Real-IP \$proxy_protocol_addr;
      default_type 'text/plain; charset=utf-8';
      alias ${WORK_DIR}/subscribe/\$1;
    }
"

  NGINX_CONF+="  }
}"

  echo "$NGINX_CONF" > ${WORK_DIR}/nginx.conf
}
