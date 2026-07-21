# Changelog

本文件记录 `qqqasdwx/sing-box` 相对上游的下游变更。上游项目自身的历史请参考 [fscarmen/sing-box](https://github.com/fscarmen/sing-box)。

## 2026-07-21

- 选择性移植上游 `fa45859` 的 SIGHUP 热重载：VPS 在完整配置检查成功后只向 sing-box 主进程发送 HUP，并确认 PID 未变化且服务仍在运行。
- VPS 的监听端口和节点参数修改改用安全热重载；协议增删仍保留完整停启，避免遗漏 nginx、Argo、服务文件和防火墙联动。
- OpenRC 服务增加标准 `reload()`；systemd 继续使用已有的 `ExecReload`。
- VPS 与 Docker 更新 sing-box 前，先使用新二进制检查现有配置；不兼容时在替换文件或中断服务之前退出。
- Hysteria2 客户端带宽修改不再执行无关的防火墙同步。
- 新增安全热重载测试，覆盖配置发布失败时禁止发送 HUP，以及主 PID 变化时判定失败。
- 更新上游评审基线到 `fscarmen/sing-box@fa45859cf2e61f457f31015fa1fa4f31d4d6b159`。

## 2026-07-16

- 选择性移植上游 `4f29ea5`：v2rayN Hysteria2 Realm 订阅改用 `ProtoExtraObj.Hy2RealmUrl`，同时保留 `Ports` 和 `HopInterval` 端口跳跃字段。
- 新增 Realm 与端口跳跃四种组合的订阅 JSON 测试；VPS 和 Docker 共用同一生成逻辑。
- 不移植上游 `BIND_INTERFACE` 菜单及误改的 `PORT_HOPPING_RANGE` 示例变量，继续使用 `custom/` 唯一配置源和 `HY2_PORT_HOPPING_RANGE`。
- 更新上游跟踪基线到 `fscarmen/sing-box@4f29ea5c92707716fe5f0dfcccac12c5b5d63407`。

## 2026-07-13

- 新生成的默认 Google 与 OpenAI geosite 统一改用 MetaCubeX `sing` 分支，保持原有 DNS 偏好和 `direct` 出站行为不变；已有 `custom/` 文件不会被覆盖。
- 新增按场景组织的路由示例，覆盖 Google 全系流量使用指定 IPv4 或宿主机原生 IPv6 出站。
- release 产物包含 `examples/`，CI 会检查所有路由示例 JSON。

## 2026-07-12

- 新增统一的自定义路由与出站配置：`custom/03_route.json` 和 `custom/04_outbounds.json` 是唯一源文件，检查成功后合并发布为 `conf/03_routing.json`。
- VPS 新增 `sb check` 和 `sb reload`；发布采用临时候选配置、完整 `sing-box check`、原子替换和 HUP，失败时保留当前运行配置。
- Docker 支持挂载 `/sing-box/custom`，容器启动前强制检查并发布配置，容器内可用 `sb check` 验证，配置错误时明确退出。
- 默认内置 SagerNet 的 `geosite-google` 与 `geosite-openai` 规则集；OpenAI 保留原有 DNS 偏好，Google 新增 IPv6 优先解析，两者最终都明确使用 `direct`。
- 完全移除内置 WARP：不再生成 `warp-ep` endpoint，删除 OpenAI 自动检测/回退、Hysteria2 WARP 选项、`sb -d` WARP 专用路由菜单以及宿主机 WARP 检测/状态显示；Realm/STUN 保留。
- 升级时把旧自动 OpenAI WARP 规则改为 `direct`，删除其余引用 `warp-ep` 的路由、孤立规则集和旧 endpoint，避免留下无效配置。
- 已有 `01_outbounds.json`、`03_route.json`、`08_custom_route.json` 会迁移并合并到新的唯一源配置。
- 更新上游审查基线到 `fscarmen/sing-box@c62368ebccf27eedbd044e5c33c0c16e3ea3effd`。

## 2026-07-05

- 移植上游 `3dfbec4`：客户端订阅 TLS 指纹默认改为 `chrome` 并支持 `FINGER_PRINT` 配置，v2rayN Hysteria2 Realm 输出增加 `Finalmask`，Realm 菜单显示改为明确的开启/关闭动作。
- 移植上游 `5dfd0cd`、`53ce0dc`、`6bb22b3` 中的修复：`sb -r` 添加/删除协议时保留已有 UUID，服务端 IP 修改继续同步 `WS_SERVER_IP_SHOW`，Hysteria2 端口跳跃目标端口去除前导空格，sing-box 版本查询减少重复 API 请求。
- 更新上游跟踪基线到 `fscarmen/sing-box@3dfbec421510806564cbe2071cf101614f759842`。

## 2026-06-07

- 移植上游 `803cfa7`：修复 `sb -d` 修改端口后从 `nginx.conf` 提取 UUID 时误匹配 `/auto`、`/auto2` 的问题。
- 移植上游 `2ca9504`：订阅输出从 Neko/Nekobox 迁移到 Throne，移除多处客户端链接中的不安全 TLS 参数，并改进 V2rayN Trojan 输出。
- 支持 `LOG_LEVEL` 配置 sing-box 服务端日志级别。
- 支持 `NTP_ENABLED`、`NTP_SERVER`、`NTP_SERVER_PORT`、`NTP_INTERVAL` 配置 sing-box 内建 NTP 客户端。
- 更新上游跟踪基线到 `fscarmen/sing-box@2ca9504654e0bfc2fd6270d386a919e8f14800ab`。

## 2026-05-31

- 移植上游 v1.3.14：`sb -d` 支持管理自定义 `warp-ep` 出站路由规则，可按 `domain_suffix` 或 `rule_set` 将流量分流到 WARP endpoint。
- Docker 与 VPS 运行依赖补充 `curl`，用于校验远程 `.srs` rule_set 是否存在。
- 更新上游跟踪基线到 `fscarmen/sing-box@5644e6bebbf4f6da2e28e68e5cbb8cba2d64b865`。

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
