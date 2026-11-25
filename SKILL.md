---
name: home-server-cf-tunnel
description: "Turn a home Mac or Windows PC into a 'cloud server': publish local web apps, APIs and SSH to your own domain over HTTPS with Cloudflare Tunnel — no public IP, no port forwarding, no VPS bill. Use when the user says: 把家里电脑当服务器 / 不想续费云服务器 / 用 Cloudflare 隧道发布本地服务 / 内网穿透 / 让外网访问我电脑上的网站 / self-host on my Mac mini / expose localhost to my domain / cloudflared tunnel setup / SSH into my home machine from outside. Not for: game servers or anything that needs raw UDP/TCP ports (use a VPS), or bypassing an employer's network policy."
---

# Home Server via Cloudflare Tunnel

Make a computer at home behave like a cloud server: `https://app.your-domain.com` → Cloudflare → an outbound tunnel → `127.0.0.1:3000` on the home machine.

```
Visitor ──HTTPS──► Cloudflare edge (TLS cert, DDoS, optional login)
                        │  outbound-only tunnel (the home PC dials out; nothing is opened on the router)
                        ▼
              Home Mac / Windows PC: cloudflared ──► 127.0.0.1:<port> (your app)
```

All scripts live next to this file. `$SKILL` below means the directory that holds this `SKILL.md`.

## 0. Before you start: ask the user (max 4 questions)

1. Which OS will be the server? (macOS / Windows)
2. What do you want to publish? A list of `name → local port` (for example `blog → 3000`, `api → 8080`). If none yet, use the quick try in step 1.
3. Do you have a domain whose DNS is on Cloudflare (free plan is fine)? If not, step 1 still works; for steps 2+ the domain must be added to Cloudflare first (see `references/01-how-it-works.md` §3).
4. Should any of it be private (admin panels, SSH, personal data)? Those get Cloudflare Access in step 5.

Do not run anything that needs `sudo` / administrator rights yourself. Print the command and ask the user to run it.

## 1. Five-minute try (no account, no domain)

Proves the idea works on this machine. Gives a random `https://xxxx.trycloudflare.com` URL.

```bash
bash $SKILL/scripts/macos/quick-try.sh              # serves a demo page
bash $SKILL/scripts/macos/quick-try.sh --port 3000  # exposes an existing local app
```

```powershell
powershell -ExecutionPolicy Bypass -File $SKILL\scripts\windows\quick-try.ps1
powershell -ExecutionPolicy Bypass -File $SKILL\scripts\windows\quick-try.ps1 -Port 3000
```

Quick tunnels are for testing only: the URL changes on every run and there is no uptime guarantee.

## 2. Pick a route for the permanent setup

| | Route A: dashboard + token | Route B: config file (scripts) |
|---|---|---|
| Who | Beginners, 1–3 services | Several services, wants everything in files / git |
| Where hostnames live | Cloudflare dashboard UI | `~/.cloudflared/<name>.yml` |
| Runs at boot | System service (needs sudo / admin once) | macOS: user LaunchAgent (no sudo). Windows: logon task (no admin) or service (admin) |
| Guide | `references/02-route-a-dashboard.md` | this file, step 3 |

Default to Route B when the user has a domain on Cloudflare and more than one service. Default to Route A when the user prefers clicking over terminals.

## 3. Route B: create the tunnel with one command

The script installs `cloudflared` if missing, logs in (browser opens once), creates the tunnel, writes the config, creates the DNS records and installs a boot service plus a watchdog. Always do a dry run first and show the user the plan.

macOS:

```bash
bash $SKILL/scripts/macos/setup-tunnel.sh --name home \
  --host blog.example.com=http://127.0.0.1:3000 \
  --host api.example.com=http://127.0.0.1:8080 --dry-run
# looks right → run again without --dry-run
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File $SKILL\scripts\windows\setup-tunnel.ps1 -Name home `
  -Hosts "blog.example.com=http://127.0.0.1:3000","api.example.com=http://127.0.0.1:8080" -DryRun
