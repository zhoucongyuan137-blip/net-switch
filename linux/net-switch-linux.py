#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
net-switch (Linux) —— 有线没出口时自动改走手机热点 + 校园网自助认证

Windows 版的对应物是本仓库的 net-switch.ps1（选路）+ campus-login.ps1（认证）；
Linux 上两件事合并成这一个文件，只用 Python 3 标准库（tkinter 仅 GUI 需要）。

与 Windows 版的机制差异：
  · Windows 靠"接口跃点数"决定默认路由；Linux 靠**默认路由的 metric**（同一张路由表里多条 default，metric 小的优先）。
    所以这里不动接口，只是"给热点接口加一条 metric 更小的 default 路由"，撤销时精确删掉那一条即可（比 Windows 更干净）。
  · 探测出口用 SO_BINDTODEVICE 把 socket 钉在指定网卡上（Linux 的确定性做法，等价于 Windows 版的"绑定源地址"）。
  · 没有 DPAPI，密码放在 ~/.config/net-switch/campus.json（0600，只有你自己可读），可用 NETSWITCH_PASSWORD 环境变量覆盖。

用法（详见 README）：
  net-switch-linux.py status                       # 只读：看每条线路与当前默认路由
  net-switch-linux.py auto                         # 单次判断 + 切换 + 兜底认证
  net-switch-linux.py login [--wait-for-ip 40]     # 只做校园网认证
  net-switch-linux.py settle --until wiredup|wireddown --max-minutes N
  net-switch-linux.py gui                          # 图形界面（tkinter）
  net-switch-linux.py install / uninstall          # 装/卸 systemd 单元与定时器（需要 sudo）
  net-switch-linux.py forget                       # 删除保存的凭据
  任何命令都可加 --dry-run：只打印将要执行的命令/判定结果，不改任何东西。
