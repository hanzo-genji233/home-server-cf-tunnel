# 05 给私密服务加登录（Cloudflare Access）+ 在外 SSH 回家

## 1. 给网页加一道「只有我能进」的门

适用：后台管理页、文件管理、数据库界面、家庭相册、任何没有自己登录功能的东西。

1. Cloudflare 控制台 → Zero Trust → Access → **Applications** → Add an application → **Self-hosted**。
2. Application domain 填要保护的域名，比如 `admin.example.com`。
3. 添加策略（Policy）：Action = **Allow**，Include → **Emails** → 填你自己的邮箱（可以填多个）。
4. 登录方式默认是 **One-time PIN**：访问时输入邮箱，收到验证码才能进。
5. 保存。打开 `https://admin.example.com`，应该先跳到 Cloudflare 的登录页。

免费版 50 个用户以内不收费。会话时长（默认 24 小时）在应用设置里改。

## 2. 在外面 SSH 回家

```
笔记本 ssh home-cf ─ProxyCommand: cloudflared access ssh─► Cloudflare Access（邮箱验证码）
       ─► 隧道 ─► 家里电脑 cloudflared ─► 127.0.0.1:22
```

**家里电脑（服务端）**

1. 打开 SSH：macOS 在 系统设置 → 通用 → 共享 → 远程登录；Windows 在 设置 → 系统 → 可选功能 → 添加「OpenSSH 服务器」，再 `Start-Service sshd; Set-Service sshd -StartupType Automatic`（管理员）。
2. 建隧道时加上 SSH 入口：`setup-tunnel.sh ... --ssh ssh.example.com`（Windows：`-SshHost ssh.example.com`）。
3. 按第 1 节给 `ssh.example.com` 建一个 Access 应用，只放行你的邮箱。**这一步不能省**，否则全世界都能来试你的 SSH 密码。
4. 建议 SSH 只允许密钥登录，关掉密码登录。

**外出用的电脑（客户端）**，也要装 cloudflared，然后在 `~/.ssh/config` 加：

```sshconfig
Host home-cf
  HostName ssh.example.com
  User 你的用户名
  ProxyCommand cloudflared access ssh --hostname %h
  # 10 分钟内重复连接秒开
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
```

Windows 客户端的 `ProxyCommand` 写 cloudflared.exe 的完整路径。

第一次 `ssh home-cf` 会打开浏览器让你输入邮箱验证码，之后 24 小时内不用再登录。

## 3. 给脚本 / 定时任务用：服务令牌（不弹浏览器）

无人值守的脚本没法点浏览器。用 Service Token：

1. Zero Trust → Access → **Service Auth** → Create Service Token，记下 Client ID 和 Client Secret（Secret 只显示一次）。有效期可选，到期前记得续。
2. 在 SSH 那个 Access 应用里**再加一条**策略：Action = **Service Auth**，Include → Service Token → 选刚建的令牌。原来的邮箱策略保留。
3. 客户端把令牌放进环境变量，再调用 cloudflared：

```bash
# ~/.ssh/cf-proxy.sh   （chmod 700；令牌文件 chmod 600，不要进 git）
#!/bin/sh
. "$HOME/.config/cf-tunnel/service-token.env"   # 两行：TUNNEL_SERVICE_TOKEN_ID=…  TUNNEL_SERVICE_TOKEN_SECRET=…
export TUNNEL_SERVICE_TOKEN_ID TUNNEL_SERVICE_TOKEN_SECRET
exec cloudflared access ssh --hostname "$1"
```

```sshconfig
Host home-cf
  HostName ssh.example.com
  ProxyCommand ~/.ssh/cf-proxy.sh %h
```

验证：`ssh -o BatchMode=yes home-cf hostname` 能直接返回主机名，不弹浏览器。

## 4. 本地端口转发：在外面用家里的内网服务

家里还有没发布出去的服务（比如 NAS 网页 `192.168.1.10:5000`），SSH 通了以后：

```bash
ssh -N -L 15000:192.168.1.10:5000 home-cf
# 然后在外面的电脑上打开 http://127.0.0.1:15000
```

## 5. 三层防护

1. Cloudflare Access：只有你的邮箱 / 令牌能到达 SSH。
2. SSH 本身：只认你的公钥。
3. Cloudflare 账号：**开两步验证**。谁拿到账号，谁就能改上面两层。