# add -Service (run as Administrator) to start before anyone logs in
```

Re-running is safe and additive: it backs up the old config, keeps the hostnames already in it, adds or updates only the `--host` entries you pass, adds missing DNS records and restarts the tunnel. To drop old hostnames, pass `--replace-hosts` (Windows: `-ReplaceHosts`). Each tunnel gets its own metrics port (kept from the old config, else the first free port from 20241), so the watchdog and doctor never read another tunnel.

## 4. Make the machine behave like a server

A cloud server never sleeps and comes back after a power cut. The home machine must do the same. `doctor` checks these; the user runs the fixes (they need sudo / admin).

| | macOS | Windows |
|---|---|---|
| Never sleep | `sudo pmset -a sleep 0 disksleep 0` | `powercfg /change standby-timeout-ac 0` |
| Power back after outage | `sudo pmset -a autorestart 1` | BIOS: "Restore on AC power loss = On" |
| Start apps without a login | user LaunchAgents need a logged-in user → enable auto-login (System Settings → Users & Groups) | `-Service` mode, or auto-login + logon task |
| Fixed LAN IP (optional) | DHCP reservation on the router | same |

Details: `references/03-macos.md`, `references/04-windows.md`.

## 5. Protect anything private

Everything published is public by default. Before publishing an admin panel, file browser, database UI or SSH, put Cloudflare Access in front of it (free up to 50 users): only listed emails get in, after a one-time code. Steps, plus SSH over the tunnel and service tokens for scripts: `references/05-access-and-ssh.md`.

## 6. Several apps on one hostname / path routing

cloudflared routes by hostname and path regex, but it cannot strip a path prefix. For `site.com/app1 → :8001` and `site.com/app2 → :8002` put a tiny Caddy reverse proxy (single binary, listens on 127.0.0.1 only) between cloudflared and the apps: `references/06-multi-service-caddy.md` and `templates/Caddyfile.example`.

## 7. Check health

```bash
bash $SKILL/scripts/macos/doctor.sh --name home
```

```powershell
powershell -ExecutionPolicy Bypass -File $SKILL\scripts\windows\doctor.ps1 -Name home
```

It checks: cloudflared installed, config valid, service running, live edge connections (from the metrics endpoint), each public hostname answering, each local port listening, sleep / auto-restart settings, proxy-software hints. Read the output and fix ✗ lines first.

## 8. Rules for the agent

1. Never print, commit or upload `~/.cloudflared/*.json`, `cert.pem` or tunnel tokens. They are the keys to the tunnel.
2. Bind local apps to `127.0.0.1`, not `0.0.0.0`, unless the user wants LAN access too. The tunnel only needs localhost.
3. Never publish a service with no login of its own without asking; suggest Access (step 5).
4. Do not run `sudo` / admin commands; print them for the user.
5. After any change, run `doctor` and curl the public URL. Report real status codes, not assumptions.
6. When something fails, read `references/07-pitfalls.md` before guessing. Most failures are listed there.

## Files

| Path | What |
|---|---|
| `references/01-how-it-works.md` | How it works, comparison with a VPS, what it cannot do, adding a domain to Cloudflare |
| `references/02-route-a-dashboard.md` | Route A step by step (dashboard + token) |
| `references/03-macos.md` | macOS details: LaunchAgent, sleep, auto-login, logs |
| `references/04-windows.md` | Windows details: logon task vs service, power, firewall |
| `references/05-access-and-ssh.md` | Cloudflare Access, SSH over the tunnel, service tokens |
| `references/06-multi-service-caddy.md` | Path routing with Caddy |
| `references/07-pitfalls.md` | Known problems and fixes |
| `scripts/macos/*.sh`, `scripts/windows/*.ps1` | quick-try, setup-tunnel, doctor, watchdog |
| `scripts/macos/cfg_tool.py` | read-only helper for setup-tunnel.sh: merge old ingress rules, pick a free metrics port |
| `templates/` | `config.yml.example`, `Caddyfile.example` |
