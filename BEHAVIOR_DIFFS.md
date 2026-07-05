# 与上游的行为差异

本次 review 基线，日期：2026-07-05。

- 上游：`fscarmen/sing-box@3dfbec421510806564cbe2071cf101614f759842`
- 下游：`qqqasdwx/sing-box@main`

本次 review 已移植上游 `6bb22b3`、`53ce0dc`、`5dfd0cd` 和 `3dfbec4` 中适用于本仓库的变化。本文记录本仓库相对上游的刻意行为差异，以及迁移过程中发现并修复的问题。

## Review 结果

- VPS 安装脚本刻意尽量保持与上游一致。目前观察到的差异主要是仓库归属链接、`force_version` 来源，以及生成的 `sb` 快捷命令地址。
- Docker 行为刻意与上游不同：本仓库的 Docker 入口复用 VPS 的协议生成逻辑，而不是继续维护一份独立手写实现。
- 本次 review 已移植上游 `6bb22b3`、`53ce0dc`、`5dfd0cd` 和 `3dfbec4`，包括客户端 TLS 指纹、部分导出配置热更新、服务端 IP 修改修复、协议变更 UUID 保留、Hysteria2 Realm UX、v2rayN Realm `Finalmask` 输出、端口跳跃目标解析和 Hysteria2 sing-box JSON 输出修复。
- 早前 review 已移植上游 `803cfa7` 与 `2ca9504`，包括 `nginx.conf` UUID 提取修复、Throne 订阅输出、客户端订阅 TLS 安全参数调整和 V2rayN Trojan 输出改进。
- 早前 review 发现并修复了两个迁移问题：
  - README 重写后，脚本输出中的 ShadowTLS 帮助链接曾指向不存在的锚点；当前已随上游迁移到 Throne 小节。
  - Docker `init.sh -v` 更新 sing-box 时丢失了上游的失败回滚保护。现在会备份旧二进制，通过 s6 重启检查新进程；如果新进程没有恢复，会还原旧二进制。

## 刻意保留的差异