"""

import argparse
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timedelta

VERSION = "1.1.0"
APP = "net-switch"

PROBE_TARGETS = [("223.5.5.5", 443), ("119.29.29.29", 443)]   # 阿里/腾讯 DNS，TCP 通也算通
PROBE_ICMP_FALLBACK = True

# 这些虚拟接口不参与选路（VPN/TUN/容器/网桥…）
VIRTUAL_PATTERNS = re.compile(
    r"^(lo|docker|veth|br-|virbr|tun|tap|wg|tailscale|zt|nebula|Meta|utun|ppp|vmnet|vboxnet)",
    re.I,
)
WIRELESS_PATTERNS = re.compile(r"^(wl\d|wlan\d|wlp\d|wlo\d)", re.I)          # 无线（含手机热点）
TETHER_PATTERNS = re.compile(r"^(usb\d|rndis\d?|enx[0-9a-f]{12})", re.I)   # 手机 USB 网络共享
# 有线：eth0 / eno1 / enp3s0 / ens5 / em1 …（注意 enx… 属于 USB 网卡，归到"热点一侧"，所以放在 TETHER 里）
WIRED_PATTERNS = re.compile(r"^(eth\d+|eno\d+|enp\d+s?\d*|ens\d+|em\d+)", re.I)

DEFAULT_ALT_METRIC = 10

SO_BINDTODEVICE = 25


def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log_path():
    home = os.environ.get("NETSWITCH_HOME") or os.path.dirname(os.path.abspath(__file__))
    return os.path.join(home, "%s.log" % APP)


def log(msg, quiet=False):
    line = "%s  %s" % (now(), msg)
    if not quiet:
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except Exception:
            pass
    try:
        with open(log_path(), "a", encoding="utf-8") as f:
            f.write(line + "\n")
        # 日志超过 2000 行就截断
        p = log_path()
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        if len(lines) > 2000:
            with open(p, "w", encoding="utf-8") as f:
                f.writelines(lines[-1000:])
    except Exception:
        pass


def run(cmd, dry=False, check=False):
    """执行命令；dry=True 只回显。返回 (returncode, stdout)。"""
    if dry:
        log("  [dry-run] " + " ".join(cmd))
        return 0, ""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        if r.returncode != 0 and check:
            log("  ! 命令失败(%d): %s -- %s" % (r.returncode, " ".join(cmd), (r.stderr or "").strip()))
        return r.returncode, (r.stdout or "")
    except Exception as e:
        log("  ! 执行失败: %s (%s)" % (" ".join(cmd), e))
        return 1, ""


def sudo_wrap(cmd):
    """需要 root 的命令：已是 root 就直接跑，否则用 sudo -n（非交互，失败就报错而不是卡住）。"""
    if os.geteuid() == 0:
        return cmd
    if shutil.which("sudo"):
        return ["sudo", "-n"] + cmd
    return cmd


# ---------------------------------------------------------------- 接口 / 路由

def list_interfaces():
    """返回 [{name, ip, cidr, up, kind}]；kind ∈ wired/alt/other"""
    out = []
    rc, txt = run(["ip", "-o", "-4", "addr", "show"])
    addrs = {}
    for line in txt.splitlines():
        m = re.match(r"\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)", line)
        if m:
            addrs.setdefault(m.group(1), []).append((m.group(2), int(m.group(3))))
    rc, link = run(["ip", "-o", "link", "show"])
    state = {}
    for line in link.splitlines():
        m = re.match(r"\d+:\s+(\S+?)(?:@\S+)?:\s+<([^>]*)>.*state\s+(\S+)", line)
        if m:
            state[m.group(1)] = ("UP" in m.group(2).split(",")) and m.group(3).lower() != "down"
    for name in sorted(set(list(addrs.keys()) + list(state.keys()))):
        if VIRTUAL_PATTERNS.match(name):
            continue
        ip = addrs.get(name, [(None, None)])[0][0]
        up = state.get(name, False) and ip is not None
        kind = "other"
        if WIRELESS_PATTERNS.match(name) or TETHER_PATTERNS.match(name):
            kind = "alt"
        elif WIRED_PATTERNS.match(name):
            kind = "wired"
        out.append({"name": name, "ip": ip, "up": up, "kind": kind})
    return out


def default_routes():
    """返回 [{dev, gw, metric}]，按 metric 升序"""
    routes = []
    rc, txt = run(["ip", "-o", "route", "show", "default"])
    for line in txt.splitlines():
        dev = re.search(r"\bdev\s+(\S+)", line)
        gw = re.search(r"\bvia\s+(\S+)", line)
        metric = re.search(r"\bmetric\s+(\d+)", line)
        if dev:
            routes.append({"dev": dev.group(1), "gw": gw.group(1) if gw else None,
                           "metric": int(metric.group(1)) if metric else 0, "raw": line.strip()})
    routes.sort(key=lambda r: r["metric"])
    return routes


def best_route_dev():
    r = default_routes()
    return r[0]["dev"] if r else None


def probe_dev(dev, timeout=1.5):
    """把 socket 钉在这块网卡上探测外网（TCP 优先，ICMP 兜底）。"""
    for dst, port in PROBE_TARGETS:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            try:
                s.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, dev.encode() + b"\0")
            except PermissionError:
                # 老内核/无权限时退化成"绑定该网卡的源地址"
                ip = iface_ip(dev)
                if not ip:
                    return False
                s.bind((ip, 0))
            s.connect((dst, port))
            return True
        except OSError:
            pass
        finally:
            s.close()
    if PROBE_ICMP_FALLBACK and shutil.which("ping"):
        rc, _ = run(["ping", "-c", "1", "-W", "2", "-I", dev, PROBE_TARGETS[0][0]])
        return rc == 0
    return False


def iface_ip(name):
    for i in list_interfaces():
        if i["name"] == name:
            return i["ip"]
    return None


def iface_gw(name):
    for r in default_routes():
        if r["dev"] == name and r["gw"]:
            return r["gw"]
    return None


# ---------------------------------------------------------------- 配置 / 状态

def config_dir():
    return os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), APP)


def state_dir():
    return os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), APP)


def config_path():
    return os.path.join(config_dir(), "campus.json")


def state_path():
    return os.path.join(state_dir(), "state.json")


def campus_state_path():
    return os.path.join(state_dir(), "campus-state.json")


def _load_json(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _save_json(p, obj, mode=0o600):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.chmod(tmp, mode)
    os.replace(tmp, p)


def read_config():
    cfg = _load_json(config_path())
    if not cfg:
        return None
    pwd = os.environ.get("NETSWITCH_PASSWORD")
    if not pwd and cfg.get("password_b64"):
        try:
            pwd = base64.b64decode(cfg["password_b64"]).decode("utf-8")
        except Exception:
            pwd = ""
    return {
        "account": cfg.get("account", ""),
        "operator": cfg.get("operator", "campus"),
        "portal": cfg.get("portal", "http://10.2.5.251:801/eportal/"),
        "password": pwd,
        "password_saved": bool(cfg.get("password_b64")) or bool(os.environ.get("NETSWITCH_PASSWORD")),
        "auto_login": cfg.get("auto_login", True),
    }


def save_config(account, operator, password, portal, auto_login=True):
    old = _load_json(config_path()) or {}
    obj = {
        "account": account,
        "operator": operator,
        "portal": portal,
        "auto_login": bool(auto_login),
        "updated_at": datetime.now().isoformat(timespec="seconds"),
    }
    if password:
        obj["password_b64"] = base64.b64encode(password.encode("utf-8")).decode("ascii")
    elif old.get("password_b64"):
        obj["password_b64"] = old["password_b64"]
    _save_json(config_path(), obj, 0o600)


OP_SUFFIX = {"cmcc": "@cmcc", "unicom": "@unicom", "telecom": "@telecom", "campus": ""}
OP_NAME = {"cmcc": "中国移动", "unicom": "中国联通", "telecom": "中国电信", "campus": "校园网（无后缀）"}


# ---------------------------------------------------------------- 校园网认证

def parse_portal_response(text):
    """dr1003({...}) / 纯 JSON 都要认；返回 (ok, kind, msg)"""
    s = text.strip()
    m = re.search(r"\(\s*(\{.*\})\s*\)", s, re.S)
    if m:
        s = m.group(1)
    try:
        obj = json.loads(s)
    except Exception:
        return False, "unparsed", "响应无法解析: " + text[:160].replace("\n", " ")
    msg = str(obj.get("msg", ""))
    res = str(obj.get("result", ""))
    code = str(obj.get("ret_code", ""))
    if re.search(r"已在线|已经在线|重复认证", msg):
        return True, "already", "该 IP 已在线：" + msg
    if res == "1" or code == "2" or "成功" in msg:
        return True, "ok", msg or "认证成功"
    kind = "failed"
    if re.search(r"密码|账号|用户名", msg):
        kind = "bad-credential"
    elif re.search(r"关闭|维护|不可用|未开放", msg):
        kind = "unavailable"
    return False, kind, "登录未成功: " + msg


def http_get_via_dev(dev, host, port, path, timeout=6):
    """手写 HTTP GET，并把连接钉在 dev 上（不依赖 requests/curl）。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        try:
            s.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, dev.encode() + b"\0")
        except PermissionError:
            ip = iface_ip(dev)
            if ip:
                s.bind((ip, 0))
        s.connect((host, port))
        req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: net-switch/%s\r\n"
               "Accept: */*\r\nConnection: close\r\n\r\n") % (path, host, VERSION)
        s.sendall(req.encode("ascii", "replace"))
        buf = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
            if len(buf) > 65536:
                break
    finally:
        s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    status = 0
    m = re.match(rb"HTTP/\d\.\d\s+(\d+)", head)
    if m:
        status = int(m.group(1))
    text = body.decode("utf-8", "replace")
    if "\ufffd" in text and status:      # 解出乱码就按 GB18030 再试（不少门户是 GBK）
        text = body.decode("gb18030", "replace")
    return status, text


