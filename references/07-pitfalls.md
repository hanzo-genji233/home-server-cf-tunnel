# 07 坑点大全（作者真实踩过的）

先跑 `doctor`，按报错找下面对应的一条。

## 1. 网站打开是 530 / 1033，但 cloudflared 进程明明在跑

- **原因**：cloudflared 和 Cloudflare 边缘断开后，偶尔卡住不重连。进程活着，launchd / 计划任务都觉得没问题，实际 0 条连接。
- **判断**：`curl -s 127.0.0.1:<端口>/metrics | grep ha_connections`，值为 0。端口看 `~/.cloudflared/<name>.yml` 的 `metrics:` 行（Windows 在 `%USERPROFILE%\.cloudflared\`）。
- **解决**：重启隧道（macOS `launchctl kickstart -k gui/$(id -u)/com.cloudflared.<name>`）。长期解决靠看门狗：`setup-tunnel` 默认装好，每分钟检查，连续 3 次 0 条连接就自动重启。

## 2. 502 Bad Gateway

隧道是通的，但 cloudflared 连不上你的本地服务。

1. 服务没起来：`curl http://127.0.0.1:3000` 试试。
2. 地址写错：服务监听 `localhost`（可能只是 IPv6 `::1`），配置里写的是 `127.0.0.1`。两边写成一样。
3. 服务只认特定 Host 头（比如 Vite、某些框架会拒绝陌生域名）：在框架配置里允许你的域名，或在 ingress 里加 `originRequest: { httpHostHeader: localhost }`。

## 3. 开着代理软件（Clash 等），隧道一天断几百次

- **现象**：日志里大量 `Lost connection with the edge`、`TLS handshake with edge error: EOF`，时好时坏。
- **原因**：代理软件把 cloudflared 连 Cloudflare 的流量也送进了机场节点，节点质量决定了隧道稳不稳。作者实测：经一个不稳定的节点时每天断 100～300 次。
- **解决**：给 cloudflared 单独设规则。在 Clash / mihomo 规则最前面加：
  ```yaml
  - PROCESS-NAME,cloudflared,DIRECT          # macOS / Linux
  - PROCESS-NAME,cloudflared.exe,DIRECT      # Windows
  ```
  直连不稳定时，可以换成一个专门的 fallback 分组（按顺序挑第一个能通的稳定节点，最后兜底 DIRECT）。作者改规则后：改前 3 分钟抽样 16/18 次 0 条连接，改后 10 分钟 0 次断开。
- 开了 TUN / 全局模式的代理，对 cloudflared 同样生效，一样要加规则。

## 4. QUIC 连不上（`failed to dial to edge with quic`）

部分网络、公司防火墙、代理会挡 UDP 7844。在配置里写 `protocol: http2`，然后重启隧道。

## 5. macOS：LaunchAgent 起不来，退出码 78

plist 里的日志路径放在了 `~/Documents`、`~/Desktop`、`~/Downloads` 这类受隐私保护的目录，launchd 写不进去。改到 `~/Library/Logs/`。

## 6. macOS：plist 改了不生效

`kickstart` 不会重新读 plist。要 `launchctl bootout gui/$(id -u)/<label>` 再 `launchctl bootstrap gui/$(id -u) <plist>`。

## 7. `tunnel route dns` 建出了奇怪的域名

`cloudflared tunnel login` 时只授权了**一个**域名（zone）。给另一个域名建 DNS 时，cloudflared 可能把它拼到授权的那个域名后面（`blog.b.com.a.com`）。

- 看脚本输出里的 `Added CNAME …` 那一行，确认域名对不对。
- 多个域名：到 Cloudflare 面板对应域名的 DNS 页手动加 CNAME：名称 `blog`，目标 `<隧道ID>.cfargotunnel.com`，开启代理（小黄云）。或者对另一个域名重新 `cloudflared tunnel login`（会覆盖 `cert.pem`，先备份）。
- 用 `setup-tunnel --no-dns` 可以跳过自动建 DNS。

## 8. 域名原来指向云服务器（A 记录），route dns 报 already exists

加 `--overwrite-dns`（Windows `-OverwriteDns`）重跑，A 记录会被换成指向隧道的 CNAME。搬家前先确认新地址能用，再改 DNS；回滚就把 A 记录改回去。

## 9. 域名过期 / 换域名

旧域名过期后，对应的 ingress 条目就成了死条目，`doctor` 会报「无响应」。换域名时：

1. 新域名托管到 Cloudflare。
2. 隧道配置里新旧主机名并存，先加新的，验证通过。
3. 所有用到旧地址的客户端、脚本、配置一起改（用 `grep -rn 旧域名` 搜一遍）。
4. 旧域名停止解析后，再删旧条目。

## 10. 重启隧道把自己的 SSH 断了

在外面通过 `ssh home-cf` 连进来，再重启隧道，SSH 会立刻断开，重启命令可能执行不完。放到后台执行：

```bash
nohup sh -c 'sleep 1; launchctl kickstart -k gui/$(id -u)/com.cloudflared.home' >/dev/null 2>&1 &
```

## 11. 在外 SSH 卡在 “A browser window should have opened”

Access 登录令牌过期（默认 24 小时），脚本或无人值守任务又没法点浏览器。用服务令牌，见 `05-access-and-ssh.md` 第 3 节。

## 12. 第一次浏览器登录完成后，那一次 ssh 报 `websocket: bad handshake`

令牌其实已经存好，再连一次就通。

## 13. 国内打开慢

免费版走海外节点，这是这个方案的代价。能做的：

1. 静态资源压缩、加缓存头，让 Cloudflare 边缘缓存静态文件。
2. 页面首屏做轻。
3. 真的要求国内秒开，那部分业务还是放国内云服务器。

## 14. 家里换了宽带 / 路由器

隧道不依赖家里 IP，换宽带不用改任何配置。只要电脑能上网，隧道会自己连回去。
