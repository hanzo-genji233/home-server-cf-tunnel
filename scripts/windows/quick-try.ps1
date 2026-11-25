# 5 分钟体验：不要账号、不要域名，把本机一个端口临时发布到 https://xxxx.trycloudflare.com
# 用法：
#   powershell -ExecutionPolicy Bypass -File quick-try.ps1              # 起一个演示页面并发布
#   powershell -ExecutionPolicy Bypass -File quick-try.ps1 -Port 3000   # 发布本机已有的 3000 端口
#   powershell -ExecutionPolicy Bypass -File quick-try.ps1 -Check       # 自测：拿到网址后访问一次就退出
param([int]$Port = 0, [switch]$Check)
. (Join-Path $PSScriptRoot 'lib.ps1')

$cf = Ensure-Cloudflared
$work = Join-Path $env:TEMP ("cf-quick-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$procs = @()
$demo = $null

try {
  if ($Port -eq 0) {
    # 用 PowerShell 自带的 HttpListener 起演示页面（不需要装 Python / Node）
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $Port = $l.LocalEndpoint.Port; $l.Stop()
    $html = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>Hello from home</title>" +
            "<body style='font-family:sans-serif;text-align:center;padding:12vh 1em'><h1>&#x1F3E0; 这个页面来自我家里的电脑</h1>" +
            "<p>$env:COMPUTERNAME &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p><p>没有云服务器，没有公网 IP，经 Cloudflare Tunnel 发布。</p></body>"
    Set-Content -Path (Join-Path $work 'index.html') -Value $html -Encoding UTF8
    $server = @"
`$h = New-Object Net.HttpListener; `$h.Prefixes.Add('http://127.0.0.1:$Port/'); `$h.Start()
`$b = [IO.File]::ReadAllBytes('$($work -replace "'", "''")\index.html')
while (`$h.IsListening) { `$c = `$h.GetContext(); `$c.Response.ContentType = 'text/html; charset=utf-8'; `$c.Response.OutputStream.Write(`$b, 0, `$b.Length); `$c.Response.Close() }
"@
    Set-Content -Path (Join-Path $work 'serve.ps1') -Value $server -Encoding UTF8
    # 路径可能含空格（如 C:\Users\Jane Doe），整串参数自己加引号
    $demo = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $work 'serve.ps1')`"" -WindowStyle Hidden -PassThru
    $procs += $demo
    $up = $false
    for ($i = 0; $i -lt 20 -and -not $up; $i++) { Start-Sleep -Milliseconds 500; $up = (Get-HttpCode "http://127.0.0.1:$Port/" 2) -eq 200 }
    if (-not $up) { Die "演示页面没起来（http://127.0.0.1:$Port 无响应）。可以改用 -Port 发布你自己已有的服务" }
    Info "演示页面已在 http://127.0.0.1:$Port 启动"
  } elseif ((Get-HttpCode "http://127.0.0.1:$Port/" 3) -eq 0) {
    Warn "127.0.0.1:$Port 现在没有响应，网址会打开 502"
  }

  $log = Join-Path $work 'cf.log'
  $p = Start-Process $cf -ArgumentList 'tunnel', '--no-autoupdate', '--url', "http://127.0.0.1:$Port" -RedirectStandardError $log -RedirectStandardOutput (Join-Path $work 'cf.out') -WindowStyle Hidden -PassThru
  $procs += $p

  $url = $null
  for ($i = 0; $i -lt 60 -and -not $url; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $log) {
      $m = Select-String -Path $log -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' | Select-Object -First 1
      if ($m) { $url = $m.Matches[0].Value }
    }
  }
  if (-not $url) { Get-Content $log -Tail 20 | Out-Host; Die '60 秒内没拿到网址。常见原因：代理软件或防火墙拦了 cloudflared（见 references/07-pitfalls.md）' }
  Ok "外网地址：$url"

  if ($Check) {
    for ($i = 0; $i -lt 20; $i++) {
      $code = Get-HttpCode "$url/" 10
      if ($code -eq 200) { Ok "自测通过：$url 返回 200"; exit 0 }
      Start-Sleep -Seconds 3
    }
    Die "自测失败：$url 最后返回 $code"
  }
  Info '用手机流量打开上面的网址试试。按 Ctrl+C 结束。'
  Wait-Process -Id $p.Id
} finally {
  foreach ($x in $procs) { if ($x -and -not $x.HasExited) { Stop-Process -Id $x.Id -Force -ErrorAction SilentlyContinue } }
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
