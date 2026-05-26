# Changelog

本文件记录 `qqqasdwx/sing-box` 相对上游的下游变更。上游项目自身的历史请参考 [fscarmen/sing-box](https://github.com/fscarmen/sing-box)。

## 2026-05-26

- 支持按协议自定义监听端口；未设置的协议继续按 `START_PORT` 和 `CHOOSE_PROTOCOLS` 顺序使用默认递增端口，`sb -d` 面板也可按协议修改端口。
- Docker 与 VPS 共用协议端口解析和冲突校验，避免自定义协议端口与 `PORT_NGINX` 撞车。
- 在 `config.conf`、README 和 Docker Compose 示例中补充所有协议端口变量。

## 2026-05-25

- 支持按协议自定义节点名；未设置单协议名称时继续回退到全局节点名和默认主机名。
- 新增 `BEHAVIOR_DIFFS.md`，记录本仓库与上游的刻意行为差异和迁移 review 结果。
- 修复 README 重写后 ShadowTLS 教程链接失效的问题。
- Docker 更新 sing-box 时恢复失败回滚检查，避免新二进制启动失败后直接留下不可用状态。
- 将默认开发分支切换为 `main`，`release` 改为自动生成的纯发布分支。
- 删除旧的 `modular` 分支，保留 `upstream-main` 作为上游跟踪分支。
- 新增 `tools/prepare-release.sh`，用于生成只包含运行产物的发布目录。
- 调整 GitHub Actions：`main` 推送后校验 bundle、构建 GHCR 镜像，并发布 `release` 分支。
- GHCR 镜像发布到 `ghcr.io/qqqasdwx/sing-box:latest`，支持 `linux/amd64`、`linux/arm64`、`linux/arm/v7`。
- 新增 `Upstream watch` Action，每天检查 `fscarmen/sing-box:main` 是否有新提交，并通过 GitHub Issue 通知。

## 2026-05-24

- 将 `sing-box.sh` 和 `docker_init.sh` 拆成 `src/vps/`、`src/docker/` 模块，并通过 `tools/bundle.sh` 重新打包成单文件。
- 保留 `bash <(wget -qO- https://raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh)` 这种远程单文件执行方式。
- Docker 入口改为复用 VPS 的协议配置、订阅导出和 Argo 处理逻辑。
- 修复 Docker 中 Cloudflare API Token / Argo 认证不生效的问题；无效 `ARGO_AUTH` 会直接失败并提示。
- Docker 端口语义与 VPS 对齐：`START_PORT` 是第一个协议端口，`PORT_NGINX` 是订阅或 Argo 的 nginx 回源端口。
- Dockerfile 补充运行依赖：`ca-certificates`、`tar`、`iproute2`、`iputils`、`procps`、`coreutils`、`xxd`。
