# home-server-cf-tunnel：把家里的 Mac / Windows 电脑变成你的「云服务器」

> 不续费云服务器，不要公网 IP，不用在路由器上开端口。
> 一台家里常开的电脑 + 一个域名 + Cloudflare 免费版，就能让全世界用 `https://你的域名` 访问你电脑上的网站、接口和 SSH。

[English](README.en.md) · 这是一个 **Agent Skill**：可以自己照着做，也可以交给 Claude Code / Codex / Cursor 等 AI 助手，让它一步步带你做完。

```
访客 ──HTTPS──► Cloudflare 边缘节点（自动 HTTPS 证书、防攻击、可加登录）
                     │  隧道：由家里电脑主动连出去，路由器上什么都不用开
                     ▼
            家里的 Mac / Windows：cloudflared ──► 127.0.0.1:3000（你的网站）
                                                 127.0.0.1:8080（你的接口）
                                                 127.0.0.1:22  （SSH，加登录保护）
```

## 为什么做这个

作者原来租了一台国内云服务器（2 核 2G 轻量），上面跑着几个网页小游戏和反向代理。到期前把它们全部搬回了家里的 Mac mini，之后又陆续把模型中转站、学习网站、远程 SSH 都挂了上去，云服务器就没再续费。

搬家之后的实际情况：

| | 云服务器 | 家里电脑 + Cloudflare Tunnel |
|---|---|---|
| 每月费用 | 服务器月租 | 0（只有域名年费和电费） |
| 公网 IP | 要 | 不要（家里宽带是运营商 NAT 也行） |
| 开端口 / 防火墙 | 要配安全组 | 不开任何入站端口 |
| HTTPS 证书 | 自己申请、续期 | Cloudflare 自动负责 |
| 性能 | 2 核 2G | 家里电脑的全部 CPU / 内存 / 硬盘 |
| 数据在哪 | 别人的机房 | 自己家里 |
| 登录保护 | 自己写 | Cloudflare Access，填邮箱就行（50 人内免费） |
| 国内打开速度 | 快（国内机房） | 慢一些：作者实测首页从 0.1～0.3 秒变成 1.5～2 秒（走 Cloudflare 海外节点） |
| 停电 / 断网 | 机房负责 | 家里停电就访问不了 |

**适合**：个人网站、作品集、小游戏、自用工具、AI 接口中转、家庭相册 / NAS 的网页端、远程 SSH 回家。
**不适合**：要求国内秒开的商业网站、游戏服务器等需要裸 UDP / TCP 端口的服务、必须 99.9% 在线的业务。详见 [references/01-how-it-works.md](references/01-how-it-works.md)。

## 需要准备什么

