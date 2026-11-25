#!/usr/bin/env bash
# 公共函数：输出、找 / 装 cloudflared。被其他脚本 source。
if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[34m'; N=$'\e[0m'; else G=; Y=; R=; B=; N=; fi
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s△%s %s\n' "$Y" "$N" "$*" >&2; }
bad()  { printf '%s✗%s %s\n' "$R" "$N" "$*"; }
info() { printf '%s›%s %s\n' "$B" "$N" "$*" >&2; }
die()  { bad "$*" >&2; exit 1; }

find_cloudflared() {
  local c
  for c in "$(command -v cloudflared 2>/dev/null || true)" "$HOME/.local/bin/cloudflared" /opt/homebrew/bin/cloudflared /usr/local/bin/cloudflared; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# 找不到就装：有 Homebrew 用 brew；没有就从 GitHub 官方 Release 下载到 ~/.local/bin（不需要 sudo）
ensure_cloudflared() {
  local c arch url tmp
  if c="$(find_cloudflared)"; then echo "$c"; return 0; fi
  if command -v brew >/dev/null 2>&1; then
    info "用 Homebrew 安装 cloudflared…"
    brew install cloudflared >&2 && find_cloudflared && return 0
  fi
  case "$(uname -m)" in arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-$arch.tgz"
  info "从 Cloudflare 官方 GitHub Release 下载：$url"
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/cf.tgz" || die "下载失败，检查网络，或手动安装：brew install cloudflared"
  tar -xzf "$tmp/cf.tgz" -C "$tmp"
  mkdir -p "$HOME/.local/bin"
  mv "$tmp/cloudflared" "$HOME/.local/bin/cloudflared"
  chmod +x "$HOME/.local/bin/cloudflared"
  xattr -d com.apple.quarantine "$HOME/.local/bin/cloudflared" 2>/dev/null || true
  rm -rf "$tmp"
  "$HOME/.local/bin/cloudflared" --version >&2 || die "cloudflared 装好了但运行失败"
  echo "$HOME/.local/bin/cloudflared"
}
