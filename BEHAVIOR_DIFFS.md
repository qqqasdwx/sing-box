# 与上游的行为差异

本次 review 基线，日期：2026-07-21。

- 上游：`fscarmen/sing-box@fa45859cf2e61f457f31015fa1fa4f31d4d6b159`
- 下游：`qqqasdwx/sing-box@main`

截至当前 review 基线，已选择性移植上游中适用于本仓库的变化。本文记录本仓库相对上游的刻意行为差异，以及迁移过程中发现并修复的问题。

## Review 结果

- VPS 安装脚本刻意尽量保持与上游一致。目前观察到的差异主要是仓库归属链接、`force_version` 来源，以及生成的 `sb` 快捷命令地址。
- Docker 行为刻意与上游不同：本仓库的 Docker 入口复用 VPS 的协议生成逻辑，而不是继续维护一份独立手写实现。
- 本仓库完全移除内置 WARP endpoint、宿主机 WARP 检测/状态显示，以及 OpenAI、Hysteria2 和 `sb -d` 的 WARP 专用逻辑；Hysteria2 Realm/STUN 与通用自定义出站能力保留。
- 本次 review 选择性移植上游 `4f29ea5` 的 v2rayN Hysteria2 Realm 格式更新，改用 `ProtoExtraObj.Hy2RealmUrl`；上游实现遗漏了 `Ports` 和 `HopInterval`，本仓库保留这两个端口跳跃字段并增加组合测试。
- 本次 review 不移植上游的 `BIND_INTERFACE` 菜单；需要绑定网卡时可直接在 `custom/04_outbounds.json` 中设置 sing-box 的 `bind_interface`。上游同时把示例变量误改为脚本不读取的 `PORT_HOPPING_RANGE`，本仓库继续使用 `HY2_PORT_HOPPING_RANGE`。
- 本次 review 选择性移植上游 `fa45859` 的 SIGHUP 热重载和新二进制配置预检。VPS 复用现有候选配置检查，在发送 HUP 后确认主 PID 未变化且服务仍存活；Docker 只移植更新前预检，配置生效方式仍为重启容器。
- 上游把协议增删也直接改为 HUP，但该流程同时修改服务文件、nginx、Argo 和防火墙。本仓库暂时保留协议增删的完整停启，只让端口和单项节点参数修改使用安全热重载。
- 本仓库不生成 sing-box 内建 NTP 客户端配置，直接依赖宿主机时间同步；升级时删除旧 `06_ntp.json` 并注释状态文件中的旧 `NTP_*` 配置项。
- 下游配置文件更新会在 SNI 未变化且证书、私钥有效匹配时复用已有自签证书；Docker 示例通过命名卷持久化 `/sing-box/cert`，避免升级或重建容器后已有客户端的证书固定值失效。
- 下游自定义路由发布除了执行 `sing-box check`，还会校验规则引用的出站或 endpoint tag 是否存在；这是对当前 sing-box 内建检查语义盲区的补充。
- 早前 review 已移植上游 `6bb22b3`、`53ce0dc`、`5dfd0cd` 和 `3dfbec4`，包括客户端 TLS 指纹、部分导出配置热更新、服务端 IP 修改修复、协议变更 UUID 保留、Hysteria2 Realm UX、v2rayN Realm 订阅支持、端口跳跃目标解析和 Hysteria2 sing-box JSON 输出修复。
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
| 外部维护脚本 | 菜单可直接以 root 执行 BBR/DD、ArgoX、SBA 和 TCP Brutal 远程脚本。 | 删除这些入口；TCP Brutal 只检测用户自行安装的内核模块。 | sing-box 安装器不应代管内核、重装系统或执行无关项目的远程代码。 |
| 客户端订阅模板 | 运行时从独立仓库下载 Clash、sing-box 模板和预编译二维码程序。 | VPS 与 Docker 共用项目内模板生成逻辑；删除二维码生成和展示，只输出订阅链接。 | 去掉无许可证模板和额外可执行文件供应链，同时避免二维码占用终端和容器日志。 |
| 时间同步 | 默认生成 sing-box 内建 NTP 客户端配置。 | 不生成内建 NTP 配置，直接使用宿主机或容器环境的系统时间。 | 时间同步属于宿主机基础设施，避免应用重复访问 NTP 服务并维护第二套同步策略。 |
| 遥测与密钥处理 | 默认调用自建服务统计运行次数、查询 IP，缺少本地工具时把 Reality 私钥交给远程服务推导公钥。 | 不发送运行统计；公网 IP 使用 Cloudflare 官方 trace；Reality 私钥只在本机处理，缺少工具时明确失败。 | 安装器不应静默上报，也不应把私钥发送给第三方。 |
| GitHub 加速 | 直连失败时自动探测并选择内置第三方 GitHub 反代。 | 默认只直连；仅当用户显式设置 `GH_PROXY` 时添加 URL 前缀。 | 代理属于用户的信任决策，不应由脚本静默决定。 |
| 节点命名 | 只支持一个全局节点名，所有协议共用同一前缀。 | 支持 `NODE_NAME_CONFIRM` 全局节点名，也支持 `NODE_NAME_XTLS_REALITY`、`NODE_NAME_HYSTERIA2` 等单协议节点名。 | 用户可以给每个协议设置可识别的名称；未设置单协议名称时仍保持上游式全局回退。 |
| 协议端口 | 主要通过 `START_PORT` 按所选协议顺序连续分配端口。 | 支持 `PORT_XTLS_REALITY`、`PORT_HYSTERIA2` 等单协议端口；未设置时仍按 `START_PORT` 顺序使用默认端口。 | 保留上游默认行为，同时允许 Docker 或配置文件固定某个协议的公开端口。 |
| 客户端 TLS 指纹 | 通过已安装后的 `sb -d` 菜单修改导出订阅里的客户端 TLS fingerprint。 | 保留菜单修改，并额外支持 `FINGER_PRINT` 配置文件变量和 Docker 环境变量；默认值同上游为 `chrome`。 | Docker 没有交互菜单，配置化可以让 VPS 和 Docker 的订阅输出保持一致。 |
| 自定义路由与出站 | 路由和出站由安装脚本直接生成在 sing-box 的配置目录，自定义 WARP 规则另存一份配置。 | `custom/03_route.json` 和 `custom/04_outbounds.json` 是唯一源文件；完整检查成功后合并发布到 `conf/03_routing.json`。VPS 使用 `sb check/reload`，Docker 在启动时发布。 | 避免基本路由与附加规则存在多个来源，同时保证错误配置不会覆盖最后一次可运行版本。 |
| 服务配置热重载 | 配置修改后直接发送 HUP；信号发送成功即报告完成，协议增删也不再停启。 | VPS 先发布并检查完整配置，再只向主 PID 发送 HUP，并验证 PID 与服务状态；协议增删继续完整停启。Docker 仍通过容器重启应用配置。 | 避免无效配置触发 reload，并保留 nginx、Argo、服务文件和防火墙的跨组件生命周期。 |
| 出站网卡绑定 | `sb -d` 枚举当前网卡并直接修改生成的 `conf/01_outbounds.json`。 | 不提供专用菜单；高级用户可在 `custom/04_outbounds.json` 的具体出站中设置 `bind_interface`。 | 网卡绑定不能区分同一接口上的多个地址，容器内外看到的接口也不同；配置应继续遵守 `custom/` 唯一源和检查发布流程。 |
| 内置 WARP | 默认生成 `warp-ep`，OpenAI 检测失败时自动使用，另有 Hysteria2 和 `sb -d` WARP 路由入口。 | 不生成 WARP endpoint，并删除所有 WARP 专用入口；旧引用在升级时清理。 | 项目没有足够明确、普适的场景需要默认携带或管理 WARP。 |
| Docker 镜像仓库 | Action 使用 Docker Hub secrets 推送到 Docker Hub。 | Action 使用 `GITHUB_TOKEN` 推送到 `ghcr.io/qqqasdwx/sing-box:latest`。 | 不再依赖 Docker Hub 凭据，镜像发布留在 GitHub Packages。 |
| Docker 构建上下文 | 直接从仓库分支构建。 | 从生成后的 release tree 构建。 | 确保 Docker 镜像使用的 `docker_init.sh` 和发布分支里的文件完全一致。 |
| Docker 进程管理器 | 构建时下载 s6-overlay 的 latest 资产。 | 固定 s6-overlay `3.2.3.2`，并用发布资产附带的 SHA-256 校验后再解压。 | 避免 latest 漂移并校验构建阶段下载内容。 |
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
