# AetherCloud DynamicV6 网关

此分支将 AetherCloud DynamicV6 封装为一个隔离的 SOCKS5 网关，不会安装或配置
sing-box。Dante 接收的 TCP 和 UDP 流量会通过租用的动态 IPv6 地址出站。

## 网络模型

- 控制接口连接独立的 IPv4 Docker 网桥，负责访问 AetherCloud API、提供本地
  SOCKS5 监听，以及承载 SOCKS5 UDP 中继流量。
- WAN 接口连接 Docker 原生 IPv6 ipvlan L2 网络。容器启动后在这个接口内配置
  DynamicV6 地址、邻居项和策略路由。
- 每条动态租约使用独立的源地址策略路由和 Dante 进程。容器端口从 `1080`
  依次分配，第一条租约使用 `1080`，第二条使用 `1081`。
- 动态地址、邻居项、策略路由规则以及 MTU 1280 路由仅存在于容器网络命名空间。
- Compose 只将第一个 SOCKS5 端口发布到 `127.0.0.1:11080`，用于手工测试 TCP
  连接。其他出口通过容器桥接地址和各自端口访问。
- 宿主机上的 sing-box 应使用 `172.30.53.2` 和安装器输出的端口。SOCKS5 控制
  连接使用 IPv4 不影响代理 IPv6 目标，UDP 中继也通过这个可直达的容器地址传输。
- 不会修改宿主机主网卡的地址和默认路由。

Docker 使用原生 ipvlan 网络驱动创建 WAN 接口，并在容器重启时自动重建。Docker
不保证两个容器接口的名称和顺序，因此容器按 Compose 分配的固定临时地址识别
控制接口与 WAN 接口。控制 bridge 只启用 IPv4，避免 Docker bridge 开启宿主机
IPv6 转发并影响依赖 RA 的宿主机默认路由；IPv6 ipvlan 不需要宿主机承担三层转发。
Docker 仍会正常管理网桥、veth、防火墙和端口发布状态。
该方案与宿主机路由相互隔离，但并不代表宿主机上完全不会产生网络对象或网络操作。

不要同时运行商家提供的宿主机 DynamicV6 脚本和本容器。两者会把同一租约地址
分别配置到宿主机和 ipvlan 容器，造成 IPv6 地址冲突。

## 安装

