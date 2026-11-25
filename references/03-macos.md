# 03 macOS 细节

## 1. 文件都在哪

| 东西 | 位置 |
|---|---|
| cloudflared | Homebrew 路径，或 `~/.local/bin/cloudflared` |
| 登录凭据 | `~/.cloudflared/cert.pem`（能在你授权的域名下建隧道、建 DNS） |
| 隧道凭据 | `~/.cloudflared/<隧道ID>.json`（只能跑这一条隧道） |
| 配置 | `~/.cloudflared/<name>.yml` |
| 开机自启 | `~/Library/LaunchAgents/com.cloudflared.<name>.plist` |
| 看门狗 | `~/Library/LaunchAgents/com.cloudflared.<name>.watchdog.plist`，脚本在 `~/.local/share/cf-tunnel/` |
| 日志 | `~/Library/Logs/cloudflared/<name>.log`、`<name>-watchdog.log` |

## 2. 常用命令

```bash
U=gui/$(id -u)
launchctl print $U/com.cloudflared.home | grep -E 'state|pid|last exit'   # 状态
launchctl kickstart -k $U/com.cloudflared.home                             # 重启隧道
launchctl bootout $U/com.cloudflared.home                                  # 停用（重新启用用 bootstrap）
tail -f ~/Library/Logs/cloudflared/home.log                                # 看日志
curl -s 127.0.0.1:20241/metrics | grep ha_connections                      # 连接数，正常是 4
```

改了 plist 要 `bootout` 再 `bootstrap`，`kickstart` 不会重新读 plist。改了 `.yml` 只要 `kickstart -k`。

## 3. 为什么用 LaunchAgent，不用 `sudo cloudflared service install`

- LaunchAgent 装在用户目录，不需要 sudo，卸载就是删一个文件。
- 代价：要有用户登录它才会启动。所以要开**自动登录**：系统设置 → 用户与群组 → 自动以此身份登录。开了 FileVault 的 Mac 不能自动登录，重启后要到机器前输一次密码（或用 Route A 的系统服务）。

## 4. 让 Mac 像服务器

```bash
sudo pmset -a sleep 0 disksleep 0     # 永不睡眠（屏幕可以关）
sudo pmset -a autorestart 1           # 停电来电后自动开机（Mac mini / iMac 支持，笔记本没有）
sudo pmset -a womp 1                  # 允许网络唤醒
pmset -g                              # 查看
```

- 笔记本当服务器：合盖会睡，要接电源和外接显示器，或者用 `caffeinate -s` 之类的方法，不推荐长期这么用。
- 路由器上给这台 Mac 做 DHCP 静态分配，局域网地址就固定了（隧道本身不需要固定 IP，但你自己局域网 SSH 会方便）。
- 屏保、动态壁纸会悄悄吃 CPU，服务器用途可以关掉。

## 5. 把你的服务也做成开机自启

隧道只负责转发。你的网站本身也要开机就跑。照着下面写一个 plist 放进 `~/Library/LaunchAgents/`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.me.blog</string>
  <key>ProgramArguments</key><array>
    <string>/Users/你/.local/bin/node</string><string>/Users/你/apps/blog/server.js</string>
  </array>
  <key>WorkingDirectory</key><string>/Users/你/apps/blog</string>
  <key>EnvironmentVariables</key><dict><key>PORT</key><string>3000</string><key>HOST</key><string>127.0.0.1</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/你/Library/Logs/blog.log</string>
  <key>StandardErrorPath</key><string>/Users/你/Library/Logs/blog.log</string>
</dict></plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.me.blog.plist
```

- 路径都写绝对路径。launchd 不读你的 `.zshrc`，`PATH` 里没有 Homebrew。
- 日志不要放 `~/Documents`、`~/Desktop`、`~/Downloads`：这些目录受隐私保护，launchd 写不进去，服务会以退出码 78 起不来。

## 6. 卸载

```bash
U=gui/$(id -u)
launchctl bootout $U/com.cloudflared.home.watchdog; launchctl bootout $U/com.cloudflared.home
rm ~/Library/LaunchAgents/com.cloudflared.home*.plist
cloudflared tunnel cleanup home && cloudflared tunnel delete home
# 再到 Cloudflare DNS 页面删掉指向 <隧道ID>.cfargotunnel.com 的 CNAME
```
