# AetherCloud DynamicV6 Gateway

This branch packages AetherCloud DynamicV6 as an isolated SOCKS5 gateway. It
does not install or configure sing-box. TCP and UDP traffic received by Dante
leaves through the leased IPv6 address.

## Network model

- A dedicated dual-stack Docker bridge on `eth0` handles the AetherCloud API,
  the local SOCKS5 listener, and SOCKS5 UDP relay traffic.
- An `ipvlan` L2 interface named `wan0` carries DynamicV6 traffic.
- The address, neighbor entry, policy rule, and MTU 1280 route exist only in
  the container network namespace.
- The host runner publishes SOCKS5 on `127.0.0.1:11080` for manual TCP access.
- Host sing-box instances should use the container ULA `fd53:ac::2:1080` so
  SOCKS5 TCP control and UDP relay traffic use the same address family.
- The host primary interface address and default routes are not modified.

The runner temporarily creates an ipvlan device in the host kernel before
moving it into the container namespace. Docker also manages its normal bridge,
veth, firewall, and port-publishing state. This is isolated from host routing,
but it is not equivalent to zero host network activity.

## Install

Docker and systemd are required. From a checkout of the `aethercloud` branch:

```sh
sudo ./install.sh
```

The installer creates `/etc/aethercloud-v6.env` with a random SOCKS5 password,
pulls `ghcr.io/qqqasdwx/sing-box:aethercloud`, and starts
`aethercloud-v6.service`.

To test an image built from the checkout instead of pulling GHCR, use a local
tag and explicitly skip the pull:

```sh
sudo docker build -t aethercloud-v6:local .
sudo AETHERCLOUD_IMAGE=aethercloud-v6:local AETHERCLOUD_SKIP_PULL=true ./install.sh
```

On later reinstalls the image name is read from `/etc/aethercloud-v6.env`, but
`AETHERCLOUD_SKIP_PULL=true` must still be passed when that name is only local.

Useful commands:

```sh
sudo aethercloud-v6 status
sudo aethercloud-v6 test
sudo aethercloud-v6 logs
sudo systemctl restart aethercloud-v6
```

## sing-box outbound

Use the fixed container ULA as a normal sing-box outbound. Keep the credentials
synchronized with `/etc/aethercloud-v6.env`. If the dedicated IPv6 subnet or
container address is customized, update `server` to match.

```json
{
  "type": "socks",
  "tag": "aethercloud",
  "server": "fd53:ac::2",
  "server_port": 1080,
  "version": "5",
  "username": "aethercloud",
  "password": "replace-with-the-generated-password"
}
```

Using the loopback-published endpoint for this outbound works for TCP, but the
IPv4 SOCKS5 control connection is not suitable for sing-box IPv6 UDP relay.

The main sing-box configuration remains responsible for geosite/geoip rules
and selecting this outbound.

With the `qqqasdwx/sing-box` main Docker image, keep the `direct` object and
add this object to the `outbounds` array in the bind-mounted
`custom/04_outbounds.json`. Select the `aethercloud` tag from rules in
`custom/03_route.json`, then validate and restart the main container:

```sh
docker exec sing-box sb check
docker restart sing-box
```

The main container must use host networking, or otherwise have IPv6 reachability
to the AetherCloud Docker network and `fd53:ac::2`. Do not persist or edit its
generated `conf/03_routing.json` directly.

## Configuration

Edit `/etc/aethercloud-v6.env`, then restart the service. The parent interface
is detected from the IPv4 default route unless `AETHERCLOUD_PARENT` is set.
The dedicated Docker IPv4/IPv6 subnets are also configurable when the defaults
overlap with existing local or routed networks.

The image checks the lease every 120 seconds. If the IPv6 address changes, it
replaces the container address and policy route and restarts Dante for new
connections. An API failure keeps the last working lease in place.

## Remove

```sh
sudo ./uninstall.sh
```

The uninstaller preserves `/etc/aethercloud-v6.env` so credentials and local
settings are not lost accidentally.