需要 Docker 和 Docker Compose v2。使用 root 用户执行一键安装命令：

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/qqqasdwx/sing-box/aethercloud/install.sh)
```

安装器会自动检测宿主机父接口和 VM UUID，在
`/opt/aethercloud-v6/` 中生成 `.env` 和 `compose.yml`，然后拉取
`ghcr.io/qqqasdwx/aethercloud-v6:latest` 并执行 `docker compose up -d`。安装器
执行结束后不保留任何宿主机服务，容器的开机自启和故障重启由 Docker 负责。

以后升级时重新执行同一条命令即可。安装器会重新检测并写入最新的父接口和
VM UUID，同时保留用户配置和 SOCKS5 密码，然后拉取最新镜像并
重建容器。安装完成后，终端会按当前有效租约输出所有包含实际用户名和密码的
sing-box 出站对象，可加入 `custom/04_outbounds.json`。

### 从旧版 IPv6 控制网络升级

曾使用 `fd53:ac::2:1080` 作为 sing-box SOCKS 出站的旧版用户，可以直接重新执行
上述安装命令。安装器会保留 `.env` 中的凭据，删除旧控制网络并重建容器。升级后
必须把 sing-box 出站的 `server` 从 `fd53:ac::2` 改为 `172.30.53.2`，再执行
`sb reload`；Docker 版 sing-box 则重启容器。

旧 IPv6 bridge 可能已经将宿主机 `net.ipv6.conf.all.forwarding` 改为 `1`。删除
bridge 后这个内核状态不一定自动恢复，安装器检测到时会发出警告，但不会擅自关闭
转发，以免影响宿主机上的其他路由或容器业务。升级后检查：

```sh
sysctl net.ipv6.conf.all.forwarding
ip -6 route show default
```

依赖 RA 且不承担 IPv6 转发的普通 VPS，预期应为 `forwarding = 0`，并存在
`default via ...`。可以在测试机重启后再次确认；若重启后仍为 `1`，还需检查其他
Docker IPv6 bridge 或持久化 sysctl 配置。

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

使用容器的固定 IPv4 桥接地址配置普通 sing-box 出站。用户名和密码必须与
`/opt/aethercloud-v6/.env` 保持一致。如果修改了专用 IPv4 子网或容器地址，也要
同步修改 `server`。第一条租约继续使用兼容名称 `aethercloud` 和端口 `1080`；
后续租约使用 `aethercloud-2`、`aethercloud-3` 和端口 `1081`、`1082`。

```json
{
  "type": "socks",
  "tag": "aethercloud",
  "server": "172.30.53.2",
  "server_port": 1080,
  "version": "5",
  "username": "aethercloud",
  "password": "replace-with-the-generated-password"
}
```

例如第二条租约对应：

```json
{
  "type": "socks",
  "tag": "aethercloud-2",
  "server": "172.30.53.2",
  "server_port": 1081,
  "version": "5",
  "username": "aethercloud",
  "password": "replace-with-the-generated-password"
}
```

将回环地址发布的 `127.0.0.1:11080` 用于此出站时，TCP 可以正常工作，但 SOCKS5
UDP 会使用协商得到的动态中继端口，固定的 Docker 端口发布无法转发该端口。因此
sing-box 必须直接连接 `172.30.53.2`，回环端口仅用于手工 TCP 测试。

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

主容器必须使用 host 网络，或者具备到 AetherCloud Docker 网络和 `172.30.53.2`
的 IPv4 可达性。不要持久化或直接修改生成的 `conf/03_routing.json`。

## 配置

`AETHERCLOUD_PARENT` 和 `DYNAMICV6_VM_UUID` 由安装器管理，每次运行都会优先
重新检测并覆盖 `.env` 中的旧值。动态网关 MAC 由容器内核通过 NDP 解析，不需要
写入配置。特殊网络环境可以在执行安装器时临时指定其中任意值，例如：

```sh
AETHERCLOUD_PARENT=ens5 bash <(curl -fsSL https://raw.githubusercontent.com/qqqasdwx/sing-box/aethercloud/install.sh)
```

镜像、SOCKS5 凭据和端口、资源限制及 Docker 子网属于用户配置，重新安装时会保留。
编辑 `/opt/aethercloud-v6/.env` 中的这些字段后，在该目录执行
`docker compose up -d --force-recreate`。如果默认的 Docker IPv4 子网与现有
本地网络或路由网络冲突，可以自定义这些专用子网。

镜像每 120 秒检查一次全部租约，并将租约与固定槽位对应。匹配优先使用
`wg_interface` 和租约前缀，不依赖 API 数组顺序。槽位保存在
`/opt/aethercloud-v6/state/leases.json`，容器升级或重启不会重新编号。

如果某条 IPv6 发生变化，只更新对应地址、策略路由和 Dante 进程，其他出口不受
影响。已有连接会因源地址变化而断开。API 请求失败时保留当前配置；一次成功响应中
暂时缺少某条租约时，默认连续缺少 3 次后才停用该出口，而且不会把它自动改走其他
IPv6。重新出现的相同租约会恢复原端口。

`AETHERCLOUD_MAX_LEASES` 默认限制为 `16`。`AETHERCLOUD_MISSING_GRACE` 控制停用
出口前允许连续缺少的刷新次数，默认 `3`。通常不需要修改这两个值。查看当前活跃
出口和持久化槽位：

```sh
docker exec aethercloud-v6 jq . /run/aethercloud/active-leases.json
docker exec aethercloud-v6 jq . /var/lib/aethercloud/leases.json
```

## 卸载

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/qqqasdwx/sing-box/aethercloud/uninstall.sh)
```

卸载器会保留 `/opt/aethercloud-v6/.env` 和 `state/`，避免意外丢失凭据及稳定的
出口端口映射。
