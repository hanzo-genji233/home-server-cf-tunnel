# 一条命令把本机服务发布到自己的域名（Cloudflare Tunnel，配置文件方式）。可重复运行。
#
# 用法（PowerShell）：
#   powershell -ExecutionPolicy Bypass -File setup-tunnel.ps1 -Name home `
#     -Hosts "blog.example.com=http://127.0.0.1:3000","api.example.com=http://127.0.0.1:8080" [选项]
#
# 选项：
#   -DryRun         只打印要做的事和生成的文件，不改任何东西
#   -OverwriteDns   域名已有记录（比如以前指向云服务器）时改成指向隧道
#   -NoDns          不自动建 DNS（去 Cloudflare 面板手动加 CNAME）
#   -Service        装成 Windows 服务：开机就跑、不用登录（要“以管理员身份运行”）
#                   不加时装成“登录后启动”的计划任务（不需要管理员）
#   -NoAutostart    不装开机自启
#   -NoWatchdog     不装看门狗
#   -SshHost        额外发布本机 SSH（如 ssh.example.com）。务必再配 Cloudflare Access，见 references/05
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string[]]$Hosts = @(),
  [string]$SshHost = '',
  [switch]$DryRun, [switch]$OverwriteDns, [switch]$NoDns, [switch]$Service, [switch]$NoAutostart, [switch]$NoWatchdog,
  [int]$MetricsPort = 20241
)
. (Join-Path $PSScriptRoot 'lib.ps1')

if ($Name -notmatch '^[A-Za-z0-9_-]+$') { Die '-Name 只能用字母、数字、- 和 _' }
if ($Hosts.Count -eq 0 -and -not $SshHost) { Die '至少要一个 -Hosts "域名=http://127.0.0.1:端口"' }
foreach ($h in $Hosts) { if ($h -notmatch '^[^=]+=https?://') { Die "-Hosts 写成 域名=http://127.0.0.1:端口，收到的是：$h" } }
if ($Service -and -not $DryRun) {
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $admin) { Die '-Service 需要管理员：右键 PowerShell → 以管理员身份运行，再执行一次' }
}

$cfDir = Join-Path $env:USERPROFILE '.cloudflared'
$config = Join-Path $cfDir "$Name.yml"
$share = Join-Path $env:LOCALAPPDATA 'cf-tunnel'
$logDir = Join-Path $share 'logs'
$taskName = "cloudflared-$Name"
$watchName = "cloudflared-$Name-watchdog"

function Run([string]$exe, [string[]]$a) {
  if ($DryRun) { Write-Host "  [dry-run] $exe $($a -join ' ')"; return }
  & $exe @a
  if ($LASTEXITCODE -ne 0) { throw "$exe $($a -join ' ') 失败（退出码 $LASTEXITCODE）" }
}

# ---------- 1. cloudflared ----------
if ($DryRun) { $cf = Find-Cloudflared; if (-not $cf) { $cf = $script:CfLocal } } else { $cf = Ensure-Cloudflared }
Ok "cloudflared：$cf"

# ---------- 2. 登录 ----------
if (Test-Path (Join-Path $cfDir 'cert.pem')) { Ok "已登录（$cfDir\cert.pem）" }
else { Info '接下来会打开浏览器：登录 Cloudflare → 选你的域名 → Authorize'; Run $cf @('tunnel', 'login') }

# ---------- 3. 隧道 ----------
function Get-TunnelId {
  try {
    $json = & $cf tunnel list -o json 2>$null | Out-String
    $t = ($json | ConvertFrom-Json) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($t) { return $t.id }
  } catch {}
  return $null
}
$tid = $null
if (Test-Path (Join-Path $cfDir 'cert.pem')) { $tid = Get-TunnelId }
if ($tid) { Ok "隧道 $Name 已存在：$tid" }
else {
  Info "新建隧道 $Name"
  if ($DryRun) { Run $cf @('tunnel', 'create', $Name); $tid = '<新隧道ID>' }
  else { & $cf tunnel create $Name | Out-Host; $tid = Get-TunnelId; if (-not $tid) { Die '隧道建好了但查不到 ID' } }
}
$cred = Join-Path $cfDir "$tid.json"
if (-not $DryRun -and -not (Test-Path $cred)) { Die "找不到隧道凭据 $cred。隧道可能是在别的电脑上建的：把那台的 $tid.json 拷过来，或换个 -Name" }