def campus_login(cfg, wired, wait_for_ip=0, force=False, quiet=False, dry=False):
    """返回 (ok, kind, msg)。wired = 有线接口名"""
    if not cfg or not cfg.get("account"):
        return False, "no-config", "还没有配置校园网账号"
    pwd = cfg.get("password")
    if not pwd:
        return False, "no-password", "还没有保存密码"
    if not wired:
        return False, "no-wired", "没有可用的有线接口"
    waited = 0
    while wait_for_ip and not iface_ip(wired) and waited < wait_for_ip:
        time.sleep(2)
        waited += 2
    ip = iface_ip(wired)
    if not ip:
        return False, "no-wired-ip", "有线接口 %s 还没拿到 IPv4" % wired

    portal = cfg["portal"]
    m = re.match(r"http://([^/:]+)(?::(\d+))?(.*)$", portal)
    if not m:
        return False, "bad-portal", "认证服务器地址不合法: " + portal
    host, port, basepath = m.group(1), int(m.group(2) or 80), (m.group(3) or "/")
    basepath = basepath.rstrip("/") or ""
    user = cfg["account"] + OP_SUFFIX.get(cfg["operator"], "")
    from urllib.parse import quote
    path = "%s/?c=Portal&a=login&login_method=1&user_account=%s&user_password=%s&wlan_user_ip=%s" % (
        basepath, quote(user, safe=""), quote(pwd, safe=""), quote(ip, safe=""))
    log("  发起认证: 账号=%s%s 本机IP=%s 接口=%s" % (cfg["account"], OP_SUFFIX.get(cfg["operator"], ""), ip, wired), quiet)
    if dry:
        log("  [dry-run] GET http://%s:%d%s" % (host, port, path.replace(quote(pwd, safe=""), "******")), quiet)
        return True, "dry-run", "演练：未真正请求"
    try:
        status, body = http_get_via_dev(wired, host, port, path)
    except Exception as e:
        return False, "unreachable", "连不上认证服务器 %s:%d（%s）" % (host, port, e)
    log("  认证响应 HTTP %s: %s" % (status, body.strip()[:200].replace("\n", " ")), quiet)
    ok, kind, msg = parse_portal_response(body)
    if ok:
        time.sleep(0.8)
        if probe_dev(wired):
            return True, kind, "认证成功，外网已通"
        return True, "ok-unconfirmed", "认证接口返回成功，但外网暂时还不通：" + msg
    return ok, kind, msg


