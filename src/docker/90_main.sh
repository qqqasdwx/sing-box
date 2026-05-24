# Docker entrypoint.
while getopts ":Vv" OPTNAME; do
  case "${OPTNAME,,}" in
    v ) ACTION=update ;;
  esac
done

case "$ACTION" in
  update )
    docker_update_sing_box
    ;;
  * )
    docker_install
    exec /init
    ;;
esac
