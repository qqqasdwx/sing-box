# Google 全系使用宿主机原生 IPv6

此示例把 Google、Gemini、YouTube 等 Google 全系域名限制为只解析 IPv6，
并通过 `direct-v6` 绑定的宿主机原生 IPv6 出站。直接访问 Google IPv6 地址时，
`geoip-google` 也会选择相同出站。

编辑 `04_outbounds.json`，把文档保留地址 `2001:db8::10` 替换为宿主机上
实际存在且可出站的固定 IPv6 地址，不要附加 `/64` 或 `/128`。动态变化的
IPv6 不适合直接写入此配置。

IPv4 字面地址无法转换成 IPv6；直接访问 Google IPv4 地址时会继续使用默认
`direct` 出站。正常通过域名访问时，`ipv6_only` 会避免产生这种情况。

将两个 JSON 文件复制到 `/etc/sing-box/custom/` 后执行：

```sh
sb check
sb reload
```
