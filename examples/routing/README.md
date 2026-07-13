# 路由示例

每个子目录都是一个完整场景，包含可作为唯一源配置使用的
`03_route.json`、`04_outbounds.json` 和独立说明。示例保留默认 OpenAI
解析与直连行为，并只改变对应场景中的 Google 路由。

可用场景：

- `google-v4`：Google 全系域名使用指定的宿主机 IPv4。
- `google-native-v6`：Google 全系域名使用指定的宿主机原生 IPv6。
- `google-aethercloud-v6`：Google 全系域名使用 AetherCloud DynamicV6
  SOCKS5 网关。

示例中的 `192.0.2.10`、`2001:db8::10` 和占位密码不能直接用于生产。
复制前先备份现有 `custom/`，再按场景 README 替换必要字段。

VPS 修改后执行：

```sh
sb check
sb reload
```

Docker 修改绑定挂载的 `custom/` 后执行：

```sh
docker exec sing-box sb check
docker restart sing-box
```

所有示例统一使用 MetaCubeX `sing` 分支的规则集。`geosite/google.srs`
已经聚合 Gemini、YouTube、Google Play、Firebase 等 Google 子集；
`geoip/google.srs` 用于匹配没有域名信息的 Google IP 流量。
