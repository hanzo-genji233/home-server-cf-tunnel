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
#   -ReplaceHosts   不保留旧配置里的域名，只发布这次传入的（默认保留旧域名，只增改这次传的）
#   -MetricsPort    指定 metrics 端口（默认沿用旧配置；新隧道自动挑 20241 起没被占用的）
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string[]]$Hosts = @(),
  [string]$SshHost = '',
  [switch]$DryRun, [switch]$OverwriteDns, [switch]$NoDns, [switch]$Service, [switch]$NoAutostart, [switch]$NoWatchdog, [switch]$ReplaceHosts,
  [int]$MetricsPort = 0
)
. (Join-Path $PSScriptRoot 'lib.ps1')

# powershell -File 不会把 "a","b" 拆成数组，会收到一整串 "a,b"：这里统一按逗号拆开
$Hosts = @($Hosts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Name -notmatch '^[A-Za-z0-9_-]+$') { Die '-Name 只能用字母、数字、- 和 _' }
if ($Hosts.Count -eq 0 -and -not $SshHost) { Die '至少要一个 -Hosts "域名=http://127.0.0.1:端口"' }
foreach ($h in $Hosts) { if ($h -notmatch '^[A-Za-z0-9*.-]+=https?://\S+$') { Die "-Hosts 写成 域名=http://127.0.0.1:端口（不能有空格），收到的是：$h" } }
if ($SshHost -and $SshHost -notmatch '^[A-Za-z0-9.-]+$') { Die "-SshHost 只写域名，比如 ssh.example.com，收到的是：$SshHost" }
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

