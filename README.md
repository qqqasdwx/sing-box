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

GitHub 默认直连。只有在当前网络无法直连时才设置 URL 前缀；该服务必须支持“前缀 + 原始 GitHub URL”的形式：

```sh
export GH_PROXY='https://your-trusted-prefix.example/'
bash <(wget -qO- "${GH_PROXY}https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh") -f config.conf
```

把同一值写入 `config.conf` 的 `GH_PROXY` 后，安装过程、版本下载和生成的 `sb` 快捷命令都会继续使用它。也可以通过 `--GH_PROXY` 覆盖配置文件中的值；优先级为命令行、配置文件、环境变量。未设置时脚本不会探测或切换到任何第三方 GitHub 代理。

`-f config.conf` 可用于首次安装，也可用于已安装后的配置更新。首次成功安装或后续成功更新后，脚本会先备份原 `config.conf`，再只取消注释并补齐实际生效或需要复用的值，例如 UUID、端口、节点名、Reality 私钥、协议密码、Argo 认证等，使其成为可复用状态文件。未启用或当前模式下不生效的配置会保持注释状态；回写不会修改文件权限。请自行保护这个文件的权限。

参数化安装示例：

```sh
bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh) \
  --LANGUAGE c \
  --CHOOSE_PROTOCOLS bcf \
  --START_PORT 8881 \
  --LOG_LEVEL warn \
  --PORT_HYSTERIA2 443 \
  --SERVER_IP 203.0.113.10 \
  --SUBSCRIBE=true \
  --NODE_NAME_CONFIRM sing-box \
  --NODE_NAME_HYSTERIA2 sing-box-hy2
```

协议选择：`a` 为全部；`b` VLESS Reality；`c` Hysteria2；`d` Tuic；`e` ShadowTLS；`f` Shadowsocks；`g` Trojan；`h` VMess WS；`i` VLESS WS TLS；`j` H2 Reality；`k` gRPC Reality；`l` AnyTLS；`m` NaiveProxy。主机安装和 Docker 都支持单协议开关：`CHOOSE_PROTOCOLS` 留空且任意开关启用时，会按 `XTLS_REALITY`、`HYSTERIA2`、`TUIC`、`SHADOWTLS`、`SHADOWSOCKS`、`TROJAN`、`VMESS_WS`、`VLESS_WS`、`H2_REALITY`、`GRPC_REALITY`、`ANYTLS`、`NAIVE` 生成协议列表；`CHOOSE_PROTOCOLS=switch` 会强制按这些开关生成，且至少要启用一个。开关值为 `true/1/y/yes/on` 时启用。`LOG_LEVEL` 可设置 sing-box 服务端日志级别，支持 `trace`、`debug`、`info`、`warn`、`error`、`fatal`、`panic`，默认 `error`。`FINGER_PRINT` 可设置客户端 TLS 指纹，默认 `chrome`，常用值为 `chrome` 或 `firefox`。sing-box 使用宿主机或容器运行环境的系统时间，本项目不再生成内建 NTP 客户端配置；请在宿主机上独立维护时间同步。

TCP Brutal 不再由本项目代安装。脚本只检测宿主机是否已有 `brutal` 内核模块，并在检测成功时生成相应客户端参数；需要该功能时应先由用户按自己的系统和内核环境独立安装、验证和维护。

协议端口可以逐个覆盖：`PORT_XTLS_REALITY`、`PORT_HYSTERIA2`、`PORT_TUIC`、`PORT_SHADOWTLS`、`PORT_SHADOWSOCKS`、`PORT_TROJAN`、`PORT_VMESS_WS`、`PORT_VLESS_WS`、`PORT_H2_REALITY`、`PORT_GRPC_REALITY`、`PORT_ANYTLS`、`PORT_NAIVE`。未填写的协议继续按 `START_PORT` 和 `CHOOSE_PROTOCOLS` 顺序递增，重复端口会直接报错。除 WebSocket 协议外，这些端口会作为客户端连接端口导出；`PORT_VMESS_WS` 和 `PORT_VLESS_WS` 是源站监听端口，Argo 下是本机内部回源端口，Origin Rules 下是 Cloudflare 回源端口，客户端连接端口由 `CDN_PORT` 决定（默认 VMess WS 为 80，VLESS WS TLS 为 443）。已安装后也可以通过 `sb -d` 的监听端口面板逐个修改。

VPS 上通过菜单修改监听端口、UUID、密码、Reality 参数、SNI、节点名或 Hysteria2 Realm 时，脚本会先对包含自定义路由在内的完整配置执行 `sing-box check`，检查成功后向 sing-box 主进程发送 HUP，并确认 PID 未变化且服务仍在运行。协议增加或删除还会联动服务文件、nginx、Argo 和防火墙，因此继续使用完整停启流程。

