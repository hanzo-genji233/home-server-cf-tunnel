# 公共函数：输出、找 / 装 cloudflared。被其他脚本 dot-source。兼容 Windows PowerShell 5.1。
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!]  $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "[X]  $m" -ForegroundColor Red }
function Info($m) { Write-Host ">    $m" -ForegroundColor Cyan }
function Die($m)  { Bad $m; exit 1 }

$script:CfLocal = Join-Path $env:LOCALAPPDATA 'cloudflared\cloudflared.exe'

function Find-Cloudflared {
  $c = Get-Command cloudflared -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @($script:CfLocal, "$env:ProgramFiles\cloudflared\cloudflared.exe", "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe")) {
    if ($p -and (Test-Path $p)) { return $p }
  }
  return $null
}

# 找不到就装：先 winget；没有 winget 就从 Cloudflare 官方 GitHub Release 下载到 %LOCALAPPDATA%\cloudflared（不需要管理员）
function Ensure-Cloudflared {
  $c = Find-Cloudflared
  if ($c) { return $c }
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Info '用 winget 安装 cloudflared…'
    winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements | Out-Host
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $c = Find-Cloudflared
    if ($c) { return $c }
  }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
  $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$arch.exe"
  Info "从 Cloudflare 官方 GitHub Release 下载：$url"
  New-Item -ItemType Directory -Force -Path (Split-Path $script:CfLocal) | Out-Null
  $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $script:CfLocal } catch { Die "下载失败：$($_.Exception.Message)。手动安装：winget install Cloudflare.cloudflared" }
  finally { $ProgressPreference = $old }
  & $script:CfLocal --version | Out-Host
  return $script:CfLocal
}

function Get-HaConnections([string]$MetricsHostPort) {
  try {
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri "http://$MetricsHostPort/metrics"
    foreach ($line in ($r.Content -split "`n")) {
      if ($line -like 'cloudflared_tunnel_ha_connections *') { return [int][double]($line.Split(' ')[1]) }
    }
  } catch {}
  return $null
}

function Get-HttpCode([string]$Url, [int]$Timeout = 15) {
  # 不跟随跳转：被 Cloudflare Access 保护的站点返回 302，也算“通了”
  try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.AllowAutoRedirect = $false; $req.Timeout = $Timeout * 1000; $req.UserAgent = 'home-server-cf-tunnel-doctor'
    $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close(); return $code
  } catch [Net.WebException] {
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close(); return $code }
    return 0
  } catch { return 0 }
}