def campus_login_rate_limited(cfg, wired, wait_for_ip=0, force=False, quiet=False,
                              dry=False, min_interval=180, fail_backoff_min=30):
    """带频率限制/失败退避的认证入口（给自动流程用）。"""
    st = _load_json(campus_state_path()) or {}
    nowdt = datetime.now()
    if not force:
        bu = st.get("backoff_until")
        if bu:
            try:
                if nowdt < datetime.fromisoformat(bu):
                    log("上次失败（%s），退避到 %s，本次跳过。" % (st.get("last_msg", ""), bu), quiet)
                    return False, "backoff", "处于退避期"
            except Exception:
                pass
        la = st.get("last_attempt")
        if la:
            try:
                if (nowdt - datetime.fromisoformat(la)).total_seconds() < min_interval:
                    log("距上次尝试太近，跳过。", quiet)
                    return False, "too-soon", "间隔太短"
            except Exception:
                pass
    ok, kind, msg = campus_login(cfg, wired, wait_for_ip, force, quiet, dry)
    if ok:
        _save_json(campus_state_path(), {"last_attempt": nowdt.isoformat(timespec="seconds"),
                                        "last_result": kind, "last_msg": msg, "backoff_until": None})
    else:
        _save_json(campus_state_path(), {"last_attempt": nowdt.isoformat(timespec="seconds"),
                                        "last_result": kind, "last_msg": msg,
                                        "backoff_until": (nowdt + timedelta(minutes=fail_backoff_min)).isoformat(timespec="seconds")})
    return ok, kind, msg


# ---------------------------------------------------------------- 选路

def set_prefer_alt(alt, dry=False):
    """给热点接口加一条 metric 更小的默认路由，让它接管公网。"""
    gw = iface_gw(alt) or "0.0.0.0"
    dev = alt
    if gw == "0.0.0.0":
        # 没有网关信息时用 "dev 直连式" 默认路由
        cmd = ["ip", "route", "replace", "default", "dev", dev, "metric", str(DEFAULT_ALT_METRIC)]
    else:
        cmd = ["ip", "route", "replace", "default", "via", gw, "dev", dev, "metric", str(DEFAULT_ALT_METRIC)]
    rc, _ = run(sudo_wrap(cmd), dry=dry)
    if rc == 0:
        _save_json(state_path(), {"mode": "alt", "override": {"dev": dev, "gw": gw,
                                                             "metric": DEFAULT_ALT_METRIC}})
    return rc == 0


def restore_campus(dry=False):
    """删掉我们加的那条默认路由，恢复由系统/ NetworkManager 决定。"""
    st = _load_json(state_path()) or {}
    ov = st.get("override")
    if ov:
        dev, gw, metric = ov.get("dev"), ov.get("gw"), int(ov.get("metric", DEFAULT_ALT_METRIC))
        if gw and gw != "0.0.0.0":
            cmd = ["ip", "route", "del", "default", "via", gw, "dev", dev, "metric", str(metric)]
        else:
            cmd = ["ip", "route", "del", "default", "dev", dev, "metric", str(metric)]
        run(sudo_wrap(cmd), dry=dry)
    _save_json(state_path(), {"mode": "campus", "override": None})
    return True


