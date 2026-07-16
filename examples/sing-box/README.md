# sing-box 路由示例

这些示例用于把 AetherCloud DynamicV6 网关接入 `qqqasdwx/sing-box` 主项目。
每个子目录都包含完整的 `custom/03_route.json`、`custom/04_outbounds.json`
和独立说明：

- `google-all-v6`：Google 全系域名强制使用 IPv6，并通过 AetherCloud 出站。
- `google-selective-v6`：仅将 Google IPv6 目标分流到 AetherCloud，Google
  IPv4 保持 `direct`。

先运行本分支安装器部署网关，再把对应场景的两个 JSON 文件复制到
`/etc/sing-box/custom/`。必须将 `04_outbounds.json` 中的占位密码替换为安装器
最终输出的实际密码。
