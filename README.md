# sing-box downstream

这是 `qqqasdwx/sing-box`，一个基于 [fscarmen/sing-box](https://github.com/fscarmen/sing-box) 的独立下游版本。

本仓库的目标不是重新发明安装逻辑，而是把原脚本整理成可维护、可自动发布、Docker 与 VPS 行为一致的版本。上游变化通过 `upstream-main` 分支跟踪；我们只在审阅后把有价值的改动移植到 `main`。

变更记录见 [CHANGELOG.md](CHANGELOG.md)。与上游的行为差异见 [BEHAVIOR_DIFFS.md](BEHAVIOR_DIFFS.md)。当前跟踪的上游基线见 [`main` 分支的 UPSTREAM.md](https://github.com/qqqasdwx/sing-box/blob/main/UPSTREAM.md)。

## 和上游的主要区别

- 脚本源码已模块化：`src/vps/` 生成 `sing-box.sh`，`src/docker/` 生成 `docker_init.sh`。
- 仍发布单文件脚本：安装入口固定为 `release` 分支的 `sing-box.sh`，兼容 `bash <(wget -qO- ...)`。
- Docker 与 VPS 共用主要协议生成逻辑，减少两套行为不一致的问题。
- Docker 镜像发布到 GHCR：`ghcr.io/qqqasdwx/sing-box:latest`，不再推 Docker Hub。
- Docker Argo 认证复用 VPS 逻辑，支持 Json、Tunnel Token、Cloudflare API Token，并对无效 `ARGO_AUTH` 直接失败。
- `main` 是源码分支，`release` 是自动生成的发布分支，`upstream-main` 只用于观察上游。
- GitHub Actions 会校验打包结果、发布 `release` 分支、构建多架构 GHCR 镜像，并每天检查上游是否更新。

## 分支与发布模型

- `main`：实际开发分支，包含模块化源码、工具脚本和 Actions。
- `release`：自动生成，只保留运行产物、发布说明和 `examples/` 配置示例，例如 `sing-box.sh`、`docker_init.sh`、`Dockerfile`、`README.md`、`CHANGELOG.md`、`BEHAVIOR_DIFFS.md`。
- `upstream-main`：镜像 `fscarmen/main`，只作为对比和移植参考。

不要直接改 `release`。所有变更都应提交到 `main`，由 Action 生成发布分支和镜像。

## VPS 安装

交互安装：

```sh
bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh)
```

中文极速安装：

```sh
bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh) -l
```

英文极速安装：

```sh
bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh) -k
```

使用配置文件安装：

```sh
wget -O config.conf https://raw.githubusercontent.com/qqqasdwx/sing-box/release/config.conf
bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh) -f config.conf
```

`-f config.conf` 可用于首次安装，也可用于已安装后的配置更新。首次成功安装或后续成功更新后，脚本会先备份原 `config.conf`，再只取消注释并补齐实际生效或需要复用的值，例如 UUID、端口、节点名、Reality 私钥、协议密码、Argo 认证等，使其成为可复用状态文件。未启用或当前模式下不生效的配置会保持注释状态；回写不会修改文件权限。请自行保护这个文件的权限。

参数化安装示例：

```sh
bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh) \
  --LANGUAGE c \
  --CHOOSE_PROTOCOLS bcf \
  --START_PORT 8881 \
  --LOG_LEVEL warn \
  --NTP_SERVER pool.ntp.org \
  --NTP_INTERVAL 30m \
  --PORT_HYSTERIA2 443 \
  --SERVER_IP 203.0.113.10 \
  --SUBSCRIBE=true \
  --NODE_NAME_CONFIRM sing-box \
  --NODE_NAME_HYSTERIA2 sing-box-hy2
```

协议选择：`a` 为全部；`b` VLESS Reality；`c` Hysteria2；`d` Tuic；`e` ShadowTLS；`f` Shadowsocks；`g` Trojan；`h` VMess WS；`i` VLESS WS TLS；`j` H2 Reality；`k` gRPC Reality；`l` AnyTLS；`m` NaiveProxy。主机安装和 Docker 都支持单协议开关：`CHOOSE_PROTOCOLS` 留空且任意开关启用时，会按 `XTLS_REALITY`、`HYSTERIA2`、`TUIC`、`SHADOWTLS`、`SHADOWSOCKS`、`TROJAN`、`VMESS_WS`、`VLESS_WS`、`H2_REALITY`、`GRPC_REALITY`、`ANYTLS`、`NAIVE` 生成协议列表；`CHOOSE_PROTOCOLS=switch` 会强制按这些开关生成，且至少要启用一个。开关值为 `true/1/y/yes/on` 时启用。`LOG_LEVEL` 可设置 sing-box 服务端日志级别，支持 `trace`、`debug`、`info`、`warn`、`error`、`fatal`、`panic`，默认 `error`。`NTP_ENABLED`、`NTP_SERVER`、`NTP_SERVER_PORT`、`NTP_INTERVAL` 可配置 sing-box 内建 NTP 客户端，默认 `true / time.apple.com / 123 / 60m`。`FINGER_PRINT` 可设置客户端 TLS 指纹，默认 `chrome`，常用值为 `chrome` 或 `firefox`。

协议端口可以逐个覆盖：`PORT_XTLS_REALITY`、`PORT_HYSTERIA2`、`PORT_TUIC`、`PORT_SHADOWTLS`、`PORT_SHADOWSOCKS`、`PORT_TROJAN`、`PORT_VMESS_WS`、`PORT_VLESS_WS`、`PORT_H2_REALITY`、`PORT_GRPC_REALITY`、`PORT_ANYTLS`、`PORT_NAIVE`。未填写的协议继续按 `START_PORT` 和 `CHOOSE_PROTOCOLS` 顺序递增，重复端口会直接报错。除 WebSocket 协议外，这些端口会作为客户端连接端口导出；`PORT_VMESS_WS` 和 `PORT_VLESS_WS` 是源站监听端口，Argo 下是本机内部回源端口，Origin Rules 下是 Cloudflare 回源端口，客户端连接端口由 `CDN_PORT` 决定（默认 VMess WS 为 80，VLESS WS TLS 为 443）。已安装后也可以通过 `sb -d` 的监听端口面板逐个修改。

VPS 上通过菜单修改监听端口、UUID、密码、Reality 参数、SNI、节点名或 Hysteria2 Realm 时，脚本会先对包含自定义路由在内的完整配置执行 `sing-box check`，检查成功后向 sing-box 主进程发送 HUP，并确认 PID 未变化且服务仍在运行。协议增加或删除还会联动服务文件、nginx、Argo 和防火墙，因此继续使用完整停启流程。执行 `sb -v` 更新 sing-box 时，会先用新二进制检查当前配置；不兼容时在替换文件和停止服务之前中止。Docker 更新同样执行新二进制预检，但运行配置仍通过重启容器生效。

节点名称优先级：单协议节点名 > 全局 `NODE_NAME_CONFIRM` > 默认主机名。支持的单协议变量包括 `NODE_NAME_XTLS_REALITY`、`NODE_NAME_HYSTERIA2`、`NODE_NAME_TUIC`、`NODE_NAME_SHADOWTLS`、`NODE_NAME_SHADOWSOCKS`、`NODE_NAME_TROJAN`、`NODE_NAME_VMESS_WS`、`NODE_NAME_VLESS_WS`、`NODE_NAME_H2_REALITY`、`NODE_NAME_GRPC_REALITY`、`NODE_NAME_ANYTLS`、`NODE_NAME_NAIVE`。

## 自定义出站与路由

安装时会生成两份唯一源配置：

- `/etc/sing-box/custom/03_route.json`：完整的 `route` 配置。
- `/etc/sing-box/custom/04_outbounds.json`：完整的 `outbounds` 配置。

新生成的默认配置包含 MetaCubeX `sing` 分支的 `geosite-google` 和 `geosite-openai` 两个远程规则集，更新周期使用 sing-box 默认值。`api.openai.com` 优先解析 IPv4，OpenAI 与 Google 规则集优先解析 IPv6，两者最终都明确使用 `direct` 出站。已有 `custom/` 文件属于用户配置，更新脚本不会替换其中的规则集 URL。项目不内置 WARP，也不执行 OpenAI 可用性检测。sing-box 不直接读取 `custom/`；脚本会把两份源配置合并为 `/etc/sing-box/conf/03_routing.json`。修改后先检查，再发布并热重载：

```sh
sb check
sb reload
```

`sb check` 会在临时目录中连同其余 `conf/` 文件执行完整的 `sing-box check`，不修改当前运行配置。`sb reload` 只有在同样的检查成功后才原子替换运行配置并发送 HUP；检查失败时，当前配置和进程不变。开机或服务重启只读取最后一次成功发布的 `conf/`。旧版的 `01_outbounds.json`、`03_route.json` 和 `08_custom_route.json` 会在首次检查、重载或更新时迁移到 `custom/`。项目不再内置 WARP endpoint；升级时会删除所有引用旧 `warp-ep` 的路由和旧 endpoint，Hysteria2 Realm 与 STUN 功能不受影响。

完整配置见 [路由示例索引](examples/routing/README.md)：

- [Google 全系使用指定 IPv4](examples/routing/google-v4/README.md)
- [Google 全系使用宿主机原生 IPv6](examples/routing/google-native-v6/README.md)

示例按场景提供完整的 `03_route.json` 和 `04_outbounds.json`，不会改变默认安装行为。

## Docker 使用

Docker 镜像：

```sh
docker pull ghcr.io/qqqasdwx/sing-box:latest
```

Compose 示例见 [docker-compose.example.yml](docker-compose.example.yml)。示例文件列出了 Docker 支持的环境变量，并包含用临时镜像生成 `UUID_CONFIRM` 和 `REALITY_PRIVATE` 的命令。

最小示例：

```sh
docker run -d --name sing-box --network host --restart unless-stopped \
  -v "$PWD/custom:/sing-box/custom" \
  -e LANGUAGE=c \
  -e CHOOSE_PROTOCOLS=bcf \
  -e START_PORT=8881 \
  -e LOG_LEVEL=warn \
  -e NTP_SERVER=pool.ntp.org \
  -e NTP_INTERVAL=30m \
  -e SUBSCRIBE=true \
  -e NODE_NAME_CONFIRM=sing-box \
  -e NODE_NAME_HYSTERIA2=sing-box-hy2 \
  ghcr.io/qqqasdwx/sing-box:latest
```

Docker 模式把宿主机 `./custom` 挂载到 `/sing-box/custom`。首次启动会在空目录中生成与 VPS 相同的默认文件；每次容器启动都会先合并配置并执行完整检查，失败时容器会明确退出，不会回退到其他配置。修改后使用：

```sh
docker exec sing-box sb check
docker restart sing-box
```

Docker 不做在线重载；重启的是 sing-box 容器，不是 Docker daemon。`conf/03_routing.json` 是容器内的运行产物，不需要持久化。

固定 Argo 示例：

```sh
docker run -d --name sing-box --network host --restart unless-stopped \
  -v "$PWD/custom:/sing-box/custom" \
  -e LANGUAGE=c \
  -e CHOOSE_PROTOCOLS=a \
  -e START_PORT=8881 \
  -e PORT_NGINX=8899 \
  -e ARGO=true \
  -e ARGO_DOMAIN=sb.example.com \
  -e ARGO_AUTH='REDACTED_JSON_TOKEN_OR_CF_API_TOKEN' \
  ghcr.io/qqqasdwx/sing-box:latest
```

`START_PORT` 是默认协议端口基准。每个协议都可以用对应 `PORT_*` 单独覆盖；未覆盖的协议按选择顺序从 `START_PORT` 递增。`LOG_LEVEL` 可设置 sing-box 服务端日志级别，默认 `error`。`NTP_ENABLED`、`NTP_SERVER`、`NTP_SERVER_PORT`、`NTP_INTERVAL` 可配置 sing-box 内建 NTP 客户端，默认 `true / time.apple.com / 123 / 60m`。`FINGER_PRINT` 可设置客户端 TLS 指纹，默认 `chrome`。`PORT_VMESS_WS` 和 `PORT_VLESS_WS` 通常保持为空，让脚本自动分配即可；用户侧连接端口看 `CDN_PORT`。`SERVER_IP` 可选；Docker 启动时留空会自动检测公网 IPv4/IPv6。启用订阅或 Argo 时，`PORT_NGINX` 是 nginx 回源端口；未指定时会从 `START_PORT + 已选协议数量` 开始选择，并避开已选协议端口。

## Throne 设置 ShadowTLS 方法

脚本会输出两条 Throne 链接。把两条链接导入 Throne 后，手动创建链式代理，并按 `ShadowTLS -> Shadowsocks` 的顺序选择这两个节点；顺序反了会导致连接失败。

## 开发维护

修改脚本时先改 `src/`，再生成根目录单文件：

```sh
tools/bundle.sh
bash -n sing-box.sh docker_init.sh
tools/bundle.sh --check
bash tests/test-safe-reload.sh
find examples/routing -type f -name '*.json' -print0 | xargs -0 -r -n1 jq empty
```

本地生成发布目录：

```sh
tools/prepare-release.sh /tmp/sing-box-release
docker build -t sing-box:local /tmp/sing-box-release
```

上游更新由 `Upstream watch` Action 每天检查。如果有更新，会创建 GitHub Issue；处理方式是审阅 `fscarmen/main` 与 `upstream-main` 的差异，把需要的部分移植到 `main`，再更新 `upstream-main` 的跟踪提交。

## 安全说明

不要提交真实的 `ARGO_AUTH`、Cloudflare API Token、UUID、Reality 私钥、证书、服务器 IP 或生产域名。文档和示例必须使用脱敏值。
