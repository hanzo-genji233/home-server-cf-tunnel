# 06 一个域名分给多个服务：用 Caddy 做路径分流

## 1. 什么时候需要

- **不同子域名** → 不同服务：不需要 Caddy，直接在隧道配置里写多条 `hostname`。
- **同一个域名、不同路径** → 不同服务（`site.com/game1`、`site.com/game2`）：cloudflared 能按路径匹配，但**不能去掉路径前缀**。后端收到的还是 `/game1/index.html`，大多数应用会 404。这时中间加一层 Caddy。

```
Cloudflare ─► cloudflared ─► 127.0.0.1:8790 Caddy ─┬─ /game1/* 去前缀 ─► 127.0.0.1:8787
                                                    ├─ /game2/* 去前缀 ─► 127.0.0.1:8788
                                                    └─ 其余           ─► 127.0.0.1:8787
```

作者从云服务器搬家时就是这样：原来服务器上的 Caddy 按路径分流两个小游戏，搬回家后 Caddy 原样保留，只是 HTTPS 交给了 Cloudflare。

## 2. 安装 Caddy

- macOS：`brew install caddy`；没有 Homebrew 就从 <https://caddyserver.com/download> 下载单文件放进 `~/.local/bin/`。
- Windows：`winget install CaddyServer.Caddy`，或下载 `caddy.exe`。

## 3. 配置

见 `templates/Caddyfile.example`。要点：

1. 全局设置 `admin off`、`auto_https off`：HTTPS 由 Cloudflare 负责，Caddy 只跑 http。
2. 站点地址写 `http://域名:8790`，并 `bind 127.0.0.1`，只让本机的 cloudflared 访问。
3. `handle_path /game1/*` 会自动去掉 `/game1` 前缀再转发。

隧道配置里，这个域名的 service 改成 Caddy：

```yaml
  - hostname: site.example.com
    service: http://127.0.0.1:8790
```

## 4. 让 Caddy 开机自启

- macOS：照 `03-macos.md` 第 5 节写一个 plist，`ProgramArguments` 是 `caddy run --config /绝对路径/Caddyfile --adapter caddyfile`。
- Windows：用计划任务（登录后启动）或 `sc.exe create`。

验证：

```bash
caddy validate --config Caddyfile --adapter caddyfile
curl -H 'Host: site.example.com' http://127.0.0.1:8790/game1/
```
