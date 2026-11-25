# 02 Route A：全程在 Cloudflare 网页上点（面板 + token 方式）

适合：不想碰配置文件、只有一两个服务的人。Mac 和 Windows 步骤一样，只有最后一条安装命令不同。

## 步骤

1. 打开 Cloudflare 控制台 → **Zero Trust**（第一次进要起一个团队名，选 Free 计划；可能要求绑定支付方式，免费计划不扣费）。
2. Networks → **Tunnels** → Create a tunnel → 类型选 **Cloudflared** → 起名（如 `home`）→ Save。
3. 页面会给出一条安装命令，里面带一长串 token。选你的系统：
   - macOS：
     ```bash
     brew install cloudflared
     sudo cloudflared service install <页面上的TOKEN>
     ```
   - Windows（以管理员身份打开 PowerShell）：
     ```powershell
     winget install --id Cloudflare.cloudflared
     cloudflared.exe service install <页面上的TOKEN>
     ```
4. 回到网页，等页面下方显示 Connector 状态为 **HEALTHY**。
5. 下一步 **Public Hostname** → Add：
   - Subdomain：`blog`；Domain：选你的域名
   - Service：Type `HTTP`，URL `127.0.0.1:3000`
   - Save。DNS 记录会自动建好。
6. 手机流量打开 `https://blog.你的域名`。
7. 再加服务就重复第 5 步。

## 要知道的

- token 就是隧道的钥匙，**不要截图外发**。泄露了在 Tunnels 页面删掉重建。
- 这种方式装的是系统级服务（macOS 是 LaunchDaemon，Windows 是服务），开机就跑，不用登录。
- 想换成配置文件方式（Route B），在网页上删掉这条隧道和它的 Public Hostname，再用 `setup-tunnel` 脚本。两种方式的隧道互不影响，但同一个域名只能指向一条隧道。
- 体检脚本照样能用：`doctor` 会提示没有配置文件，然后检查服务、连接数和外网访问。