def do_round(dry=False, quiet=False, want_campus_login=True, cfg=None):
    """探测一轮，必要时切换；返回 dict"""
    ifaces = list_interfaces()
    wired = [i for i in ifaces if i["kind"] == "wired"]
    alts = [i for i in ifaces if i["kind"] == "alt"]

    # 有线（可能多条，取有 IP 那条）
    wired_up = [i["name"] for i in wired if i["up"]]
    wired_on = [n for n in wired_up if probe_dev(n)]

    # 有线在线但出不了网 -> 先试校园网认证，再重新判定
    if wired_up and not wired_on and want_campus_login and not dry:
        if cfg is None:
            cfg = read_config()
        if cfg and cfg.get("account") and cfg.get("auto_login", True):
            log("  有线在线但出不了网 -> 尝试校园网认证", quiet)
            campus_login_rate_limited(cfg, wired_up[0], wait_for_ip=0, quiet=quiet)
            wired_on = [n for n in wired_up if probe_dev(n)]

    alt_up = [i["name"] for i in alts if i["up"]]
    alt_on = [n for n in alt_up if probe_dev(n)]

    want = "alt" if (alt_on and not wired_on) else "campus"
    cur = (_load_json(state_path()) or {}).get("mode")
    desc = "有线Up=%s 有线通=%s 热点Up=%s 热点通=%s => 选择 %s (上次 %s)" % (
        wired_up, wired_on, alt_up, alt_on, want, cur)

    if want == cur:
        log("无变化 | " + desc, quiet)
    elif want == "alt":
        log("切到热点优先 | " + desc, quiet)
        set_prefer_alt(alt_on[0], dry=dry)
    else:
        log("恢复有线优先 | " + desc, quiet)
        restore_campus(dry=dry)
    return {"want": want, "wired_online": bool(wired_on), "alt_online": bool(alt_on),
            "wired_up": wired_up, "alt_up": alt_up}


# ---------------------------------------------------------------- 命令

def cmd_status(args):
    ifaces = list_interfaces()
    routes = default_routes()
    print("")
    print("===== net-switch (Linux) 状态 =====")
    print("%-12s %-6s %-16s %-8s" % ("接口", "链路", "IPv4", "能出网"))
    for i in ifaces:
        online = "-"
        if i["up"]:
            online = "是" if probe_dev(i["name"]) else "否"
        print("%-12s %-6s %-16s %-8s" % (i["name"], "UP" if i["up"] else "DOWN", i["ip"] or "-", online))
    print("\n默认路由（metric 小的优先）:")
    for r in routes:
        print("  dev=%-10s via=%-16s metric=%s" % (r["dev"], r["gw"] or "-", r["metric"]))
    best = best_route_dev()
    print("  系统当前会把公网流量交给: %s" % (best or "(无默认路由)"))
    st = _load_json(state_path()) or {}
    if st.get("override"):
        print("  本工具加的覆盖路由: %s" % json.dumps(st["override"], ensure_ascii=False))
    cfg = read_config()
    print("\n校园网配置: %s" % (config_path()))
    if cfg and cfg.get("account"):
        print("  账号 %s%s（%s）  密码 %s  服务器 %s" % (
            cfg["account"], OP_SUFFIX.get(cfg["operator"], ""), OP_NAME.get(cfg["operator"], "?"),
            "已保存" if cfg["password_saved"] else "未保存", cfg["portal"]))
        print("  自动登录: %s" % ("开" if cfg.get("auto_login", True) else "关"))
    else:
        print("  未配置（运行 net-switch-linux.py gui 填账号密码）")
    cs = _load_json(campus_state_path()) or {}
    if cs.get("last_attempt"):
        print("  上次认证: %s  %s  %s" % (cs.get("last_attempt"), cs.get("last_result"), cs.get("last_msg")))
    print("")
    return 0


def cmd_auto(args):
    do_round(dry=args.dry_run, quiet=args.quiet)
    return 0


def cmd_login(args):
    cfg = read_config()
    if not cfg or not cfg.get("account"):
        log("未配置校园网账号，跳过自动登录。", args.quiet)
        return 3
    if not cfg.get("auto_login", True) and not args.force:
        log("自动登录已在设置里关闭，跳过。", args.quiet)
        return 0
    wired = next((i["name"] for i in list_interfaces() if i["kind"] == "wired" and i["up"]), None)
    if not wired:
        log("没有可用的有线接口，跳过校园网认证。", args.quiet)
        return 4
    if not args.force and probe_dev(wired):
        log("校园网已在线，无需认证。", args.quiet)
        return 0
    ok, kind, msg = campus_login_rate_limited(cfg, wired, wait_for_ip=args.wait_for_ip,
                                              force=args.force, quiet=args.quiet, dry=args.dry_run)
    log("校园网认证结果: %s [%s] %s" % ("成功" if ok else "失败", kind, msg), args.quiet)
    return 0 if ok else 1


