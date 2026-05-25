# sing-box downstream

这是 `qqqasdwx/sing-box`，一个基于 [fscarmen/sing-box](https://github.com/fscarmen/sing-box) 的独立下游版本。

本仓库的目标不是重新发明安装逻辑，而是把原脚本整理成可维护、可自动发布、Docker 与 VPS 行为一致的版本。上游变化通过 `upstream-main` 分支跟踪；我们只在审阅后把有价值的改动移植到 `main`。

变更记录见 [CHANGELOG.md](CHANGELOG.md)。当前跟踪的上游基线见 [`main` 分支的 UPSTREAM.md](https://github.com/qqqasdwx/sing-box/blob/main/UPSTREAM.md)。

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
- `release`：自动生成，只保留运行产物和发布说明，例如 `sing-box.sh`、`docker_init.sh`、`Dockerfile`、`README.md`、`CHANGELOG.md`。
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

参数化安装示例：

```sh
bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh) \
  --LANGUAGE c \
  --CHOOSE_PROTOCOLS bcf \
  --START_PORT 8881 \
  --SERVER_IP 203.0.113.10 \
  --SUBSCRIBE=true \
  --NODE_NAME_CONFIRM sing-box
```

协议选择：`a` 为全部；`b` VLESS Reality；`c` Hysteria2；`d` Tuic；`e` ShadowTLS；`f` Shadowsocks；`g` Trojan；`h` VMess WS；`i` VLESS WS TLS；`j` H2 Reality；`k` gRPC Reality；`l` AnyTLS；`m` NaiveProxy。

## Docker 使用

Docker 镜像：

```sh
docker pull ghcr.io/qqqasdwx/sing-box:latest
```

最小示例：

```sh
docker run -d --name sing-box --network host --restart unless-stopped \
  -e LANGUAGE=c \
  -e CHOOSE_PROTOCOLS=bcf \
  -e START_PORT=8881 \
  -e SERVER_IP=203.0.113.10 \
  -e SUBSCRIBE=true \
  ghcr.io/qqqasdwx/sing-box:latest
```

固定 Argo 示例：

```sh
docker run -d --name sing-box --network host --restart unless-stopped \
  -e LANGUAGE=c \
  -e CHOOSE_PROTOCOLS=a \
  -e START_PORT=8881 \
  -e PORT_NGINX=8899 \
  -e SERVER_IP=203.0.113.10 \
  -e ARGO=true \
  -e ARGO_DOMAIN=sb.example.com \
  -e ARGO_AUTH='REDACTED_JSON_TOKEN_OR_CF_API_TOKEN' \
  ghcr.io/qqqasdwx/sing-box:latest
```

`START_PORT` 是第一个协议端口。启用订阅或 Argo 时，`PORT_NGINX` 是 nginx 回源端口；未指定时默认使用 `START_PORT + 已选协议数量`，并会检查是否与协议端口冲突。

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
