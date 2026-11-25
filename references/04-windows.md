# 04 Windows 细节

## 1. 两种开机自启，选一种

| | 计划任务（默认） | Windows 服务（`-Service`） |
|---|---|---|
| 要管理员 | 不要 | 要（一次） |
| 什么时候启动 | 用户登录后 | 开机就启动，不用登录 |
| 适合 | 自己常用的电脑 | 专门当服务器的小主机 |
| 停止 / 启动 | `Stop-ScheduledTask` / `Start-ScheduledTask cloudflared-home` | `Restart-Service Cloudflared` |

服务模式的原理（Cloudflare 官方文档的做法）：先 `cloudflared service install` 装出服务，再把注册表 `HKLM\SYSTEM\CurrentControlSet\Services\Cloudflared` 的 `ImagePath` 改成带 `--config <你的配置>` 的启动命令。脚本自动做这两步。

如果电脑上**已经有**一个 Cloudflared 服务在跑别的隧道（比如面板 token 装的），脚本会停下、不改它，免得那条隧道断开。这时去掉 `-Service` 用计划任务模式即可，两条隧道互不影响。

## 2. 文件都在哪

| 东西 | 位置 |
|---|---|
| cloudflared | winget 安装路径，或 `%LOCALAPPDATA%\cloudflared\cloudflared.exe` |
| 登录凭据、隧道凭据、配置 | `%USERPROFILE%\.cloudflared\` |
| 日志（计划任务模式） | `%LOCALAPPDATA%\cf-tunnel\logs\<name>.log` |
| 看门狗 | 计划任务 `cloudflared-<name>-watchdog`，日志 `%LOCALAPPDATA%\cf-tunnel\watchdog.log`（服务模式在 `%ProgramData%\cf-tunnel\`） |

## 3. 让 Windows 像服务器

```powershell
powercfg /change standby-timeout-ac 0     # 插电永不睡眠
powercfg /change hibernate-timeout-ac 0   # 插电永不休眠
```

- **断电来电自动开机**：开机按 Del / F2 进 BIOS，找 `Restore on AC Power Loss` / `AC Back` / `来电自启`，设成 `Power On`。
- **自动登录**（计划任务模式需要）：`Win+R` → `netplwiz` → 取消勾选「要使用本计算机，用户必须输入用户名和密码」。用微软账号登录的电脑，先在 设置 → 账户 → 登录选项 里关掉「仅允许 Windows Hello 登录」。
- **Windows 更新自动重启**：设置 → Windows 更新 → 高级选项 → 活跃时间，避免半夜重启后没人登录（服务模式不受影响）。

## 4. 防火墙

隧道是出站连接，**不需要**在 Windows 防火墙里放行任何入站端口。你的服务只监听 `127.0.0.1` 时，防火墙弹窗可以选「取消」。

## 5. 编码坑

- 脚本是 UTF-8 带 BOM 保存的，Windows PowerShell 5.1 才能正确显示中文。自己改脚本时用 VS Code 保存为「UTF-8 with BOM」。
- cloudflared 的 `config.yml` 必须是 **UTF-8 不带 BOM**。用记事本另存时选「UTF-8」（新版记事本默认就不带 BOM）。带 BOM 可能导致解析出错。脚本生成的配置已处理。

## 6. 卸载

```powershell
Unregister-ScheduledTask cloudflared-home -Confirm:$false
Unregister-ScheduledTask cloudflared-home-watchdog -Confirm:$false
# 服务模式（管理员）：cloudflared service uninstall
cloudflared tunnel cleanup home; cloudflared tunnel delete home
# 再到 Cloudflare DNS 页面删掉指向 <隧道ID>.cfargotunnel.com 的 CNAME
```