1. 一台能常开的电脑：Mac（Mac mini 最合适，功耗低、安静）或 Windows（小主机、旧笔记本都行）。
2. 一个域名，并且 DNS 托管在 Cloudflare（免费版就够；在哪买的域名都可以，改 NS 就行，见 [01 第 3 节](references/01-how-it-works.md#3-把域名交给-cloudflare-管)）。
3. 电脑上已经跑着你想发布的服务（没有也行，先用第 1 步的演示页面）。

## 三步上手

### 第 1 步：5 分钟体验（不用账号、不用域名）

先确认这条路在你电脑上走得通。会得到一个临时网址 `https://xxxx.trycloudflare.com`，用手机流量打开就能看到你电脑上的页面。

macOS（终端）：

```bash
git clone https://github.com/hanzo-genji233/home-server-cf-tunnel.git
cd home-server-cf-tunnel
bash scripts/macos/quick-try.sh              # 起一个演示页面并发布
bash scripts/macos/quick-try.sh --port 3000  # 或者发布你已有的 3000 端口
```

Windows（PowerShell）：

```powershell
git clone https://github.com/hanzo-genji233/home-server-cf-tunnel.git
cd home-server-cf-tunnel
powershell -ExecutionPolicy Bypass -File scripts\windows\quick-try.ps1
```

没装 `cloudflared` 会自动装（Mac 用 Homebrew 或官方 Release；Windows 用 winget 或官方 Release），都不需要管理员权限。

### 第 2 步：绑定自己的域名，开机自启

先 `--dry-run` 看一遍要做什么，确认后去掉它再跑。

macOS：

```bash
bash scripts/macos/setup-tunnel.sh --name home \
  --host blog.example.com=http://127.0.0.1:3000 \
  --host api.example.com=http://127.0.0.1:8080 --dry-run
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\setup-tunnel.ps1 -Name home `
  -Hosts "blog.example.com=http://127.0.0.1:3000","api.example.com=http://127.0.0.1:8080" -DryRun
```

脚本会：装 cloudflared → 打开浏览器登录 Cloudflare 一次 → 建隧道 → 写配置 → 自动建 DNS 记录 → 装开机自启（Mac 是 LaunchAgent，Windows 是计划任务或服务）→ 装看门狗 → 等隧道连上后从外网访问一次，告诉你结果。

不想碰配置文件？也可以全程在 Cloudflare 网页上点，见 [Route A：面板方式](references/02-route-a-dashboard.md)。

### 第 3 步：让它像服务器一样 24 小时在线

| | macOS | Windows |
|---|---|---|
| 不睡眠 | `sudo pmset -a sleep 0 disksleep 0` | `powercfg /change standby-timeout-ac 0` |
| 停电来电后自动开机 | `sudo pmset -a autorestart 1` | BIOS 里开 Restore on AC Power Loss |
| 重启后不用人登录 | 系统设置里开自动登录 | 用 `-Service` 模式，或开自动登录 |

然后体检：

```bash
bash scripts/macos/doctor.sh --name home
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\doctor.ps1 -Name home
```

体检会检查：隧道有没有连上（几条连接）、每个本地服务在不在、每个域名从外网打开返回什么、会不会睡眠、断电会不会自动开机、有没有代理软件在捣乱。

## 进阶

- **私密服务加登录**（后台、SSH、个人数据）：[05 Cloudflare Access 与 SSH 回家](references/05-access-and-ssh.md)
- **一个域名下按路径分给多个服务**（`site.com/app1`、`site.com/app2`）：[06 用 Caddy 做路径分流](references/06-multi-service-caddy.md)
- **macOS 细节**：[03-macos.md](references/03-macos.md) · **Windows 细节**：[04-windows.md](references/04-windows.md)
- **出问题了**：[07 坑点大全](references/07-pitfalls.md)（作者真实踩过的坑：隧道「活着但不通」、代理软件导致一天断几百次、launchd 日志放错目录起不来……）

## 交给 AI 助手做

把这个仓库放进你的 agent 的 skills 目录（例如 Claude Code 的 `~/.claude/skills/home-server-cf-tunnel/`），然后直接说：

> 我想把家里这台电脑上 3000 端口的网站发布到 blog.我的域名.com，帮我弄好并且开机自启。

agent 会按 [SKILL.md](SKILL.md) 的流程：先问清楚、先 dry-run 给你看、需要 sudo / 管理员的命令交给你执行、做完跑体检并报告真实结果。

## 安全提醒

- `~/.cloudflared/` 里的 `cert.pem` 和 `<隧道ID>.json` 等于隧道的钥匙，**不要上传、不要发给别人**。
- 发布出去的东西默认人人能访问。后台、文件管理、数据库界面、SSH 一定先加 [Cloudflare Access](references/05-access-and-ssh.md)。
- 本地服务尽量只监听 `127.0.0.1`，隧道只需要本机能访问到它。
- Cloudflare 账号本身开两步验证：谁拿到账号，谁就能改你的隧道和 DNS。

## 实测环境

- macOS：Apple 芯片 Mac mini（作者家里 24 小时在跑），macOS 自带 bash 3.2 + 系统 Python 3。
- Windows：Windows 10 + Windows PowerShell 5.1 实测（Windows 11 同样适用，未单独实测）。
- cloudflared 2026.x。

## License

MIT