# ---------- 4. 配置 ----------
$lines = @(
  "# 由 home-server-cf-tunnel/setup-tunnel.ps1 生成于 $(Get-Date -Format 'yyyy-MM-dd HH:mm')。可以手改，改完重跑 doctor.ps1",
  "tunnel: $tid",
  "credentials-file: $cred",
  "metrics: 127.0.0.1:$MetricsPort",
  'no-autoupdate: true',
  '# 所在网络 / 代理挡 UDP 时改成 http2（见 references/07-pitfalls.md）',
  'protocol: auto',
  'ingress:'
)
$allHosts = @()
foreach ($h in $Hosts) {
  $host_, $svc = $h -split '=', 2
  $lines += "  - hostname: $host_"; $lines += "    service: $svc"; $allHosts += $host_
}
if ($SshHost) { $lines += "  - hostname: $SshHost"; $lines += '    service: ssh://127.0.0.1:22'; $allHosts += $SshHost }
$lines += '  # 最后一条必须是兜底：没匹配上的域名一律 404'
$lines += '  - service: http_status:404'
$yaml = ($lines -join "`r`n") + "`r`n"

if ($DryRun) { Info "将写入 $config："; $lines | ForEach-Object { Write-Host "    $_" } }
else {
  New-Item -ItemType Directory -Force -Path $cfDir | Out-Null
  if (Test-Path $config) { Copy-Item $config "$config.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"; Info '旧配置已备份' }
  [IO.File]::WriteAllText($config, $yaml, (New-Object Text.UTF8Encoding($false)))   # 无 BOM，cloudflared 才读得懂
  & $cf tunnel --config $config ingress validate | Out-Host
  if ($LASTEXITCODE -ne 0) { Die "配置校验失败：$config" }
  Ok "配置已写入并校验通过：$config"
}

