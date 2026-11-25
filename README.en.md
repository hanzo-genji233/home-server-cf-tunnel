# home-server-cf-tunnel

Turn a Mac or Windows PC at home into your own "cloud server". Publish local websites, APIs and SSH at `https://your-domain.com` with **Cloudflare Tunnel** — no public IP, no port forwarding, no VPS bill.

```
Visitor ──HTTPS──► Cloudflare edge (TLS, DDoS protection, optional login)
                        │ outbound-only tunnel (nothing opened on your router)
                        ▼
             Home Mac / Windows: cloudflared ──► 127.0.0.1:<port>
```

It is also an **Agent Skill** ([SKILL.md](SKILL.md)): drop it into Claude Code / Codex / Cursor skills and say "publish my port 3000 at blog.mydomain.com and keep it running".

## Quick start

1. **Try it in 5 minutes (no account, no domain)** — get a temporary `https://xxxx.trycloudflare.com`:
   - macOS: `bash scripts/macos/quick-try.sh` (or `--port 3000`)
   - Windows: `powershell -ExecutionPolicy Bypass -File scripts\windows\quick-try.ps1`
2. **Your own domain, starts at boot** (domain DNS must be on Cloudflare, free plan is fine). Run with `--dry-run` / `-DryRun` first:
   - macOS: `bash scripts/macos/setup-tunnel.sh --name home --host blog.example.com=http://127.0.0.1:3000`
   - Windows: `setup-tunnel.ps1 -Name home -Hosts "blog.example.com=http://127.0.0.1:3000"` (add `-Service` as admin to run before login)
3. **Keep it online like a server**: disable sleep, enable auto power-on, then run `doctor.sh` / `doctor.ps1`.

The setup script installs cloudflared, logs in once in the browser, creates the tunnel, writes the config, creates DNS records, installs a boot service (macOS LaunchAgent / Windows scheduled task or service) plus a watchdog that restarts the tunnel when it silently drops to 0 edge connections.

## Docs (Chinese)

| | |
|---|---|
| How it works, vs. VPS, limits | [references/01-how-it-works.md](references/01-how-it-works.md) |
| Dashboard + token route | [references/02-route-a-dashboard.md](references/02-route-a-dashboard.md) |
| macOS / Windows details | [03-macos.md](references/03-macos.md) · [04-windows.md](references/04-windows.md) |
| Cloudflare Access, SSH from outside, service tokens | [references/05-access-and-ssh.md](references/05-access-and-ssh.md) |
| Path routing with Caddy | [references/06-multi-service-caddy.md](references/06-multi-service-caddy.md) |
| Pitfalls | [references/07-pitfalls.md](references/07-pitfalls.md) |

## Not a fit for

Game servers or anything needing raw UDP/TCP ports, sites that must be fast inside mainland China (free plan uses overseas edges), large file / video distribution.

## Security

Never share `~/.cloudflared/cert.pem`, `<tunnel-id>.json` or tunnel tokens. Put Cloudflare Access in front of admin panels and SSH. Enable 2FA on your Cloudflare account.

MIT License.
