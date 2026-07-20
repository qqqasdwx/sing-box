# 仅将 Google IPv6 分流到 AetherCloud

此示例保留 Google 域名的 `prefer_ipv6` 解析策略。Google 域名的解析结果
包含 IPv6 时，通过 AetherCloud DynamicV6 SOCKS5 网关连接；结果只有 IPv4
时，继续使用 `direct`。客户端直接传入目标 IP 时，Google IPv6 使用
AetherCloud，Google IPv4 仍使用默认出站。

域名解析可能同时返回 IPv6 和 IPv4。`prefer_ipv6` 会先尝试 IPv6，但
sing-box 选定 AetherCloud 后不会在连接失败时重新选择 `direct`；后续地址
仍会通过同一个 AetherCloud 出站尝试。此示例不提供跨出站自动回退。

先按本分支根目录 README 部署网关，并确认宿主机可以访问
`172.30.53.2:1080`。编辑 `04_outbounds.json`，将占位密码替换为安装网关时
终端输出的实际密码。

将两个 JSON 文件复制到 `/etc/sing-box/custom/` 后执行：

```sh
sb check
sb reload
```
