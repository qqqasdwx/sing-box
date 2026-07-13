# Google 全系使用 AetherCloud DynamicV6

此示例把 Google、Gemini、YouTube 等 Google 全系域名限制为只解析 IPv6，
并通过 AetherCloud DynamicV6 SOCKS5 网关出站。直接访问 Google IPv6 地址时，
`geoip-google` 也会选择相同出站。

使用前先按 `aethercloud` 分支的 README 部署网关，并确认宿主机可以访问
`fd53:ac::2:1080`。编辑 `04_outbounds.json`，将占位密码替换为安装网关时
终端输出的实际密码。

IPv4 字面地址无法通过 IPv6-only DynamicV6 出口转换成 IPv6；直接访问 Google
IPv4 地址时会继续使用默认 `direct` 出站。正常通过域名访问时，`ipv6_only`
会避免产生这种情况。

将两个 JSON 文件复制到 `/etc/sing-box/custom/` 后执行：

```sh
sb check
sb reload
```