def cmd_settle(args):
    deadline = datetime.now() + timedelta(minutes=args.max_minutes)
    log("== 定点任务启动 == 等待条件 [%s]，最长 %d 分钟，每 %d 秒探测一次" %
        (args.until, args.max_minutes, args.interval), args.quiet)
    while True:
        is_campus = args.until == "wiredup"
        prev = do_round(dry=args.dry_run, quiet=args.quiet)
        cond = prev["wired_online"] if is_campus else (not prev["wired_online"])
        if cond:
            if not is_campus:
                # 有线真的断了：无论热点此刻在不在，先把优先级摆好
                alts = [i["name"] for i in list_interfaces() if i["kind"] == "alt" and i["up"]]
                if alts:
                    set_prefer_alt(alts[0], dry=args.dry_run)
                else:
                    log("  有线已断，但当前没有可用热点接口；等热点连上后由 auto 接管。", args.quiet)
            log("条件已满足（%s），定点任务退出。" % args.until, args.quiet)
            return 0
        if datetime.now() >= deadline:
            log("等待 %d 分钟内条件未出现，定点任务退出（保持当前设置）。" % args.max_minutes, args.quiet)
            return 0
        time.sleep(args.interval)


def cmd_watch(args):
    stop = datetime.now().replace(hour=7, minute=45, second=0, microsecond=0)
    if stop <= datetime.now():
        stop += timedelta(days=1)
    hard = datetime.now() + timedelta(hours=args.max_hours)
    log("== 守护启动 == 每 %d 秒一轮；%s 之后且有线恢复即退出，最晚 %s" %
        (args.interval, stop.strftime("%m-%d %H:%M"), hard.strftime("%m-%d %H:%M")), args.quiet)
    while True:
        r = do_round(dry=args.dry_run, quiet=args.quiet)
        t = datetime.now()
        if t >= hard:
            log("到达最长运行时间 %d 小时，守护退出。" % args.max_hours, args.quiet)
            return 0
        if t >= stop and r["wired_online"]:
            log("已过 %s 且有线已恢复上网，守护退出。" % stop.strftime("%H:%M"), args.quiet)
            return 0
        time.sleep(args.interval)


def cmd_forget(args):
    for p in (config_path(), campus_state_path(), state_path()):
        try:
            if os.path.exists(p):
                os.remove(p)
                log("已删除 " + p, args.quiet)
        except Exception as e:
            log("删除 %s 失败: %s" % (p, e), args.quiet)
    return 0


# ---------------------------------------------------------------- systemd

UNIT_DIR = "/etc/systemd/system"
PY = sys.executable or "/usr/bin/python3"
SELF = os.path.abspath(__file__)
CFG = config_path()


def _unit_service(desc, exec_args):
    return """[Unit]
Description={desc}
After=network.target NetworkManager.service

[Service]
Type=oneshot
ExecStart={py} {self} {args} --quiet
""".format(desc=desc, py=PY, self=SELF, args=exec_args)


def _unit_timer(desc, on_calendar):
    return """[Unit]
Description={desc}

[Timer]
OnCalendar={cal}
Persistent=true
AccuracySec=30s

[Install]
WantedBy=timers.target
""".format(desc=desc, cal=on_calendar)


