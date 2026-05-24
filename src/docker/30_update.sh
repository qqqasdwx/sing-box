# Sing-box 的最新版本
update_sing-box() {
  local ONLINE=$(check_latest_sing-box)
  local LOCAL=$(${WORK_DIR}/sing-box version | awk '/version/{print $NF}')
  if [ -n "$ONLINE" ]; then
    if [[ "$ONLINE" != "$LOCAL" ]]; then
      cp -f ${WORK_DIR}/sing-box /tmp/sing-box.bak
      wget https://github.com/SagerNet/sing-box/releases/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz -O- | tar xz -C /tmp sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box
      mv /tmp/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box ${WORK_DIR}/sing-box
      local SING_BOX_PID_OLD=$(ps aux | grep '[s]ing-box run' | awk '{print $1}')
      kill -9 ${SING_BOX_PID_OLD}
      sleep 1
      local SING_BOX_PID_NEW=$(ps aux | grep '[s]ing-box run' | awk '{print $1}')
      until [[ "${SING_BOX_PID_NEW}" =~ ^[0-9]+$ ]]; do
        (( i++ ))
        [ "$i" -gt 5 ] && break
        sleep 1
        local SING_BOX_PID_NEW=$(ps aux | grep '[s]ing-box run' | awk '{print $1}')
      done
      if [[ "${SING_BOX_PID_NEW}" =~ ^[0-9]+$ ]]; then
        info " Sing-box v${ONLINE} 更新成功！"
      else
        cp -f /tmp/sing-box.bak ${WORK_DIR}/sing-box
        warning " Sing-box v${ONLINE} 运行不成功，使用回旧版本 v${LOCAL} 更新成功！"
      fi
      rm -rf ${WORK_DIR}/sing-box-$ONLINE-linux-$SING_BOX_ARCH /tmp/sing-box.bak
    else
      info " Sing-box v${ONLINE} 已是最新版本！"
    fi
  else
    warning " 获取不了在线版本，请稍后再试！"
  fi
}
