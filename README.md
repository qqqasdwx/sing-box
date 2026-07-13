# AetherCloud DynamicV6 网关

此分支将 AetherCloud DynamicV6 封装为一个隔离的 SOCKS5 网关，不会安装或配置
sing-box。Dante 接收的 TCP 和 UDP 流量会通过租用的动态 IPv6 地址出站。

## 网络模型

- `eth0` 使用独立的双栈 Docker 网桥，负责访问 AetherCloud API、提供本地
  SOCKS5 监听，以及承载 SOCKS5 UDP 中继流量。
- 名为 `wan0` 的 ipvlan L2 接口负责承载 DynamicV6 流量。
- 动态地址、邻居项、策略路由规则以及 MTU 1280 路由仅存在于容器网络命名空间。
- 宿主机运行器将 SOCKS5 发布到 `127.0.0.1:11080`，用于手工测试 TCP 连接。
- 宿主机上的 sing-box 应使用容器 ULA 地址 `fd53:ac::2:1080`，让 SOCKS5 TCP
  控制连接和 UDP 中继使用相同的地址族。
- 不会修改宿主机主网卡的地址和默认路由。

运行器会先在宿主机内核中临时创建 ipvlan 设备，再将其移动到容器网络命名空间。
Docker 也会正常管理网桥、veth、防火墙和端口发布状态。该方案与宿主机路由相互
隔离，但并不代表宿主机上完全不会产生网络对象或网络操作。

## 安装

需要 Docker 和 systemd。在 `aethercloud` 分支的工作目录中执行：

```sh
sudo ./install.sh
```

安装器会创建 `/etc/aethercloud-v6.env`，生成随机 SOCKS5 密码，拉取
`ghcr.io/qqqasdwx/sing-box:aethercloud`，然后启动
`aethercloud-v6.service`。

如需测试当前工作目录构建的镜像，而不是从 GHCR 拉取，可以使用本地标签并明确
跳过拉取：

```sh
sudo docker build -t aethercloud-v6:local .
sudo AETHERCLOUD_IMAGE=aethercloud-v6:local AETHERCLOUD_SKIP_PULL=true ./install.sh
```

后续重新安装时，安装器会从 `/etc/aethercloud-v6.env` 读取镜像名称；如果该镜像
仅存在于本机，仍需传入 `AETHERCLOUD_SKIP_PULL=true`。

常用命令：

```sh
sudo aethercloud-v6 status
sudo aethercloud-v6 test
sudo aethercloud-v6 logs
sudo systemctl restart aethercloud-v6
```

## sing-box 出站

使用容器的固定 ULA 地址配置普通 sing-box 出站。用户名和密码必须与
`/etc/aethercloud-v6.env` 保持一致。如果修改了专用 IPv6 子网或容器地址，也要
同步修改 `server`。

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

将回环地址发布的端口用于此出站时，TCP 可以正常工作，但 IPv4 SOCKS5 控制连接
不适合 sing-box 的 IPv6 UDP 中继。

geosite/geoip 规则以及何时选择此出站，仍由主 sing-box 配置负责。

使用 `qqqasdwx/sing-box` 主项目的 Docker 镜像时，在绑定挂载的
`custom/04_outbounds.json` 中保留 `direct` 对象，并将上述对象加入
`outbounds` 数组。在 `custom/03_route.json` 的规则中选择 `aethercloud` 标签，
然后检查配置并重启主容器：

```sh
docker exec sing-box sb check
docker restart sing-box
```

主容器必须使用 host 网络，或者具备到 AetherCloud Docker 网络和 `fd53:ac::2` 的
IPv6 可达性。不要持久化或直接修改生成的 `conf/03_routing.json`。

## 配置

编辑 `/etc/aethercloud-v6.env` 后重启服务。未设置 `AETHERCLOUD_PARENT` 时，
安装器会根据 IPv4 默认路由自动检测父接口。如果默认的 Docker IPv4/IPv6 子网与
现有本地网络或路由网络冲突，也可以自定义这些专用子网。

镜像每 120 秒检查一次租约。如果 IPv6 地址发生变化，会替换容器地址和策略路由，
并重启 Dante，使新连接使用新地址。API 请求失败时会保留最后一个可用租约。

## 卸载

```sh
sudo ./uninstall.sh
```

卸载器会保留 `/etc/aethercloud-v6.env`，避免意外丢失凭据和本地配置。