def cmd_install(args):
    units = {
        "net-switch-campus.service": _unit_service(
            "校园网认证：开机后立刻认证一次（脚本内部会等网卡拿到 IP）",
            "login --wait-for-ip 40 --config %s" % CFG) + "\n[Install]\nWantedBy=multi-user.target\n",
        "net-switch-night.service": _unit_service(
            "夜间断网：等到有线真的断了就切到热点（定点运行几分钟即退出）",
            "settle --until wireddown --max-minutes 20 --config %s" % CFG),
        "net-switch-night.timer": _unit_timer("每天 23:30 触发夜间切换", "*-*-* 23:30:00"),
        "net-switch-morning.service": _unit_service(
            "早上恢复：等到有线恢复就切回有线优先（定点运行几分钟即退出）",
            "settle --until wiredup --max-minutes 45 --config %s" % CFG),
        "net-switch-morning.timer": _unit_timer("每天 07:00 触发恢复切换", "*-*-* 07:00:00"),
    }
    if args.dry_run:
        for name, body in units.items():
            log("=== [dry-run] %s/%s ===" % (UNIT_DIR, name), args.quiet)
            for line in body.splitlines():
                print("    " + line)
        log("[dry-run] systemctl daemon-reload && systemctl enable --now net-switch-night.timer net-switch-morning.timer net-switch-campus.service", args.quiet)
        return 0
    for name, body in units.items():
        log("写入 %s/%s" % (UNIT_DIR, name), args.quiet)
        p = subprocess.run(sudo_wrap(["tee", os.path.join(UNIT_DIR, name)]), input=body.encode(),
                           capture_output=True)
        if p.returncode != 0:
            log("  ! 写入失败，检查 sudo 是否可用（需要 root 才能改路由与装服务）", args.quiet)
            return 1
    run(sudo_wrap(["systemctl", "daemon-reload"]))
    run(sudo_wrap(["systemctl", "enable", "--now", "net-switch-night.timer",
                   "net-switch-morning.timer", "net-switch-campus.service"]))
    log("安装完成。查看状态： systemctl list-timers 'net-switch*'", args.quiet)
    return 0


def cmd_uninstall(args):
    run(sudo_wrap(["systemctl", "disable", "--now", "net-switch-night.timer",
                   "net-switch-morning.timer", "net-switch-campus.service"]))
    for name in ("net-switch-campus.service", "net-switch-night.service", "net-switch-night.timer",
                 "net-switch-morning.service", "net-switch-morning.timer"):
        run(sudo_wrap(["rm", "-f", os.path.join(UNIT_DIR, name)]))
    run(sudo_wrap(["systemctl", "daemon-reload"]))
    restore_campus(dry=args.dry_run)
    log("已卸载 systemd 单元并恢复默认路由。", args.quiet)
    return 0


# ---------------------------------------------------------------- GUI

def cmd_gui(args):
    try:
        import tkinter as tk
        from tkinter import ttk, messagebox
    except ImportError:
        print("需要 tkinter：Debian/Ubuntu/Raspberry Pi OS 上装 python3-tk（sudo apt install python3-tk）")
        return 5
    cfg = read_config() or {}
    root = tk.Tk()
    root.title("校园网自动登录 (Linux)")
    root.resizable(False, False)
    frm = ttk.Frame(root, padding=14)
    frm.grid()

    v_acct = tk.StringVar(value=cfg.get("account", ""))
    v_ops = tk.StringVar()
    v_pwd = tk.StringVar()
    v_url = tk.StringVar(value=cfg.get("portal", "http://10.2.5.251:801/eportal/"))
    v_auto = tk.BooleanVar(value=cfg.get("auto_login", True))

    ttk.Label(frm, text="账号（学号）").grid(row=0, column=0, sticky="w", pady=4)
    ttk.Entry(frm, textvariable=v_acct, width=22).grid(row=0, column=1, sticky="w")
    ttk.Label(frm, textvariable=tk.StringVar(value=OP_SUFFIX.get(cfg.get("operator", "campus"), ""))) \
        .grid(row=0, column=2, sticky="w")
    ttk.Label(frm, text="运营商").grid(row=1, column=0, sticky="w", pady=4)
    ops = ["中国移动", "中国联通", "中国电信", "校园网（无后缀）"]
    keys = ["cmcc", "unicom", "telecom", "campus"]
    cb = ttk.Combobox(frm, values=ops, state="readonly", width=19)
    cb.current(keys.index(cfg.get("operator", "campus")) if cfg.get("operator") in keys else 3)
    cb.grid(row=1, column=1, sticky="w")
    ttk.Label(frm, text="密码").grid(row=2, column=0, sticky="w", pady=4)
    ttk.Entry(frm, textvariable=v_pwd, show="●", width=22).grid(row=2, column=1, sticky="w")
    ttk.Label(frm, text="认证服务器").grid(row=3, column=0, sticky="w", pady=4)
    ttk.Entry(frm, textvariable=v_url, width=34).grid(row=3, column=1, columnspan=2, sticky="w")
    ttk.Checkbutton(frm, text="保存后自动在后台登录（开机 / 网络变化 / 每天 07:00）",
                    variable=v_auto).grid(row=4, column=0, columnspan=3, sticky="w", pady=6)
    status = ttk.Label(frm, text=("已保存配置；密码留空 = 不修改" if cfg.get("password_saved") else "还没有保存配置"),
                       foreground=("gray" if cfg.get("password_saved") else "darkorange"))
    status.grid(row=5, column=0, columnspan=3, sticky="w", pady=(2, 8))

    def do_save(test):
        acct = v_acct.get().strip()
        if not acct:
            status.config(text="账号不能为空", foreground="red")
            return
        save_config(acct, keys[cb.current()], v_pwd.get(), v_url.get().strip(), v_auto.get())
        v_pwd.set("")
        status.config(text="已保存（%s，权限 600）" % config_path(), foreground="gray")
        if test:
            c = read_config()
            wired = next((i["name"] for i in list_interfaces() if i["kind"] == "wired" and i["up"]), None)
            if not wired:
                status.config(text="现在没有可用有线接口，插上网线再测试", foreground="firebrick")
                return
            ok, kind, msg = campus_login(c, wired, force=True)
            status.config(text=msg, foreground=("darkgreen" if ok else "firebrick"))

    btns = ttk.Frame(frm)
    btns.grid(row=6, column=0, columnspan=3, sticky="e", pady=(4, 0))
    ttk.Button(btns, text="保存并测试登录", command=lambda: do_save(True)).pack(side="left", padx=4)
    ttk.Button(btns, text="仅保存", command=lambda: do_save(False)).pack(side="left", padx=4)
    ttk.Button(btns, text="关闭", command=root.destroy).pack(side="left", padx=4)
    root.mainloop()
    return 0


