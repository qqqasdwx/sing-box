# AetherCloud DynamicV6 网关

此分支将 AetherCloud DynamicV6 封装为一个隔离的 SOCKS5 网关，不会安装或配置
sing-box。Dante 接收的 TCP 和 UDP 流量会通过租用的动态 IPv6 地址出站。

## 网络模型

- 控制接口连接独立的双栈 Docker 网桥，负责访问 AetherCloud API、提供本地
  SOCKS5 监听，以及承载 SOCKS5 UDP 中继流量。
- WAN 接口连接 Docker 原生 ipvlan L2 网络，负责承载 DynamicV6 流量。
- 动态地址、邻居项、策略路由规则以及 MTU 1280 路由仅存在于容器网络命名空间。
- Compose 将 SOCKS5 发布到 `127.0.0.1:11080`，用于手工测试 TCP 连接。
- 宿主机上的 sing-box 应使用容器 ULA 地址 `fd53:ac::2:1080`，让 SOCKS5 TCP
  控制连接和 UDP 中继使用相同的地址族。
- 不会修改宿主机主网卡的地址和默认路由。

Docker 使用原生 ipvlan 网络驱动创建 WAN 接口，并在容器重启时自动重建。Docker
不保证两个容器接口的名称和顺序，因此容器按 Compose 分配的固定临时地址识别
控制接口与 WAN 接口。Docker 也会正常管理网桥、veth、防火墙和端口发布状态。
该方案与宿主机路由相互隔离，但并不代表宿主机上完全不会产生网络对象或网络操作。

## 安装

需要 Docker 和 Docker Compose v2。使用 root 用户执行一键安装命令：

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/qqqasdwx/sing-box/aethercloud/install.sh)
```

安装器会自动检测宿主机父接口、上游路由器 MAC 和 VM UUID，在
`/opt/aethercloud-v6/` 中生成 `.env` 和 `compose.yml`，然后拉取
`ghcr.io/qqqasdwx/aethercloud-v6:latest` 并执行 `docker compose up -d`。安装器
执行结束后不保留任何宿主机服务，容器的开机自启和故障重启由 Docker 负责。

以后升级时重新执行同一条命令即可。安装器会重新检测并写入最新的父接口、上游
路由器 MAC 和 VM UUID，同时保留用户配置和 SOCKS5 密码，然后拉取最新镜像并
重建容器。安装完成后，终端会输出一份包含实际用户名和密码的 sing-box 出站
JSON，可直接复制到 `custom/04_outbounds.json`。

仅在开发测试时，如需使用当前工作目录构建的镜像，而不是从 GHCR 拉取，可以使用
本地标签并明确跳过拉取：

```sh
sudo docker build -t aethercloud-v6:local .
sudo AETHERCLOUD_IMAGE=aethercloud-v6:local AETHERCLOUD_SKIP_PULL=true ./install.sh
```

后续重新安装时，安装器会从 `/opt/aethercloud-v6/.env` 读取镜像名称；如果该镜像
仅存在于本机，仍需传入 `AETHERCLOUD_SKIP_PULL=true`。

常用命令：

```sh
cd /opt/aethercloud-v6
docker compose ps
docker compose logs -f
docker compose restart
```

## sing-box 出站

使用容器的固定 ULA 地址配置普通 sing-box 出站。用户名和密码必须与
`/opt/aethercloud-v6/.env` 保持一致。如果修改了专用 IPv6 子网或容器地址，也要
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

完整配置见 [sing-box 路由示例](examples/sing-box/README.md)：

- [Google 全系强制使用 DynamicV6](examples/sing-box/google-all-v6/README.md)
- [仅将 Google IPv6 分流到 DynamicV6](examples/sing-box/google-selective-v6/README.md)

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

`AETHERCLOUD_PARENT`、`AETHERCLOUD_ROUTER_MAC` 和 `DYNAMICV6_VM_UUID` 由安装器
管理，每次运行都会重新检测并覆盖 `.env` 中的旧值，不应直接编辑。特殊网络环境
可以在执行安装器时临时指定其中任意值，例如：

```sh
AETHERCLOUD_PARENT=ens5 bash <(curl -fsSL https://raw.githubusercontent.com/qqqasdwx/sing-box/aethercloud/install.sh)
```

镜像、SOCKS5 凭据和端口、资源限制及 Docker 子网属于用户配置，重新安装时会保留。
编辑 `/opt/aethercloud-v6/.env` 中的这些字段后，在该目录执行
`docker compose up -d --force-recreate`。如果默认的 Docker IPv4/IPv6 子网与现有
本地网络或路由网络冲突，可以自定义这些专用子网。

镜像每 120 秒检查一次租约。如果 IPv6 地址发生变化，会替换容器地址和策略路由，
并重启 Dante，使新连接使用新地址。API 请求失败时会保留最后一个可用租约。

## 卸载

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/qqqasdwx/sing-box/aethercloud/uninstall.sh)
```

卸载器会保留 `/opt/aethercloud-v6/.env`，避免意外丢失凭据和本地配置。
