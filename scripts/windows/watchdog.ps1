# cloudflared 看门狗（Windows，计划任务每 5 分钟跑一次）。
# cloudflared 和边缘断开后偶尔卡住不重连：进程还在，网站却 530。
# 连续 -Limit 次读到 0 条连接（或读不到 metrics）就重启计划任务 / 服务。只记异常、重启和恢复。
param([string]$TaskName = '', [string]$ServiceName = '', [string]$Metrics = '127.0.0.1:20241', [int]$Limit = 2)
$dir = Join-Path $env:LOCALAPPDATA 'cf-tunnel'
if ($ServiceName) { $dir = Join-Path $env:ProgramData 'cf-tunnel' }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$stateFile = Join-Path $dir 'watchdog.state.json'
$logFile = Join-Path $dir 'watchdog.log'
function Log($m) { Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" -Encoding UTF8 }

$st = @{ zeros = 0; kicks = 0 }
if (Test-Path $stateFile) { try { $o = Get-Content $stateFile -Raw | ConvertFrom-Json; $st.zeros = [int]$o.zeros; $st.kicks = [int]$o.kicks } catch {} }

$ha = $null
try {
  $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri "http://$Metrics/metrics"
  foreach ($line in ($r.Content -split "`n")) { if ($line -like 'cloudflared_tunnel_ha_connections *') { $ha = [int][double]($line.Split(' ')[1]) } }
} catch {}

if ($ha -gt 0) {
  if ($st.zeros -gt 0) { Log "恢复：$ha 条连接（之前连续 $($st.zeros) 次为 0）" }
  $st.zeros = 0
} else {
  $st.zeros++
  Log ("连接数={0}，连续第 {1} 次" -f ($(if ($null -eq $ha) { '读不到' } else { $ha })), $st.zeros)
  if ($st.zeros -ge $Limit) {
    if ($ServiceName) { Restart-Service $ServiceName -Force }
    elseif ($TaskName) { Stop-ScheduledTask -TaskName $TaskName; Start-Sleep 2; Start-ScheduledTask -TaskName $TaskName }
    $st.kicks++; $st.zeros = 0
    Log "已重启 $ServiceName$TaskName（累计 $($st.kicks) 次）"
  }
}
$st | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
