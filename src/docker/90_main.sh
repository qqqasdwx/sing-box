# Docker entrypoint and in-container configuration checker.
case "${1:-}" in
  check )
    routing_migrate_legacy || exit 1
    routing_check && info " Routing configuration is valid. " || exit 1
    exit 0
    ;;
  reload )
    error " Docker mode publishes custom routing only at container startup. Run: docker restart sing-box "
    ;;
esac

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
