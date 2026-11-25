#!/usr/bin/env python3
"""Small helpers for setup-tunnel.sh. Only reads files; never writes.

  cfg_tool.py keep CONFIG [HOST ...]   print old ingress rules whose hostname is not in HOST...
                                        (re-indented to 2 spaces, catch-all dropped)
  cfg_tool.py hosts CONFIG             print hostnames in the old ingress, one per line
  cfg_tool.py metrics CONFIG           print the metrics port of CONFIG (empty if none)
  cfg_tool.py freeport DIR [SELF]      print the first port from 20241 not used by any
                                        DIR/*.yml metrics line (except SELF) and not listening
"""
import glob
import os
import re
import socket
import sys


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().splitlines()
    except OSError:
        return []


def rules(lines):
    """Return ingress rules as (hostname or None, [raw lines]) with the original indent."""
    start = next((i for i, l in enumerate(lines) if re.match(r"^ingress:\s*(#.*)?$", l)), None)
    if start is None:
        return [], 0
    blocks, ind = [], None
    for l in lines[start + 1:]:
        if l and not l[0].isspace() and not l.startswith("#"):
            break  # next top-level key
        m = re.match(r"^(\s*)-(\s|$)", l)
        if m and (ind is None or len(m.group(1)) == ind):
            ind = len(m.group(1))
            blocks.append([l])
        elif blocks:
            blocks[-1].append(l)
    out = []
    for b in blocks:
        while b and (not b[-1].strip() or b[-1].strip().startswith("#")):
            b.pop()  # trailing comments belong to the next rule (or the catch-all)
        host = None
        for l in b:
            m = re.match(r"^\s*(?:-\s+)?hostname:\s*['\"]?([^'\"\s#]+)", l)
            if m and (l.lstrip().startswith("-") or len(l) - len(l.lstrip()) == (ind or 0) + 2):
                host = m.group(1)
                break
        out.append((host, b))
    return out, ind or 0


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd in ("keep", "hosts"):
        rs, ind = rules(read(args[0]))
        if rs and rs[-1][0] is None:
            rs = rs[:-1]  # catch-all; the caller writes a new one
        drop = {h.lower() for h in args[1:]}
        for host, block in rs:
            if cmd == "hosts":
                if host:
                    print(host)
                continue
            if host and host.lower() in drop:
                continue
            delta = 2 - ind
            for l in block:
                print((" " * delta + l) if delta >= 0 else re.sub(r"^ {0,%d}" % -delta, "", l))
    elif cmd == "metrics":
        for l in read(args[0]):
            m = re.match(r"^metrics:\s*['\"]?[^:'\"]*:(\d+)", l)
            if m:
                print(m.group(1))
                break
    elif cmd == "freeport":
        used = set()
        me = os.path.abspath(args[1]) if len(args) > 1 else None
        for f in glob.glob(os.path.join(args[0], "*.yml")):
            if os.path.abspath(f) == me:
                continue
            for l in read(f):
                m = re.match(r"^metrics:\s*['\"]?[^:'\"]*:(\d+)", l)
                if m:
                    used.add(int(m.group(1)))
        for p in range(20241, 20300):
            if p in used:
                continue
            s = socket.socket()
            try:
                s.bind(("127.0.0.1", p))
            except OSError:
                continue
            finally:
                s.close()
            print(p)
            return
        sys.exit("no free metrics port in 20241-20299")


if __name__ == "__main__":
    main()