function Get-MetricsPortOf([string]$path) {
  if (-not (Test-Path $path)) { return 0 }
  foreach ($l in (Get-Content -Encoding UTF8 $path)) { if ($l -match "^metrics:\s*['`"]?[^:'`"]*:(\d+)") { return [int]$Matches[1] } }
  return 0
}
# 读旧配置的 ingress 规则：返回 @{Host=域名或空; Lines=原文行（缩进统一成 2 格）}，去掉最后的兜底规则
function Get-IngressRules([string]$path) {
  $rules = @(); if (-not (Test-Path $path)) { return $rules }
  $lines = @(Get-Content -Encoding UTF8 $path); $in = $false; $ind = -1; $cur = $null
  foreach ($l in $lines) {
    if (-not $in) { if ($l -match '^ingress:\s*(#.*)?$') { $in = $true }; continue }
    if ($l -match '^[^\s#]') { break }
    if ($l -match '^(\s*)-(\s|$)' -and ($ind -lt 0 -or $Matches[1].Length -eq $ind)) {
      $ind = $Matches[1].Length; $cur = @{ Host = $null; Lines = New-Object Collections.ArrayList }; $rules += $cur
    }
    if ($cur) { [void]$cur.Lines.Add($l) }
  }
  foreach ($r in $rules) {
    while ($r.Lines.Count -and ($r.Lines[$r.Lines.Count - 1].Trim() -eq '' -or $r.Lines[$r.Lines.Count - 1].Trim().StartsWith('#'))) { $r.Lines.RemoveAt($r.Lines.Count - 1) }
    foreach ($l in $r.Lines) {
      $lead = $l.Length - $l.TrimStart().Length
      if ($l -match "^\s*(?:-\s+)?hostname:\s*['`"]?([^'`"\s#]+)" -and ($l.TrimStart().StartsWith('-') -or $lead -eq $ind + 2)) { $r.Host = $Matches[1]; break }
    }
    $d = 2 - $ind
    $r.Lines = @($r.Lines | ForEach-Object { if ($d -ge 0) { (' ' * $d) + $_ } else { $_ -replace "^ {0,$(-$d)}", '' } })
  }
  if ($rules.Count -and -not $rules[-1].Host) { $rules = @($rules | Select-Object -First ($rules.Count - 1)) }
  return $rules
}

# metrics 端口：指定的 > 旧配置里的 > 自动挑一个没被别的隧道用、也没被监听的（多条隧道不能共用，否则看门狗会看错）
if ($MetricsPort -le 0) { $MetricsPort = Get-MetricsPortOf $config }
if ($MetricsPort -le 0) {
  $used = @(Get-ChildItem -Path $cfDir -Filter *.yml -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $config } | ForEach-Object { Get-MetricsPortOf $_.FullName })
  foreach ($p in 20241..20299) {
    if ($used -contains $p) { continue }
    try { $t = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p); $t.Start(); $t.Stop(); $MetricsPort = $p; break } catch {}
  }
  if ($MetricsPort -le 0) { Die '找不到空闲的 metrics 端口，用 -MetricsPort 指定' }
}

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
# 重跑时默认保留旧配置里其他域名的规则，只增改这次传入的，避免已发布的站点被覆盖成 404
$old = @(Get-IngressRules $config | Where-Object { $_.Host -and ($allHosts -notcontains $_.Host) })
$oldNoHost = @(Get-IngressRules $config | Where-Object { -not $_.Host })
if ($ReplaceHosts) {
  if ($old.Count) { Warn "-ReplaceHosts：旧配置里这些域名会被去掉（DNS 记录还在，访问会变 404）：$(($old | ForEach-Object { $_.Host }) -join ' ')" }
} else {
  foreach ($r in ($old + $oldNoHost)) { $lines += $r.Lines }
  if ($old.Count) { Info "保留旧配置里的域名：$(($old | ForEach-Object { $_.Host }) -join ' ')（不想要了加 -ReplaceHosts）" }
}
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
  if ($LASTEXITCODE -eq 0) {
    # cloudflared 只认登录时选的那个 zone；别的域名会被拼成 host.<那个zone>，必须核对
    $added = if ($out -match 'Added CNAME (\S+)') { $Matches[1].TrimEnd('.') } else { $null }
    if ($added -and $added -ne $h) {
      Warn "DNS：建成了 $added，不是 $h。原因：$h 不在登录时授权的那个域名（zone）里"
      Warn "  修法：到 Cloudflare 面板删掉 $added，再给 $h 手动加 CNAME → $tid.cfargotunnel.com（开小黄云）；或删掉 $cfDir\cert.pem 重跑，登录时选 $h 所在的域名"
    } else { Ok "DNS：$h → 隧道 $Name" }
  }
  elseif ($out -match 'already exists') { Warn "DNS：$h 已有记录。若它指向旧服务器，加 -OverwriteDns 重跑；若已指向本隧道，可忽略" }
  else { Warn "DNS：$h 自动创建失败（$($out.Trim() -split "`n" | Select-Object -Last 1)）。到 Cloudflare 面板手动加 CNAME：$h → $tid.cfargotunnel.com" }
}

# ---------- 6. 开机自启 ----------
$runArgs = "tunnel --config `"$config`" run"
if (-not $NoAutostart) {
  if ($Service) {
    if ($DryRun) { Info "将安装 Windows 服务 Cloudflared，并把启动参数改成：$runArgs" }
    else {
      $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared'
      if (Get-Service Cloudflared -ErrorAction SilentlyContinue) {
        # 已有服务：只有它本来就跑这份配置才改；跑的是别的隧道（面板 token 或别的配置）就停下，免得把它断开
        $img = (Get-ItemProperty $svcKey -Name ImagePath).ImagePath
        if (-not $img -or -not $img.Contains($config)) {
          Die ("这台电脑已经有一个 Cloudflared 服务在跑别的隧道，改它会让那条隧道断开。`n" +
               "     它现在的启动命令：$img`n" +
               "     可选：① 去掉 -Service，用计划任务模式（推荐，两条隧道互不影响）；`n" +
               "           ② 确认旧隧道不要了：管理员 PowerShell 执行 sc.exe stop Cloudflared; sc.exe delete Cloudflared，再重跑本命令。")
        }
      } else { & $cf service install | Out-Host }
      # 官方文档做法：服务装好后改注册表 ImagePath，让它带上我们的配置文件
      Set-ItemProperty $svcKey -Name ImagePath -Value "`"$cf`" $runArgs"
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
