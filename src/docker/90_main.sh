
# 传参
while getopts ":Vv" OPTNAME; do
  case "${OPTNAME,,}" in
    v ) ACTION=update
  esac
done

# 主流程
case "$ACTION" in
  update )
    update_sing-box
    ;;
  * )
    install
    # 用 s6-overlay 作为 PID 1 承载守护
    exec /init
esac