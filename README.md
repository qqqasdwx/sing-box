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
- `release`：自动生成，只保留运行产物和发布说明，例如 `sing-box.sh`、`docker_init.sh`、`Dockerfile`、`README.md`、`CHANGELOG.md`、`BEHAVIOR_DIFFS.md`。
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

实验功能：多订阅 JSON 安装

> 该能力仅保留在 `feature/multi-subscriptions-json` 实验分支中，不进入常规 release。它面向少数需要单实例承载多个独立订阅的场景；没有明确需求时建议继续使用默认单订阅模式。

```sh
wget -O config.json https://raw.githubusercontent.com/qqqasdwx/sing-box/release/config.json
bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh) --json config.json
```

`config.json` 使用新的数据模型：`subscriptions[].uuid` 是订阅入口 UUID，`subscriptions[].nodes[]` 是该订阅独占的节点；节点未设置 `uuid` 时继承订阅 UUID。订阅路径为 `/<订阅UUID>/auto`、`/<订阅UUID>/auto2`、`/<订阅UUID>/clash`、`/<订阅UUID>/sing-box`、`/<订阅UUID>/v2rayn` 等。

多订阅 JSON 支持裸机 VPS 和 Docker，支持 Argo，也支持同一订阅内重复添加同一种协议。修改多订阅配置时，裸机编辑 `/etc/sing-box/config.json` 后重新执行 `--json` 安装命令；Docker 编辑挂载的 `config.json` 后重启容器。多订阅安装后的 `sb -d` 旧菜单管理仍不适用，节点增删改以 JSON 为准。

参数化安装示例：

```sh
bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh) \
  --LANGUAGE c \
  --CHOOSE_PROTOCOLS bcf \
  --START_PORT 8881 \
  --PORT_HYSTERIA2 443 \
  --SERVER_IP 203.0.113.10 \
  --SUBSCRIBE=true \
  --NODE_NAME_CONFIRM sing-box \
  --NODE_NAME_HYSTERIA2 sing-box-hy2
```

协议选择：`a` 为全部；`b` VLESS Reality；`c` Hysteria2；`d` Tuic；`e` ShadowTLS；`f` Shadowsocks；`g` Trojan；`h` VMess WS；`i` VLESS WS TLS；`j` H2 Reality；`k` gRPC Reality；`l` AnyTLS；`m` NaiveProxy。

协议端口可以逐个覆盖：`PORT_XTLS_REALITY`、`PORT_HYSTERIA2`、`PORT_TUIC`、`PORT_SHADOWTLS`、`PORT_SHADOWSOCKS`、`PORT_TROJAN`、`PORT_VMESS_WS`、`PORT_VLESS_WS`、`PORT_H2_REALITY`、`PORT_GRPC_REALITY`、`PORT_ANYTLS`、`PORT_NAIVE`。未填写的协议继续按 `START_PORT` 和 `CHOOSE_PROTOCOLS` 顺序递增，重复端口会直接报错。除 WebSocket 协议外，这些端口会作为客户端连接端口导出；`PORT_VMESS_WS` 和 `PORT_VLESS_WS` 是源站监听端口，Argo 下是本机内部回源端口，Origin Rules 下是 Cloudflare 回源端口，客户端连接端口由 `CDN_PORT` 决定（默认 VMess WS 为 80，VLESS WS TLS 为 443）。已安装后也可以通过 `sb -d` 的监听端口面板逐个修改。

节点名称优先级：单协议节点名 > 全局 `NODE_NAME_CONFIRM` > 默认主机名。支持的单协议变量包括 `NODE_NAME_XTLS_REALITY`、`NODE_NAME_HYSTERIA2`、`NODE_NAME_TUIC`、`NODE_NAME_SHADOWTLS`、`NODE_NAME_SHADOWSOCKS`、`NODE_NAME_TROJAN`、`NODE_NAME_VMESS_WS`、`NODE_NAME_VLESS_WS`、`NODE_NAME_H2_REALITY`、`NODE_NAME_GRPC_REALITY`、`NODE_NAME_ANYTLS`、`NODE_NAME_NAIVE`。

已安装后，`sb -d` 还可以管理自定义 `warp-ep` 出站路由规则。规则写入 `/etc/sing-box/conf/08_custom_route.json`，支持按 `domain_suffix` 或远程 `.srs` `rule_set` 将匹配流量分流到 WARP endpoint。