# ---------------------------------------------------------------- CLI

def build_parser():
    # 这三个开关既要能放在子命令前，也要能放在子命令后（--dry-run auto / auto --dry-run 都得行），
    # 所以做成 parents：子命令里用 SUPPRESS 默认值，避免把顶层已解析的值盖掉。
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS,
                        help="只打印将要执行的命令/判定，不做任何修改")
    common.add_argument("--quiet", action="store_true", default=argparse.SUPPRESS,
                        help="不向标准输出打印（仍写日志文件）")
    common.add_argument("--config", default=argparse.SUPPRESS,
                        help="校园网配置文件路径（默认 ~/.config/net-switch/campus.json）")

    p = argparse.ArgumentParser(prog="net-switch-linux.py", parents=[common],
                                description="有线没出口时自动改走手机热点 + 校园网认证（Linux）")
    p.set_defaults(dry_run=False, quiet=False, config=None)
    p.add_argument("--version", action="version", version="net-switch (Linux) " + VERSION)
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("status", help="只读：显示接口 / 出口 / 默认路由 / 配置")
    sub.add_parser("auto", parents=[common], help="单次判断 + 切换 + 兜底认证")
    sp = sub.add_parser("login", parents=[common], help="只做校园网认证")
    sp.add_argument("--wait-for-ip", type=int, default=0, help="网卡还没 IP 时最多等多少秒")
    sp.add_argument("--force", action="store_true", help="忽略已在线/频率限制，强制认证一次")
    sp = sub.add_parser("settle", parents=[common], help="定点任务：等到条件出现就跑完退出")
    sp.add_argument("--until", choices=["wiredup", "wireddown"], required=True)
    sp.add_argument("--max-minutes", type=int, default=20)
    sp.add_argument("--interval", type=int, default=60)
    sp = sub.add_parser("watch", parents=[common], help="（备选）常驻守护")
    sp.add_argument("--interval", type=int, default=60)
    sp.add_argument("--max-hours", type=int, default=10)
    sub.add_parser("gui", parents=[common], help="图形设置界面（tkinter）")
    sub.add_parser("install", parents=[common], help="安装 systemd 单元与定时器（需要 sudo）")
    sub.add_parser("uninstall", parents=[common], help="卸载 systemd 单元（需要 sudo）")
    sub.add_parser("forget", parents=[common], help="删除保存的凭据与状态")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    global CFG
    if getattr(args, "config", None):
        # --config 只影响校园网凭据文件；日志/状态仍按默认位置
        global config_path
        config_path = lambda: args.config      # noqa: E731
        CFG = args.config
    handlers = {"status": cmd_status, "auto": cmd_auto, "login": cmd_login, "settle": cmd_settle,
                "watch": cmd_watch, "gui": cmd_gui, "install": cmd_install, "uninstall": cmd_uninstall,
                "forget": cmd_forget}
    if not args.cmd:
        build_parser().print_help()
        return 0
    return handlers[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
