# 体检：隧道、服务、外网访问、防睡眠。只读，不改任何东西。
# 用法：powershell -ExecutionPolicy Bypass -File doctor.ps1 [-Name home] [-Config 路径]
param([string]$Name = '', [string]$Config = '')
. (Join-Path $PSScriptRoot 'lib.ps1')
$ErrorActionPreference = 'Continue'
$script:fail = 0
function Fail($m) { Bad $m; $script:fail++ }

Write-Host '== cloudflared'
$cf = Find-Cloudflared
if ($cf) { Ok "$((& $cf --version 2>&1 | Select-Object -First 1))（$cf）" } else { Fail '没装 cloudflared：setup-tunnel.ps1 会自动装，或 winget install Cloudflare.cloudflared'; exit 1 }

Write-Host '== 配置'
$cfDir = Join-Path $env:USERPROFILE '.cloudflared'
if (-not $Config) {
  if ($Name) { $Config = Join-Path $cfDir "$Name.yml" }
  else {
    $cfgs = @(Get-ChildItem $cfDir -Include *.yml, *.yaml -File -ErrorAction SilentlyContinue -Recurse -Depth 0)
    if ($cfgs.Count -eq 1) { $Config = $cfgs[0].FullName }
    elseif ($cfgs.Count -eq 0) { Warn "$cfDir 下没有配置文件（面板 token 方式 / Route A 可以忽略，只看下面的服务部分）" }
    else { Bad '有多个配置，请用 -Config 指定：'; $cfgs | ForEach-Object { Write-Host "    $($_.FullName)" }; exit 1 }
  }
}
if (-not $Name -and $Config) { $Name = [IO.Path]::GetFileNameWithoutExtension($Config) }
$hosts = @(); $services = @(); $metrics = ''
if ($Config -and (Test-Path $Config)) {
  & $cf tunnel --config $Config ingress validate *> $null
  if ($LASTEXITCODE -eq 0) { Ok "配置有效：$Config" } else { Fail "配置校验失败：cloudflared tunnel --config `"$Config`" ingress validate" }
  $text = Get-Content $Config
  $cred = ($text | Select-String '^credentials-file:\s*(.+)$' | Select-Object -First 1)
  if ($cred) { $p = $cred.Matches[0].Groups[1].Value.Trim(); if (Test-Path $p) { Ok "凭据文件在：$p" } else { Fail "凭据文件不存在：$p" } }
  $m = $text | Select-String '^metrics:\s*(\S+)' | Select-Object -First 1; if ($m) { $metrics = $m.Matches[0].Groups[1].Value }
  $hosts = @($text | Select-String 'hostname:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique)
  $services = @($text | Select-String 'service:\s*((https?|ssh|tcp)://\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique)
} elseif ($Config) { Fail "找不到 $Config" }

Write-Host '== 开机自启'
$task = Get-ScheduledTask -TaskName "cloudflared-$Name" -ErrorAction SilentlyContinue
$svc = Get-Service Cloudflared -ErrorAction SilentlyContinue
if ($svc) {
  if ($svc.Status -eq 'Running') { Ok "Windows 服务 Cloudflared 在运行（启动类型 $($svc.StartType)）" } else { Fail "Windows 服务 Cloudflared 状态：$($svc.Status)" }
}
if ($task) {
  if ($task.State -eq 'Running') { Ok "计划任务 cloudflared-$Name 在运行" } else { Fail "计划任务 cloudflared-$Name 状态：$($task.State)" }
}
if (-not $svc -and -not $task) {
  if (Get-Process cloudflared -ErrorAction SilentlyContinue) { Warn 'cloudflared 在运行，但没装开机自启（重启后不会自己起来）' } else { Fail '没有 cloudflared 在运行' }
}
if (Get-ScheduledTask -TaskName "cloudflared-$Name-watchdog" -ErrorAction SilentlyContinue) { Ok '看门狗已装' } else { Warn '没装看门狗（断线卡死时不会自动重启）' }

Write-Host '== 边缘连接'
if (-not $metrics) { foreach ($p in 20241..20245) { if ($null -ne (Get-HaConnections "127.0.0.1:$p")) { $metrics = "127.0.0.1:$p"; break } } }
if ($metrics) {
  $ha = Get-HaConnections $metrics
  if ($ha -ge 2) { Ok "$ha 条连接到 Cloudflare（正常是 4）" } elseif ($ha -ge 1) { Warn "只有 $ha 条连接，网络可能不稳" } else { Fail "0 条连接或读不到 metrics（$metrics），看日志里的 ERR，见 references/07-pitfalls.md" }
} else { Warn '读不到 metrics，没法检查连接数。在配置里加一行 metrics: 127.0.0.1:20241' }

Write-Host '== 本地服务'
foreach ($s in $services) {
  $u = [Uri]$s
  $port = if ($u.Port -gt 0) { $u.Port } elseif ($u.Scheme -eq 'https') { 443 } elseif ($u.Scheme -eq 'ssh') { 22 } else { 80 }
  $c = New-Object Net.Sockets.TcpClient
  try { $ok = $c.ConnectAsync($u.Host, $port).Wait(2000) -and $c.Connected } catch { $ok = $false } finally { $c.Close() }
  if ($ok) { Ok "$s 在监听" } else { Fail "$s 没有在监听：先把这个服务启动起来" }
}

Write-Host '== 外网访问'
foreach ($h in $hosts) {
  if ($h -match 'ssh') { Info "$h 是 SSH 入口，跳过网页检查"; continue }
  $code = Get-HttpCode "https://$h/"
  if ($code -ge 200 -and $code -lt 400) { Ok "https://$h → $code" }
  elseif ($code -in 401, 403) { Ok "https://$h → $code（有登录保护，正常）" }
  elseif ($code -eq 404) { Warn "https://$h → 404：隧道通了；是本地服务返回 404，或这个域名没写进 ingress" }
  elseif ($code -eq 502) { Fail "https://$h → 502：隧道通了，本地服务没响应" }
  elseif ($code -eq 530) { Fail "https://$h → 530：DNS 指向隧道了，但隧道没连上" }
  elseif ($code -eq 0) { Fail "https://$h → 无响应：DNS 还没生效，或本机网络 / 代理拦了" }
  else { Warn "https://$h → $code" }
}

Write-Host '== 像服务器一样常在线'
$q = powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null | Out-String
$acm = [regex]::Match($q, '(?:AC|交流)[^\r\n]*?:\s*0x([0-9a-fA-F]+)')
if ($acm.Success) {
  $sec = [Convert]::ToInt32($acm.Groups[1].Value, 16)
  if ($sec -eq 0) { Ok '插电时不会睡眠' } else { Warn "插电 $([int]($sec/60)) 分钟后会睡眠：powercfg /change standby-timeout-ac 0" }
} else { Info '读不到睡眠设置，手动确认：设置 → 系统 → 电源 → 插电时“从不”睡眠' }
$al = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue).AutoAdminLogon
if ($svc) { Ok '服务模式不需要自动登录' } elseif ($al -eq '1') { Ok '已开自动登录' } else { Warn '没开自动登录：重启后要有人登录，计划任务才会启动（或改用 -Service）' }
Info '断电后自动开机要在 BIOS 里开（Restore on AC Power Loss），脚本查不到'

Write-Host '== 代理软件'
$px = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'clash|mihomo|v2ray|sing-box|nekoray' }
if ($px) { Warn "检测到代理软件（$(($px.ProcessName | Select-Object -Unique) -join ', ')）。隧道频繁断开时给 cloudflared 单独设规则，见 references/07-pitfalls.md 第 3 条" } else { Ok '没检测到常见代理软件' }

Write-Host ''
if ($script:fail -eq 0) { Ok '体检完成：没有 [X]' } else { Bad "体检完成：$($script:fail) 项 [X]，先修这些" }
exit $script:fail
