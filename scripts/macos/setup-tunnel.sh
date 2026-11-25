#!/usr/bin/env bash
# 一条命令把本机服务发布到自己的域名（Cloudflare Tunnel，配置文件方式）。可重复运行。
#
# 用法：
#   bash setup-tunnel.sh --name home \
#        --host blog.example.com=http://127.0.0.1:3000 \
#        --host api.example.com=http://127.0.0.1:8080 [选项]
#
# 选项：
#   --dry-run         只打印要做的事和生成的文件，不改任何东西
#   --overwrite-dns   域名已有记录（比如以前指向云服务器的 A 记录）时改成指向隧道
#   --no-service      不装开机自启（自己用 cloudflared tunnel run 前台跑）
#   --no-watchdog     不装看门狗
#   --no-dns          不自动建 DNS（域名不在登录授权的那个 zone 时，去面板手动加 CNAME）
#   --ssh HOST        额外发布本机 SSH（HOST=ssh.example.com）。务必再配 Cloudflare Access，见 references/05
#
# 做的事：装 cloudflared → 浏览器登录一次 → 建隧道 → 写 ~/.cloudflared/<name>.yml
#        → 校验 → 建 DNS 记录 → 装 LaunchAgent（不需要 sudo）→ 装看门狗 → 等隧道连上
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

NAME=""; HOSTS=(); DRY=0; OVERWRITE=0; SERVICE=1; WATCHDOG=1; DNS=1; SSH_HOST=""
METRICS_PORT="${CF_METRICS_PORT:-20241}"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --host) HOSTS+=("$2"); shift 2 ;;
    --ssh) SSH_HOST="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --overwrite-dns) OVERWRITE=1; shift ;;
    --no-service) SERVICE=0; shift ;;
    --no-watchdog) WATCHDOG=0; shift ;;
    --no-dns) DNS=0; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "不认识的参数：$1（--help 看用法）" ;;
  esac
