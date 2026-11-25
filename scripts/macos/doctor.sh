#!/usr/bin/env bash
# 体检：隧道、服务、外网访问、防睡眠。只读，不改任何东西。
# 用法：bash doctor.sh [--name home] [--config 路径]
#   不给 --name 时：只有一个 ~/.cloudflared/*.yml 就用它；否则列出来让你选
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

NAME=""; CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) die "不认识的参数：$1" ;;
  esac
done
FAIL=0
fail() { bad "$*"; FAIL=$((FAIL+1)); }

echo "== cloudflared"
if CF="$(find_cloudflared)"; then ok "$("$CF" --version 2>&1 | head -1)（$CF）"; else fail "没装 cloudflared：bash $HERE/setup-tunnel.sh 会自动装，或 brew install cloudflared"; exit 1; fi

echo "== 配置"
if [ -z "$CONFIG" ]; then
  if [ -n "$NAME" ]; then CONFIG="$HOME/.cloudflared/$NAME.yml"
  else
    cfgs=(); for f in "$HOME"/.cloudflared/*.yml "$HOME"/.cloudflared/*.yaml; do [ -f "$f" ] && cfgs+=("$f"); done
    if [ ${#cfgs[@]} -eq 1 ]; then CONFIG="${cfgs[0]}"
    elif [ ${#cfgs[@]} -eq 0 ]; then fail "~/.cloudflared/ 下没有配置文件。还没建隧道？先跑 setup-tunnel.sh；用的是面板 token 方式（Route A）就只看下面的服务和外网部分"
    else bad "有多个配置，请用 --config 指定："; printf '    %s\n' "${cfgs[@]}"; exit 1; fi
  fi
fi
[ -z "$NAME" ] && [ -n "$CONFIG" ] && NAME="$(basename "$CONFIG" | sed -E 's/\.ya?ml$//')"
HOSTS=(); SERVICES=(); METRICS=""
if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
  if "$CF" tunnel --config "$CONFIG" ingress validate >/dev/null 2>&1; then ok "配置有效：$CONFIG"; else fail "配置校验失败：$CF tunnel --config $CONFIG ingress validate"; fi
  cred="$(awk '/^credentials-file:/{print $2}' "$CONFIG")"
  [ -n "$cred" ] && { [ -f "$cred" ] && ok "凭据文件在：$cred" || fail "凭据文件不存在：$cred"; }
  METRICS="$(awk '/^metrics:/{print $2}' "$CONFIG")"
  while IFS= read -r l; do HOSTS+=("$l"); done < <(awk '/hostname:/{print $NF}' "$CONFIG" | awk '!seen[$0]++')
  while IFS= read -r l; do SERVICES+=("$l"); done < <(awk '/service:/{print $NF}' "$CONFIG" | grep -E '^(https?|ssh|tcp)://' | sort -u)
elif [ -n "$CONFIG" ]; then fail "找不到 $CONFIG"; fi

echo "== 开机自启"
LABEL="com.cloudflared.$NAME"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  st="$(launchctl print "gui/$(id -u)/$LABEL" | awk -F'= ' '/^\tstate =/{print $2; exit}')"
  [ "$st" = running ] && ok "LaunchAgent $LABEL 在运行" || fail "LaunchAgent $LABEL 状态：$st。看日志 ~/Library/Logs/cloudflared/$NAME.log"
elif pgrep -f "cloudflared.*tunnel" >/dev/null; then
  ok "cloudflared 进程在运行（不是本工具装的 LaunchAgent，可能是 Route A 的系统服务或手动启动）"
else
  fail "没有 cloudflared 在运行"
fi
launchctl print "gui/$(id -u)/$LABEL.watchdog" >/dev/null 2>&1 && ok "看门狗已装" || warn "没装看门狗（断线卡死时不会自动重启）"

echo "== 边缘连接"
# 配置里没写 metrics 时，cloudflared 默认在 127.0.0.1:20241～20245 里挑一个空闲端口
if [ -z "$METRICS" ]; then
  for p in 20241 20242 20243 20244 20245; do
    curl -s --max-time 2 "http://127.0.0.1:$p/metrics" | grep -q '^cloudflared_tunnel_ha_connections ' && { METRICS="127.0.0.1:$p"; break; }
  done
fi
if [ -n "$METRICS" ]; then
  ha="$(curl -s --max-time 3 "http://$METRICS/metrics" | awk '/^cloudflared_tunnel_ha_connections /{print int($2)}')"
  if [ "${ha:-0}" -ge 2 ]; then ok "$ha 条连接到 Cloudflare（正常是 4）"
  elif [ "${ha:-0}" -ge 1 ]; then warn "只有 $ha 条连接，网络可能不稳"
  else fail "0 条连接或读不到 metrics（$METRICS）。看日志里的 ERR，见 references/07-pitfalls.md"; fi
else
  warn "读不到 metrics，没法检查连接数。在配置里加一行 metrics: 127.0.0.1:20241"
fi

echo "== 本地服务"
for s in "${SERVICES[@]:-}"; do
  [ -z "$s" ] && continue
  hp="${s#*://}"; hp="${hp%%/*}"; h="${hp%:*}"; p="${hp##*:}"
  [ "$h" = "$p" ] && { case "$s" in https*) p=443;; ssh*) p=22;; *) p=80;; esac; }
  if nc -z -G 2 "$h" "$p" >/dev/null 2>&1; then ok "$s 在监听"; else fail "$s 没有在监听：先把这个服务启动起来"; fi
done

echo "== 外网访问"
for host in "${HOSTS[@]:-}"; do
  [ -z "$host" ] && continue
  case "$host" in ssh.*|ssh-*|*ssh*) info "$host 是 SSH 入口，跳过网页检查"; continue ;; esac
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$host/" || true)"
  case "$code" in
    2*|3*) ok "https://$host → $code" ;;
    401|403) ok "https://$host → $code（有登录保护，正常）" ;;
    404) warn "https://$host → 404：隧道通了；是本地服务返回 404，或这个域名没写进 ingress" ;;
    502) fail "https://$host → 502：隧道通了，本地服务没响应" ;;
    530) fail "https://$host → 530：DNS 指向隧道了，但隧道没连上（看上面的边缘连接）" ;;
    000|"") fail "https://$host → 无响应：DNS 还没生效，或本机网络 / 代理拦了" ;;
    *) warn "https://$host → $code" ;;
  esac
done

echo "== 像服务器一样常在线"
pm="$(pmset -g 2>/dev/null)"
sl="$(awk '$1=="sleep"{print $2}' <<<"$pm")"; ar="$(awk '$1=="autorestart"{print $2}' <<<"$pm")"
[ "$sl" = 0 ] && ok "不会睡眠（sleep 0）" || warn "会睡眠（sleep $sl）：sudo pmset -a sleep 0 disksleep 0"
if [ -z "$ar" ]; then info "这台 Mac 没有断电自动开机选项（笔记本常见）"
elif [ "$ar" = 1 ]; then ok "断电恢复后自动开机"; else warn "断电后不会自动开机：sudo pmset -a autorestart 1"; fi
al="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
[ -n "$al" ] && ok "已开自动登录（$al）" || warn "没开自动登录：重启后要有人登录，LaunchAgent 才会启动"

echo "== 代理软件"
if pgrep -ifl "clash|mihomo|surge|stash|shadowrocket|v2ray|sing-box" >/dev/null 2>&1; then
  warn "检测到代理软件在运行。若隧道频繁断开，给 cloudflared 单独设规则（直连或稳定节点），见 references/07-pitfalls.md 第 3 条"
else ok "没检测到常见代理软件"; fi

echo
[ "$FAIL" = 0 ] && ok "体检完成：没有 ✗" || bad "体检完成：$FAIL 项 ✗，先修这些"
exit "$FAIL"