执行 `sb -v` 更新 sing-box 时，会先用新二进制检查当前配置。如果新版只是不兼容项目托管的基础配置，脚本会在临时目录重建 `00_log.json`、`04_experimental.json`、`05_dns.json` 和 `07_http_clients.json`，保留日志等级、DNS 策略、协议入站以及 `custom/` 路由和出站，并再次使用新二进制检查。候选配置通过后仍需用户明确确认才会应用。内核与完整 `conf/` 作为同一个事务切换；新服务启动失败时两者一起回滚。协议配置或 `custom/` 本身不兼容时不会自动改写，而是保留当前服务并显示检查错误。Docker 更新同样执行新二进制预检，但运行配置仍通过重启容器生效。

使用 `-f config.conf` 更新时，如果 `TLS_SERVER` 未变化，现有自签证书、私钥和 SNI 有效匹配，脚本会保留原证书固定值；只有 SNI 改变、证书失效或密钥不匹配时才重新生成。这样升级后无需刷新 Hysteria2、TUIC、Trojan、AnyTLS 和 Naive 客户端配置。

节点名称优先级：单协议节点名 > 全局 `NODE_NAME_CONFIRM` > 默认主机名。支持的单协议变量包括 `NODE_NAME_XTLS_REALITY`、`NODE_NAME_HYSTERIA2`、`NODE_NAME_TUIC`、`NODE_NAME_SHADOWTLS`、`NODE_NAME_SHADOWSOCKS`、`NODE_NAME_TROJAN`、`NODE_NAME_VMESS_WS`、`NODE_NAME_VLESS_WS`、`NODE_NAME_H2_REALITY`、`NODE_NAME_GRPC_REALITY`、`NODE_NAME_ANYTLS`、`NODE_NAME_NAIVE`。

## 客户端订阅

客户端配置由安装脚本本地生成，不下载外部模板：

- `clash`：使用本机 `proxies` 地址的 provider 配置，包含手动选择、自动测速和直连。
- `clash2`：节点直接内嵌在文件中的 Clash 配置。
- `sing-box`：适用于 SFI、SFA、SFM 的基础 TUN + mixed 配置，包含手动选择、自动测速和直连。
- `v2rayn`、`throne`、`shadowrocket`、`proxies`：继续由现有协议导出逻辑生成。

脚本直接输出可复制的订阅链接，不生成或展示二维码。

## 自定义出站与路由

安装时会生成两份唯一源配置：

- `/etc/sing-box/custom/03_route.json`：完整的 `route` 配置。
- `/etc/sing-box/custom/04_outbounds.json`：完整的 `outbounds` 配置。

新生成的默认配置包含 MetaCubeX `sing` 分支的 `geosite-google` 和 `geosite-openai` 两个远程规则集，更新周期使用 sing-box 默认值。`api.openai.com` 优先解析 IPv4，OpenAI 与 Google 规则集优先解析 IPv6，两者最终都明确使用 `direct` 出站。已有 `custom/` 文件属于用户配置，更新脚本不会替换其中的规则集 URL。项目不内置 WARP，也不执行 OpenAI 可用性检测。sing-box 不直接读取 `custom/`；脚本会把两份源配置合并为 `/etc/sing-box/conf/03_routing.json`。修改后先检查，再发布并热重载：

```sh
sb check
sb reload
```

`sb check` 会在临时目录中连同其余 `conf/` 文件执行完整的 `sing-box check`，并额外确认每条路由引用的 `outbound` tag 都能在 `outbounds` 或 `endpoints` 中找到，不修改当前运行配置。`sb reload` 只有在同样的检查成功后才原子替换运行配置并发送 HUP；检查失败时，当前配置和进程不变。开机或服务重启只读取最后一次成功发布的 `conf/`。旧版的 `01_outbounds.json`、`03_route.json` 和 `08_custom_route.json` 会在首次检查、重载或更新时迁移到 `custom/`。项目不再内置 WARP endpoint；升级时会删除所有引用旧 `warp-ep` 的路由和旧 endpoint，Hysteria2 Realm 与 STUN 功能不受影响。

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
  -v sing-box-cert:/sing-box/cert \
  -e LANGUAGE=c \
  -e CHOOSE_PROTOCOLS=bcf \
  -e START_PORT=8881 \
  -e LOG_LEVEL=warn \
  -e SUBSCRIBE=true \
  -e NODE_NAME_CONFIRM=sing-box \
  -e NODE_NAME_HYSTERIA2=sing-box-hy2 \
  ghcr.io/qqqasdwx/sing-box:latest
