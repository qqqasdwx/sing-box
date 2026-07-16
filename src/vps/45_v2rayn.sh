# shellcheck shell=bash

build_v2rayn_hysteria2_json() {
  local remarks="$1"
  local address="$2"
  local port="$3"
  local password="$4"
  local server_name="$5"
  local certificate="$6"
  local up_mbps="$7"
  local down_mbps="$8"
  local realm_url="${9:-}"
  local hopping_ports="${10:-}"

  jq_exec -cn \
    --arg remarks "$remarks" \
    --arg address "$address" \
    --argjson port "$port" \
    --arg password "$password" \
    --arg server_name "$server_name" \
    --arg certificate "$certificate" \
    --argjson up_mbps "$up_mbps" \
    --argjson down_mbps "$down_mbps" \
    --arg realm_url "$realm_url" \
    --arg hopping_ports "$hopping_ports" '
      {
        ConfigType: 7,
        ConfigVersion: 4,
        Remarks: $remarks,
        Address: $address,
        Port: $port,
        Password: $password,
        StreamSecurity: "tls",
        AllowInsecure: "false",
        Sni: $server_name,
        Cert: $certificate,
        ProtoExtraObj: (
          {
            UpMbps: $up_mbps,
            DownMbps: $down_mbps
          }
          + (if $realm_url == "" then {} else {Hy2RealmUrl: $realm_url} end)
          + (if $hopping_ports == "" then {} else {Ports: $hopping_ports, HopInterval: "30s"} end)
        )
      }
    '
}