done
[ -n "$NAME" ] || die "缺 --name（隧道名，比如 home）"
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "--name 只能用字母、数字、- 和 _"
[ ${#HOSTS[@]} -gt 0 ] || [ -n "$SSH_HOST" ] || die "至少要一个 --host 域名=本地地址"
for h in "${HOSTS[@]:-}"; do
  [ -z "$h" ] && continue
  [[ "$h" == *=http://* || "$h" == *=https://* ]] || die "--host 写成 域名=http://127.0.0.1:端口，收到的是：$h"
done

CFDIR="$HOME/.cloudflared"
CONFIG="$CFDIR/$NAME.yml"
LABEL="com.cloudflared.$NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WLABEL="com.cloudflared.$NAME.watchdog"
WPLIST="$HOME/Library/LaunchAgents/$WLABEL.plist"
# 日志不能放 ~/Documents、~/Desktop：launchd 没有权限写，会退出码 78
LOGDIR="$HOME/Library/Logs/cloudflared"
SHARE="$HOME/.local/share/cf-tunnel"

run() { if [ "$DRY" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# ---------- 1. cloudflared ----------
if [ "$DRY" = 1 ]; then
  CF="$(find_cloudflared || echo "$HOME/.local/bin/cloudflared")"
else
  CF="$(ensure_cloudflared)"
fi
ok "cloudflared：$CF"

# ---------- 2. 登录（生成 cert.pem，授权你在 Cloudflare 上的一个域名）----------
if [ -f "$CFDIR/cert.pem" ]; then
  ok "已登录（$CFDIR/cert.pem）"
else
  info "接下来会打开浏览器：登录 Cloudflare → 选你的域名 → Authorize"
  run "$CF" tunnel login
fi

# ---------- 3. 隧道 ----------
tunnel_id() {
  "$CF" tunnel list -o json 2>/dev/null | python3 -c '
import json,sys
name=sys.argv[1]
for t in json.load(sys.stdin) or []:
    if t.get("name")==name:
        print(t["id"]); break' "$NAME" || true
}
TID=""
if [ "$DRY" = 0 ] || [ -f "$CFDIR/cert.pem" ]; then TID="$(tunnel_id)"; fi
if [ -n "$TID" ]; then
  ok "隧道 $NAME 已存在：$TID"
else
  info "新建隧道 $NAME"
  if [ "$DRY" = 1 ]; then run "$CF" tunnel create "$NAME"; TID="<新隧道ID>"
  else "$CF" tunnel create "$NAME" >&2; TID="$(tunnel_id)"; [ -n "$TID" ] || die "隧道建好了但查不到 ID"; fi
fi
CRED="$CFDIR/$TID.json"
[ "$DRY" = 1 ] || [ -f "$CRED" ] || die "找不到隧道凭据 $CRED。隧道可能是在别的电脑上建的：把那台的 $TID.json 拷过来，或换个 --name 新建"

# ---------- 4. 配置文件 ----------
gen_config() {
  echo "# 由 home-server-cf-tunnel/setup-tunnel.sh 生成于 $(date '+%Y-%m-%d %H:%M')。可以手改，改完重跑 doctor.sh"
  echo "tunnel: $TID"
  echo "credentials-file: $CRED"
  echo "# 看门狗和 doctor 读这个地址判断隧道连没连上"
  echo "metrics: 127.0.0.1:$METRICS_PORT"
  echo "no-autoupdate: true"
  echo "# 默认 quic；所在网络 / 代理挡 UDP 时改成 http2（见 references/07-pitfalls.md）"
  echo "protocol: ${CF_PROTOCOL:-auto}"
  echo "ingress:"
  local h host svc
  for h in "${HOSTS[@]:-}"; do
    [ -z "$h" ] && continue
    host="${h%%=*}"; svc="${h#*=}"
    echo "  - hostname: $host"
    echo "    service: $svc"
  done
  if [ -n "$SSH_HOST" ]; then
    echo "  - hostname: $SSH_HOST"
    echo "    service: ssh://127.0.0.1:22"
  fi
  echo "  # 最后一条必须是兜底：没匹配上的域名一律 404"
  echo "  - service: http_status:404"
}
NEWCFG="$(gen_config)"
if [ "$DRY" = 1 ]; then
  info "将写入 $CONFIG："; printf '%s\n' "$NEWCFG" | sed 's/^/    /' >&2
else
  mkdir -p "$CFDIR"
  [ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d-%H%M%S)" && info "旧配置已备份"
  printf '%s\n' "$NEWCFG" > "$CONFIG"
  "$CF" tunnel --config "$CONFIG" ingress validate >&2 || die "配置校验失败：$CONFIG"
  ok "配置已写入并校验通过：$CONFIG"
fi

# ---------- 5. DNS ----------
ALL_HOSTS=()
for h in "${HOSTS[@]:-}"; do [ -n "$h" ] && ALL_HOSTS+=("${h%%=*}"); done
[ -n "$SSH_HOST" ] && ALL_HOSTS+=("$SSH_HOST")
for host in "${ALL_HOSTS[@]}"; do
  if [ "$DNS" = 0 ]; then info "跳过 DNS：到 Cloudflare 面板给 $host 加 CNAME → $TID.cfargotunnel.com（开小黄云）"; continue; fi
  args=(tunnel route dns); [ "$OVERWRITE" = 1 ] && args+=(--overwrite-dns)
  if [ "$DRY" = 1 ]; then run "$CF" "${args[@]}" "$NAME" "$host"; continue; fi
  if out="$("$CF" "${args[@]}" "$NAME" "$host" 2>&1)"; then
    ok "DNS：$host → 隧道 $NAME"
    # cloudflared 只认登录时选的那个 zone；别的域名会被拼成 host.<那个zone>，要看清楚
    grep -Eo 'Added CNAME [^ ]+' <<<"$out" | sed 's/^/    /' >&2 || true
  elif grep -qi "already exists" <<<"$out"; then
    warn "DNS：$host 已有记录。若它指向旧服务器，加 --overwrite-dns 重跑；若已指向本隧道，可忽略"
  else
    printf '%s\n' "$out" | tail -3 >&2
    warn "DNS：$host 自动创建失败。常见原因：这个域名不在登录时授权的那个 zone。到 Cloudflare 面板手动加 CNAME：$host → $TID.cfargotunnel.com（开小黄云）"
  fi
done

# ---------- 6. 开机自启（LaunchAgent，用户登录后启动，不需要 sudo）----------
plist_tunnel() { cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$CF</string><string>tunnel</string><string>--config</string><string>$CONFIG</string><string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOGDIR/$NAME.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/$NAME.log</string>
</dict></plist>
XML
}
plist_watchdog() { cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$WLABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>$SHARE/watchdog.py</string>
    <string>--label</string><string>$LABEL</string><string>--metrics</string><string>http://127.0.0.1:$METRICS_PORT/metrics</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOGDIR/$NAME-watchdog.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/$NAME-watchdog.log</string>
</dict></plist>
XML
}
reload() { # $1 label  $2 plist
  launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$2"
}

if [ "$SERVICE" = 1 ]; then
  if [ "$DRY" = 1 ]; then
    info "将写入 $PLIST 并加载（launchctl bootstrap）"
  else
    mkdir -p "$LOGDIR" "$(dirname "$PLIST")"
    plist_tunnel > "$PLIST"
    reload "$LABEL" "$PLIST"
    ok "开机自启已装：$LABEL（日志 $LOGDIR/$NAME.log）"
  fi
  if [ "$WATCHDOG" = 1 ]; then
    if [ "$DRY" = 1 ]; then
      info "将安装看门狗 $WLABEL：每 60 秒查一次，连续 3 次 0 条连接就重启隧道"
    else
      mkdir -p "$SHARE"; cp "$HERE/watchdog.py" "$SHARE/watchdog.py"
      plist_watchdog > "$WPLIST"
      reload "$WLABEL" "$WPLIST"
      ok "看门狗已装：$WLABEL"
    fi
  fi
else
  info "没装自启。手动运行：$CF tunnel --config $CONFIG run"
fi

[ "$DRY" = 1 ] && { ok "dry-run 结束，没有改动任何东西。确认无误后去掉 --dry-run 再跑一次。"; exit 0; }

# ---------- 7. 等隧道连上，再从外网访问一次 ----------
if [ "$SERVICE" = 1 ]; then
  info "等隧道连上 Cloudflare…"
  ha=0
  for _ in $(seq 1 30); do
    ha="$(curl -s --max-time 2 "http://127.0.0.1:$METRICS_PORT/metrics" | awk '/^cloudflared_tunnel_ha_connections /{print int($2)}')"
    [ "${ha:-0}" -gt 0 ] && break; sleep 2
  done
  if [ "${ha:-0}" -gt 0 ]; then ok "隧道已连上：$ha 条边缘连接"; else warn "60 秒内没连上，看日志：tail -50 $LOGDIR/$NAME.log"; fi
  for h in "${HOSTS[@]:-}"; do
    [ -z "$h" ] && continue
    host="${h%%=*}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$host/" || true)"
    case "$code" in
      2*|3*|401|403) ok "https://$host → $code" ;;
      502) warn "https://$host → 502：隧道通了，但本地服务 ${h#*=} 没响应" ;;
      530|1033) warn "https://$host → $code：隧道还没连上或 DNS 没指到这条隧道" ;;
      *) warn "https://$host → ${code:-无响应}（新建的 DNS 可能要等一两分钟，过会儿跑 doctor.sh）" ;;
    esac
  done
fi
cat >&2 <<TIP

下一步（像云服务器一样 24 小时在线，需要你自己执行，要输入开机密码）：
  sudo pmset -a sleep 0 disksleep 0 autorestart 1 womp 1
  系统设置 → 用户与群组 → 开启自动登录（LaunchAgent 要有用户登录才会启动）
体检：bash $HERE/doctor.sh --name $NAME
TIP