```

Docker 模式把宿主机 `./custom` 挂载到 `/sing-box/custom`，并用 Docker 命名卷 `sing-box-cert` 持久化 `/sing-box/cert`。证书卷必须保留，否则删除并重建容器会生成新的自签证书，使使用证书固定值的旧客户端失效；不要在常规升级时执行 `docker compose down -v`。首次启动会生成与 VPS 相同的默认文件和证书；后续启动在 SNI 未变化且证书有效时复用。每次容器启动都会先合并配置并执行完整检查，失败时容器会明确退出，不会回退到其他配置。修改后使用：

```sh
docker exec sing-box sb check
docker restart sing-box
```

Docker 不做在线重载；重启的是 sing-box 容器，不是 Docker daemon。`conf/03_routing.json` 是容器内的运行产物，不需要持久化。

固定 Argo 示例：

```sh
docker run -d --name sing-box --network host --restart unless-stopped \
  -v "$PWD/custom:/sing-box/custom" \
  -v sing-box-cert:/sing-box/cert \
  -e LANGUAGE=c \
  -e CHOOSE_PROTOCOLS=a \
  -e START_PORT=8881 \
  -e PORT_NGINX=8899 \
  -e ARGO=true \
  -e ARGO_DOMAIN=sb.example.com \
  -e ARGO_AUTH='REDACTED_JSON_TOKEN_OR_CF_API_TOKEN' \
  ghcr.io/qqqasdwx/sing-box:latest
```

`START_PORT` 是默认协议端口基准。每个协议都可以用对应 `PORT_*` 单独覆盖；未覆盖的协议按选择顺序从 `START_PORT` 递增。`LOG_LEVEL` 可设置 sing-box 服务端日志级别，默认 `error`。`FINGER_PRINT` 可设置客户端 TLS 指纹，默认 `chrome`。`PORT_VMESS_WS` 和 `PORT_VLESS_WS` 通常保持为空，让脚本自动分配即可；用户侧连接端口看 `CDN_PORT`。`SERVER_IP` 可选；Docker 启动时留空会自动检测公网 IPv4/IPv6。启用订阅或 Argo 时，`PORT_NGINX` 是 nginx 回源端口；未指定时会从 `START_PORT + 已选协议数量` 开始选择，并避开已选协议端口。容器直接使用宿主机提供的系统时间，本项目不会在容器内另行运行 NTP 客户端。

Docker 同样支持 `GH_PROXY` 环境变量；默认值为空。它只影响容器启动时从 GitHub 下载 sing-box、jq 和按需下载的 cloudflared。

## Throne 设置 ShadowTLS 方法

脚本会输出两条 Throne 链接。把两条链接导入 Throne 后，手动创建链式代理，并按 `ShadowTLS -> Shadowsocks` 的顺序选择这两个节点；顺序反了会导致连接失败。

## 外部依赖

安装和运行路径保留以下可审计依赖：

| 来源 | 用途 | 触发条件与处理 |
| --- | --- | --- |
| `SagerNet/sing-box` | sing-box 版本查询和官方二进制 | 安装、升级或容器启动；核心依赖。 |
| `jqlang/jq` | 固定 `1.7.1` 的 JSON 工具二进制 | 本机没有项目已保存的 jq，或容器启动；用于生成和校验 JSON。 |
| `cloudflare/cloudflared` 与 Cloudflare 官方 API | Argo Tunnel | 仅启用 Argo 时需要；主机和 Docker 未启用 Argo 时都不下载。 |
| `just-containers/s6-overlay` | Docker 内管理 sing-box、nginx、cloudflared | 只在构建镜像时使用；固定 `3.2.3.2` 并校验发布资产 SHA-256。 |
| `MetaCubeX/meta-rules-dat`，经 `testingcf.jsdelivr.net` | 默认 Google、OpenAI 远程规则集 | sing-box 按规则集配置拉取；可在 `custom/03_route.json` 中替换或删除。 |
| `realm.hy2.io` 与配置中的 STUN 服务 | Hysteria2 Realm | 仅用户启用 `HY2_REALM` 时由 sing-box/客户端使用。 |
| Cloudflare 官方 trace | 检测公网 IPv4/IPv6 和国家代码 | 安装脚本启动时调用；不再查询第三方 IP 服务。 |

项目不发送运行次数遥测，不把 Reality 私钥发送到远程服务，也不执行 BBR/DD、ArgoX、SBA 或 TCP Brutal 的远程安装脚本。Clash 和 sing-box 客户端模板由本项目本地生成。

## 开发维护

修改脚本时先改 `src/`，再生成根目录单文件：

```sh
tools/bundle.sh
bash -n sing-box.sh docker_init.sh
tools/bundle.sh --check
bash tests/test-safe-reload.sh
bash tests/test-local-assets.sh
bash tests/test-certificate-reuse.sh
bash tests/test-routing-validation.sh
bash tests/test-upgrade-transaction.sh
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
