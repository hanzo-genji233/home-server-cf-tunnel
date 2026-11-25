#!/usr/bin/env bash
# 5 分钟体验：不要账号、不要域名，把本机一个端口临时发布到 https://xxxx.trycloudflare.com
# 用法：
#   bash quick-try.sh                 # 起一个演示页面并发布
#   bash quick-try.sh --port 3000     # 发布本机已有的 3000 端口
#   bash quick-try.sh --check         # 自测：拿到网址后从外网访问一次就退出
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

PORT=""; CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "不认识的参数：$1" ;;
  esac
done

CF="$(ensure_cloudflared)"
WORK="$(mktemp -d -t cf-quick)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

if [ -z "$PORT" ]; then
  PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
  cat > "$WORK/index.html" <<HTML
<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Hello from home</title>
<body style="font-family:-apple-system,sans-serif;text-align:center;padding:12vh 1em">
<h1>🏠 这个页面来自我家里的电脑</h1>
<p>$(scutil --get ComputerName 2>/dev/null || hostname) · $(date '+%Y-%m-%d %H:%M')</p>
<p>没有云服务器，没有公网 IP，经 Cloudflare Tunnel 发布。</p></body>
HTML
  (cd "$WORK" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  PIDS+=($!)
  info "演示页面已在 http://127.0.0.1:$PORT 启动"
else
  curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/" || warn "127.0.0.1:$PORT 现在没有响应，网址会打开 502"
fi

LOG="$WORK/cf.log"
"$CF" tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" >"$LOG" 2>&1 &
PIDS+=($!)

URL=""
for _ in $(seq 1 60); do
  URL="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | head -1 || true)"
  [ -n "$URL" ] && break
  sleep 1
done
[ -n "$URL" ] || { tail -20 "$LOG"; die "60 秒内没拿到网址。常见原因：代理软件拦了 cloudflared（见 references/07-pitfalls.md）"; }

ok "外网地址：$URL"
if [ "$CHECK" = 1 ]; then
  # 新网址的 DNS 要几秒才生效，最多等 60 秒
  for _ in $(seq 1 20); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL/" || true)"
    [ "$code" = 200 ] && { ok "自测通过：$URL 返回 200"; exit 0; }
    sleep 3
  done
  die "自测失败：$URL 最后返回 ${code:-无响应}"
fi
info "用手机流量打开上面的网址试试。按 Ctrl+C 结束。"
wait