| 范围 | 上游行为 | 本仓库行为 | 为什么这么改 |
| --- | --- | --- | --- |
| 源码结构 | `sing-box.sh` 和 `docker_init.sh` 作为根目录脚本直接维护。 | 源码放在 `src/vps/` 和 `src/docker/`，由 `tools/bundle.sh` 生成根目录脚本。 | 保留单文件发布兼容性，同时让日常修改可以按模块 review。 |
| 发布分支 | `main` 同时是源码分支和 raw 安装入口。 | `main` 是源码分支；`release` 自动生成，只包含运行产物。 | raw 安装地址保持稳定，源码和自动化留在默认分支维护。 |
| raw 安装地址 | 使用 `raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh`。 | 使用 `raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh`。 | 发布脚本必须来自我们生成后的 `release` 分支。 |
| `force_version` | 从上游 `fscarmen/sing-box/main/force_version` 读取。 | 从本仓库 `qqqasdwx/sing-box/release/force_version` 读取。 | 已发布的安装脚本应该使用同一发布分支中的版本钉住文件。 |
| 节点命名 | 只支持一个全局节点名，所有协议共用同一前缀。 | 支持 `NODE_NAME_CONFIRM` 全局节点名，也支持 `NODE_NAME_XTLS_REALITY`、`NODE_NAME_HYSTERIA2` 等单协议节点名。 | 用户可以给每个协议设置可识别的名称；未设置单协议名称时仍保持上游式全局回退。 |
| 协议端口 | 主要通过 `START_PORT` 按所选协议顺序连续分配端口。 | 支持 `PORT_XTLS_REALITY`、`PORT_HYSTERIA2` 等单协议端口；未设置时仍按 `START_PORT` 顺序使用默认端口。 | 保留上游默认行为，同时允许 Docker 或配置文件固定某个协议的公开端口。 |
| 客户端 TLS 指纹 | 通过已安装后的 `sb -d` 菜单修改导出订阅里的客户端 TLS fingerprint。 | 保留菜单修改，并额外支持 `FINGER_PRINT` 配置文件变量和 Docker 环境变量；默认值同上游为 `chrome`。 | Docker 没有交互菜单，配置化可以让 VPS 和 Docker 的订阅输出保持一致。 |
| Docker 镜像仓库 | Action 使用 Docker Hub secrets 推送到 Docker Hub。 | Action 使用 `GITHUB_TOKEN` 推送到 `ghcr.io/qqqasdwx/sing-box:latest`。 | 不再依赖 Docker Hub 凭据，镜像发布留在 GitHub Packages。 |
| Docker 构建上下文 | 直接从仓库分支构建。 | 从生成后的 release tree 构建。 | 确保 Docker 镜像使用的 `docker_init.sh` 和发布分支里的文件完全一致。 |
| Docker 协议生成 | Docker 有一份独立手写的配置生成逻辑。 | Docker 复用 VPS 模块来生成协议 JSON、订阅、Argo、Reality 密钥、Hysteria2 Realm 和节点导出。 | 避免 Docker 和 VPS 两套行为继续漂移。 |
| Docker 协议选择 | 使用 `XTLS_REALITY=true` 等独立布尔变量；如果没有启用任何布尔变量，就不会选择协议。 | 支持 VPS 一样的 `CHOOSE_PROTOCOLS` 字母选择。旧布尔变量仍可用；如果两者都没传，默认启用全部协议。 | 与 VPS 快速安装行为对齐，同时保留旧 Docker 环境变量用法。 |
| Docker 端口语义 | `START_PORT` 是 nginx/Argo 回源端口；协议端口从它后面开始递增。 | `START_PORT` 是第一个协议端口；`PORT_NGINX` 是 nginx/Argo 回源端口，默认值是 `START_PORT + 已选协议数量`。 | 移除隐藏的一位端口偏移，让 Docker 与 VPS 的端口语义一致。 |
| Docker 订阅和 nginx | nginx 与订阅输出始终参与生成流程。 | 只有订阅或 Argo 需要时才生成 nginx；`SUBSCRIBE=false` 且 `ARGO=false` 时可以不启用 nginx。 | 支持非 HTTP 场景，避免无用服务。 |
| Docker Argo API | Docker 使用自己的 Cloudflare API 解析逻辑，并把隧道回源指向 `START_PORT`。 | Docker 复用 VPS 的 `input_argo_auth` / `create_argo_tunnel` 逻辑，并把隧道回源指向 `PORT_NGINX`；固定 Argo 输入无效时会提前失败。 | 修复 Docker Cloudflare API Token 路径，并保持 Argo 行为与 VPS 一致。 |
| Docker Quick Tunnel metrics | metrics 监听在 `0.0.0.0:$METRICS_PORT`。 | metrics 监听在 `127.0.0.1:$METRICS_PORT`。 | metrics 端口只用于容器内部读取临时隧道域名，不需要对外暴露。 |
| Docker 更新 | 上游会备份旧 sing-box 二进制；如果新进程启动失败，则回滚旧二进制。 | 保留同样的安全行为，但通过杀掉 s6 管理的进程，让 s6 拉起新进程并检查是否恢复。 | 保留更新失败回滚能力，同时符合容器内 supervisor 的运行方式。 |
| Docker 端口跳跃 | 上游 Docker 不管理宿主机 Hysteria2 端口跳跃 NAT。 | Docker 接受共享的 `HY2_PORT_HOPPING_RANGE` 设置，但只提示；宿主机 UDP 转发需要在容器外配置。 | 容器不应该直接修改宿主机防火墙或 NAT 状态。 |
| 运行时依赖 | Alpine 镜像只安装 `wget nginx bash openssl`。 | 额外安装 `curl ca-certificates tar iproute2 iputils procps coreutils xxd`。 | 共享 VPS 模块需要这些工具完成下载、IP 检测、进程检查、Reality 密钥处理和远程 rule_set 校验。 |
| 上游跟踪 | 上游采用 fork/mirror 风格的同步 workflow。 | 本仓库用 `upstream-main` 只镜像上游供 review；`Upstream watch` 在上游有新提交时创建 issue。 | 本仓库已作为独立下游维护，不再按直接 fork 同步流程工作。 |
