# Google 全系使用指定 IPv4

此示例把 Google、Gemini、YouTube 等 Google 全系域名限制为只解析 IPv4，
并通过 `direct-v4` 绑定的宿主机 IPv4 出站。直接访问 Google IPv4 地址时，
`geoip-google` 也会选择相同出站。

编辑 `04_outbounds.json`，把文档保留地址 `192.0.2.10` 替换为宿主机上
实际存在的 IPv4 地址，不要附加 `/24` 或 `/32`。NAT VPS 应填写网卡上的
实际地址，不能填写未分配给宿主机的公网 NAT 地址。

IPv6 字面地址无法转换成 IPv4；直接访问 Google IPv6 地址时会继续使用默认
`direct` 出站。正常通过域名访问时，`ipv4_only` 会避免产生这种情况。

将两个 JSON 文件复制到 `/etc/sing-box/custom/` 后执行：

```sh
sb check
sb reload
```