## Docker 使用

Docker 镜像：

```sh
docker pull ghcr.io/qqqasdwx/sing-box:latest
```

Compose 示例见 [docker-compose.example.yml](docker-compose.example.yml)。示例文件列出了 Docker 支持的环境变量，并包含用临时镜像生成 `UUID_CONFIRM` 和 `REALITY_PRIVATE` 的命令。

Docker 支持两种启动方式：不挂载配置时继续使用下面的环境变量模式；挂载 `config.json` 时走多订阅 JSON 模式。可用 `-e CONFIG_JSON=/sing-box/config/config.json -v /opt/sing-box:/sing-box/config` 指定配置文件，也可以直接挂载到 `/sing-box/config.json`。如果指定了配置入口但文件不存在，容器会先生成一份没有订阅和节点的默认 `config.json`，编辑后重启容器生效。

最小示例：

```sh
docker run -d --name sing-box --network host --restart unless-stopped \
  -e LANGUAGE=c \
  -e CHOOSE_PROTOCOLS=bcf \
  -e START_PORT=8881 \
  -e SUBSCRIBE=true \
  -e NODE_NAME_CONFIRM=sing-box \
  -e NODE_NAME_HYSTERIA2=sing-box-hy2 \
  ghcr.io/qqqasdwx/sing-box:latest
```

多订阅 JSON 示例：

```sh
mkdir -p /opt/sing-box
docker run --rm \
  -e CONFIG_JSON=/sing-box/config/config.json \
  -v /opt/sing-box:/sing-box/config \
  ghcr.io/qqqasdwx/sing-box:latest

# 编辑 /opt/sing-box/config.json 后启动
docker run -d --name sing-box --network host --restart unless-stopped \
  -e CONFIG_JSON=/sing-box/config/config.json \
  -v /opt/sing-box:/sing-box/config \
  ghcr.io/qqqasdwx/sing-box:latest
```

固定 Argo 示例：

```sh
docker run -d --name sing-box --network host --restart unless-stopped \
  -e LANGUAGE=c \
  -e CHOOSE_PROTOCOLS=a \
  -e START_PORT=8881 \
  -e PORT_NGINX=8899 \
  -e ARGO=true \
  -e ARGO_DOMAIN=sb.example.com \
  -e ARGO_AUTH='REDACTED_JSON_TOKEN_OR_CF_API_TOKEN' \
  ghcr.io/qqqasdwx/sing-box:latest
```

`START_PORT` 是默认协议端口基准。每个协议都可以用对应 `PORT_*` 单独覆盖；未覆盖的协议按选择顺序从 `START_PORT` 递增。`PORT_VMESS_WS` 和 `PORT_VLESS_WS` 通常保持为空，让脚本自动分配即可；用户侧连接端口看 `CDN_PORT`。`SERVER_IP` 可选；Docker 启动时留空会自动检测公网 IPv4/IPv6。启用订阅或 Argo 时，`PORT_NGINX` 是 nginx 回源端口；未指定时会从 `START_PORT + 已选协议数量` 开始选择，并避开已选协议端口。

## Nekobox 设置 ShadowTLS 方法

脚本会输出两条 Neko 链接。把两条链接导入 Nekobox 后，手动创建链式代理，并按 `ShadowTLS -> Shadowsocks` 的顺序选择这两个节点；顺序反了会导致连接失败。

## 开发维护

修改脚本时先改 `src/`，再生成根目录单文件：

```sh
tools/bundle.sh
bash -n sing-box.sh docker_init.sh
tools/bundle.sh --check
```

本地生成发布目录：

```sh
tools/prepare-release.sh /tmp/sing-box-release
docker build -t sing-box:local /tmp/sing-box-release
```

上游更新由 `Upstream watch` Action 每天检查。如果有更新，会创建 GitHub Issue；处理方式是审阅 `fscarmen/main` 与 `upstream-main` 的差异，把需要的部分移植到 `main`，再更新 `upstream-main` 的跟踪提交。

## 安全说明

不要提交真实的 `ARGO_AUTH`、Cloudflare API Token、UUID、Reality 私钥、证书、服务器 IP 或生产域名。文档和示例必须使用脱敏值。