# ---------- 5. DNS ----------
foreach ($h in $allHosts) {
  if ($NoDns) { Info "跳过 DNS：到 Cloudflare 面板给 $h 加 CNAME → $tid.cfargotunnel.com（开小黄云）"; continue }
  $a = @('tunnel', 'route', 'dns'); if ($OverwriteDns) { $a += '--overwrite-dns' }; $a += @($Name, $h)
  if ($DryRun) { Run $cf $a; continue }
  $out = & $cf @a 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0) { Ok "DNS：$h → 隧道 $Name"; ($out -split "`n" | Select-String 'Added CNAME') | ForEach-Object { Write-Host "    $_" } }
  elseif ($out -match 'already exists') { Warn "DNS：$h 已有记录。若它指向旧服务器，加 -OverwriteDns 重跑；若已指向本隧道，可忽略" }
  else { Warn "DNS：$h 自动创建失败（$($out.Trim() -split "`n" | Select-Object -Last 1)）。到 Cloudflare 面板手动加 CNAME：$h → $tid.cfargotunnel.com" }
}

# ---------- 6. 开机自启 ----------
$runArgs = "tunnel --config `"$config`" run"
if (-not $NoAutostart) {
  if ($Service) {
    if ($DryRun) { Info "将安装 Windows 服务 Cloudflared，并把启动参数改成：$runArgs" }
    else {
      if (-not (Get-Service Cloudflared -ErrorAction SilentlyContinue)) { & $cf service install | Out-Host }
      # 官方文档做法：服务装好后改注册表 ImagePath，让它带上我们的配置文件
      Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared' -Name ImagePath -Value "`"$cf`" $runArgs"
      Set-Service Cloudflared -StartupType Automatic
      Restart-Service Cloudflared -Force
      Ok 'Windows 服务 Cloudflared 已安装并启动（开机自动运行，不用登录）'
    }
  } else {
    if ($DryRun) { Info "将注册计划任务 $taskName：当前用户登录后启动，失败自动重启" }
    else {
      New-Item -ItemType Directory -Force -Path $logDir | Out-Null
      $act = New-ScheduledTaskAction -Execute $cf -Argument "--logfile `"$logDir\$Name.log`" $runArgs"
      $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
      $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
      Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Settings $set -Description 'Cloudflare Tunnel (home-server-cf-tunnel)' -Force | Out-Null
      Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
      Get-Process cloudflared -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $cf -and ((Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like "*$config*") } | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-ScheduledTask -TaskName $taskName
      Ok "计划任务 $taskName 已注册并启动（日志 $logDir\$Name.log）"
    }
  }
  if (-not $NoWatchdog) {
    if ($DryRun) { Info "将注册看门狗 $watchName：每 5 分钟查一次，连续 2 次 0 条连接就重启隧道" }
    else {
      New-Item -ItemType Directory -Force -Path $share | Out-Null
      Copy-Item (Join-Path $PSScriptRoot 'watchdog.ps1') (Join-Path $share 'watchdog.ps1') -Force
      $target = if ($Service) { '-ServiceName Cloudflared' } else { "-TaskName $taskName" }
      $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$share\watchdog.ps1`" $target -Metrics 127.0.0.1:$MetricsPort"
      $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
      $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
      if ($Service) {
        $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        Register-ScheduledTask -TaskName $watchName -Action $act -Trigger $trg -Settings $set -Principal $pr -Force | Out-Null
      } else {
        Register-ScheduledTask -TaskName $watchName -Action $act -Trigger $trg -Settings $set -Force | Out-Null
      }
      Ok "看门狗已注册：$watchName"
    }
  }
} else { Info "没装自启。手动运行：& `"$cf`" $runArgs" }

if ($DryRun) { Ok 'dry-run 结束，没有改动任何东西。确认无误后去掉 -DryRun 再跑一次。'; exit 0 }

# ---------- 7. 等隧道连上，再从外网访问一次 ----------
if (-not $NoAutostart) {
  Info '等隧道连上 Cloudflare…'
  $ha = $null
  for ($i = 0; $i -lt 30; $i++) { $ha = Get-HaConnections "127.0.0.1:$MetricsPort"; if ($ha -gt 0) { break }; Start-Sleep 2 }
  if ($ha -gt 0) { Ok "隧道已连上：$ha 条边缘连接" } else { Warn "60 秒内没连上，看日志：$logDir\$Name.log" }
  foreach ($h in $Hosts) {
    $host_ = ($h -split '=', 2)[0]
    $code = Get-HttpCode "https://$host_/"
    if ($code -ge 200 -and $code -lt 400 -or $code -in 401, 403) { Ok "https://$host_ → $code" }
    elseif ($code -eq 502) { Warn "https://$host_ → 502：隧道通了，但本地服务没响应" }
    else { Warn "https://$host_ → $code（新建的 DNS 可能要等一两分钟，过会儿跑 doctor.ps1）" }
  }
}
Write-Host ''
Write-Host '下一步（像云服务器一样 24 小时在线）：'
Write-Host '  powercfg /change standby-timeout-ac 0      # 插电时永不睡眠'
Write-Host '  BIOS 里打开 “Restore on AC Power Loss / 来电自动开机”'
if (-not $Service) { Write-Host '  计划任务要有用户登录才会启动：开自动登录（netplwiz），或改用 -Service 模式' }
Write-Host "体检：powershell -ExecutionPolicy Bypass -File `"$PSScriptRoot\doctor.ps1`" -Name $Name"
