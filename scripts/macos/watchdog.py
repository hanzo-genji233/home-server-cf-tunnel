#!/usr/bin/env python3
"""cloudflared 看门狗（macOS，launchd 每 60 秒跑一次）。

为什么要它：cloudflared 和 Cloudflare 边缘断开后，偶尔会卡住不重连。
进程还活着，launchd 的 KeepAlive 管不到，网站却一直 530。
做法：读 cloudflared 的 metrics 里的 cloudflared_tunnel_ha_connections，
连续 N 次为 0（或读不到）就 `launchctl kickstart -k` 重启隧道。
日志只记异常、重启和恢复；日志为空就是一直正常。

只用 Python 标准库，系统自带的 /usr/bin/python3 就能跑。
"""
import argparse, json, os, subprocess, time, urllib.request

STATE_DIR = os.path.expanduser('~/.local/share/cf-tunnel')


def log(msg):
    print('%s %s' % (time.strftime('%Y-%m-%d %H:%M:%S'), msg), flush=True)


def ha_connections(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            for line in r.read().decode().splitlines():
                if line.startswith('cloudflared_tunnel_ha_connections '):
                    return int(float(line.split()[1]))
    except Exception:
        return None
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--label', required=True, help='隧道的 launchd 标签，如 com.cloudflared.home')
    ap.add_argument('--metrics', default='http://127.0.0.1:20241/metrics')
    ap.add_argument('--limit', type=int, default=3, help='连续几次 0 才重启')
    a = ap.parse_args()

    os.makedirs(STATE_DIR, exist_ok=True)
    state_file = os.path.join(STATE_DIR, a.label + '.state.json')
    try:
        st = json.load(open(state_file))
    except (OSError, ValueError):
        st = {'zeros': 0, 'kicks': 0}

    ha = ha_connections(a.metrics)
    if ha:
        if st.get('zeros'):
            log('恢复：%d 条连接（之前连续 %d 次为 0）' % (ha, st['zeros']))
        st['zeros'] = 0
        st['last_ok'] = time.strftime('%Y-%m-%dT%H:%M:%S')
    else:
        st['zeros'] = st.get('zeros', 0) + 1
        log('连接数=%s，连续第 %d 次' % ('读不到' if ha is None else ha, st['zeros']))
        if st['zeros'] >= a.limit:
            target = 'gui/%d/%s' % (os.getuid(), a.label)
            rc = subprocess.run(['launchctl', 'kickstart', '-k', target]).returncode
            st['kicks'] = st.get('kicks', 0) + 1
            st['last_kick'] = time.strftime('%Y-%m-%dT%H:%M:%S')
            st['zeros'] = 0
            log('已重启 %s（rc=%d，累计 %d 次）' % (a.label, rc, st['kicks']))

    tmp = state_file + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(st, f, ensure_ascii=False, indent=1)
    os.replace(tmp, state_file)


if __name__ == '__main__':
    main()
