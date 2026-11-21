#!/usr/bin/python3 -B
"""Commandes factices du labo de captures (une seule implémentation, appelée par des liens du faux bin).

Dispatch sur le nom d'appel (uptime, df, free, uname, hostname, whoami, id, groups, systemctl, docker,
journalctl, who, w, ls, sudo, nginx, lsb_release) ou sur argv[1] (motd, procd <dossier>).
Environnement : LABMETA (meta.json de l'hôte), LABROOT (racine réelle fictive). Sorties cohérentes entre
elles (uptime/free/df/proc partagent le même meta) et ne montrent que des chemins virtuels.
"""
import hashlib
import json
import math
import os
import random
import shutil
import stat
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import fakefs  # noqa: E402

META = json.load(open(os.environ["LABMETA"]))
ROOT = os.path.realpath(os.environ.get("LABROOT", "/"))
NAME, IP, ROLE = META["name"], META["ip"], META["role"]
NOW = time.time()
BOOT = META["boot"]
UP = NOW - BOOT
TTY = sys.stdout.isatty()
SEED = int(NOW // 60)


def rng(salt=""):
    return random.Random("%s|%s|%d" % (NAME, salt, SEED))


def human_kb(kb, style="df"):
    """Taille lisible façon df -h / ls -h (arrondi au supérieur, une décimale sous 10)."""
    units = ["K", "M", "G", "T"]
    v, i = float(kb), 0
    while v >= 1024 and i < 3:
        v /= 1024
        i += 1
    if v < 10 and (i > 0 or style == "ls"):
        return "%.1f%s" % (math.ceil(v * 10) / 10, units[i])
    return "%d%s" % (math.ceil(v), units[i])


def loadavg():
    r = rng("load")
    b = META["load"]
    return [max(0.0, b * f + r.uniform(-0.04, 0.05)) for f in (1.0, 0.92, 0.85)]


def uptime_head():
    s = int(UP)
    d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    l1, l5, l15 = loadavg()
    return " %s up %d days, %2d:%02d,  1 user,  load average: %.2f, %.2f, %.2f" % (
        time.strftime("%H:%M:%S", time.localtime(NOW)), d, h, m, l1, l5, l15)


def uptime_main(args):
    if args and args[0] in ("-p", "--pretty"):
        s = int(UP)
        d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
        parts = []
        if d >= 7:
            parts.append("%d week%s" % (d // 7, "s" if d // 7 > 1 else ""))
            d %= 7
        if d:
            parts.append("%d day%s" % (d, "s" if d > 1 else ""))
        parts.append("%d hour%s" % (h, "s" if h != 1 else ""))
        parts.append("%d minute%s" % (m, "s" if m != 1 else ""))
        print("up " + ", ".join(parts))
    elif args and args[0] in ("-s", "--since"):
        print(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(BOOT)))
    else:
        print(uptime_head())


def mounts():
    total = int(META["disk_gb"] * 1024 * 1024)
    used = int(total * META["disk_used_pct"] / 100)
    mem = META["mem_kb"]
    m = [("tmpfs", mem // 10, 1228, "/run"),
         ("/dev/sda1", total, used, "/"),
         ("tmpfs", mem // 2, 0, "/dev/shm"),
         ("tmpfs", 5120, 0, "/run/lock"),
         ("/dev/sda15", 258000, 6240, "/boot/efi"),
         ("tmpfs", mem // 10, 12, "/run/user/1000")]
    if ROLE == "db":
        m.insert(2, ("/dev/sdb1", 1048576 * 200, int(1048576 * 200 * 0.47), "/var/lib/postgresql"))
    return m


def cwd_virtual():
    try:
        return fakefs.to_virtual(ROOT, os.getcwd())
    except OSError:
        return fakefs.HOME


def df_main(args):
    flags = "".join(a[1:] for a in args if a.startswith("-") and not a.startswith("--"))
    human = "h" in flags or "--human-readable" in args
    posix = "P" in flags
    paths = [a for a in args if not a.startswith("-")]
    rows = mounts()
    if paths:
        sel = []
        for p in paths:
            v = fakefs.vnorm(p, cwd_virtual())
            best = max((r for r in rows if r[3] == "/" or v == r[3] or v.startswith(r[3] + "/")), key=lambda r: len(r[3]))
            if best not in sel:
                sel.append(best)
        rows = sel
    if human:
        hdr = ("Filesystem", "Size", "Used", "Avail", "Use%", "Mounted on")
    elif posix:
        hdr = ("Filesystem", "1024-blocks", "Used", "Available", "Capacity", "Mounted on")
    else:
        hdr = ("Filesystem", "1K-blocks", "Used", "Available", "Use%", "Mounted on")
    out: list = [hdr]
    for fs, tot, used, mp in rows:
        avail = tot - used
        pct = math.ceil(used * 100 / tot) if tot else 0
        if human:
            out.append((fs, human_kb(tot), human_kb(used) if used else "0", human_kb(avail), "%d%%" % pct, mp))
        else:
            out.append((fs, str(tot), str(used), str(avail), "%d%%" % pct, mp))
    w = [max(len(r[i]) for r in out) for i in range(5)]
    for r in out:
        print("%-*s %*s %*s %*s %*s %s" % (w[0], r[0], w[1], r[1], w[2], r[2], w[3], r[3], w[4], r[4], r[5]))


def mem_numbers():
    tot = META["mem_kb"]
    used = int(tot * (META["mem_used_pct"] + rng("mem").uniform(-1.5, 1.5)) / 100)
    cache = int(tot * 0.27)
    return tot, used, max(0, tot - used - cache), cache, tot - used


def free_main(args):
    f = "".join(a.lstrip("-") for a in args if a.startswith("-") and not a.startswith("--"))
    tot, used, free, cache, avail = mem_numbers()
    swap = 2 * 1024 * 1024 if ROLE != "db" else 4 * 1024 * 1024

    def fmt(kb):
        if "h" in f:
            if kb == 0:
                return "0B"
            v, units, i = kb * 1024.0, ["B", "Ki", "Mi", "Gi", "Ti"], 0
            while v >= 1024 and i < 4:
                v /= 1024
                i += 1
            return "%.1f%s" % (v, units[i])
        if "m" in f:
            return str(kb // 1024)
        if "g" in f:
            return str(kb // 1048576)
        if "b" in f:
            return str(kb * 1024)
        return str(kb)
    print("%8s%12s%12s%12s%12s%12s%12s" % ("", "total", "used", "free", "shared", "buff/cache", "available"))
    print("%-8s%12s%12s%12s%12s%12s%12s" % ("Mem:", fmt(tot), fmt(used), fmt(free), fmt(1160), fmt(cache), fmt(avail)))
    print("%-8s%12s%12s%12s" % ("Swap:", fmt(swap), fmt(0), fmt(swap)))


def uname_main(args):
    full = {"s": "Linux", "n": NAME, "r": META["kernel"], "v": "#48-Ubuntu SMP PREEMPT_DYNAMIC Fri Sep 27 14:04:52 UTC 2024",
            "m": "x86_64", "p": "x86_64", "i": "x86_64", "o": "GNU/Linux"}
    if not args:
        print("Linux")
        return
    letters = ""
    for a in args:
        if a == "--all":
            letters += "a"
        elif a.startswith("-") and not a.startswith("--"):
            letters += a[1:]
    if "a" in letters:
        letters = "snrvmpio"
    print(" ".join(full[c] for c in "snrvmpio" if c in letters))


def hostname_main(args):
    if "-f" in args or "--fqdn" in args:
        print(NAME + ".internal")
    elif "-I" in args or "--all-ip-addresses" in args:
        print(IP + " ")
    elif "-i" in args:
        print(IP)
    elif "-d" in args:
        print("internal")
    else:
        print(NAME)


# --- systemctl ----------------------------------------------------------------------------------
UNITS = {
    "nginx": ("nginx.service", "A high performance web server and a reverse proxy server", "/usr/lib/systemd/system/nginx.service", 815,
              [(815, "nginx: master process /usr/sbin/nginx -g daemon on; master_process on;"), (816, "nginx: worker process"),
               (817, "nginx: worker process")], "8.4M", "11.2M", "1min 12.318s", "man:nginx(8)"),
    "ssh": ("ssh.service", "OpenBSD Secure Shell server", "/usr/lib/systemd/system/ssh.service", 742,
            [(742, "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups")], "5.6M", "9.8M", "2.114s", "man:sshd(8)"),
    "docker": ("docker.service", "Docker Application Container Engine", "/usr/lib/systemd/system/docker.service", 1011,
               [(1011, "/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock")], "142.7M", "310.4M", "9min 41.027s", "man:dockerd(8)"),
    "postgresql": ("postgresql@16-main.service", "PostgreSQL Cluster 16-main", "/usr/lib/systemd/system/postgresql@.service", 1180,
                   [(1180, "/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main")], "1.2G", "1.6G", "4h 18min 6.331s", "man:postgres(1)"),
}


def systemctl_main(args):
    rest = [a for a in args if not a.startswith("-")]
    if not rest:
        return
    verb, units = rest[0], [u.replace(".service", "") for u in rest[1:]]
    avail = {"web": ("nginx", "ssh", "docker"), "db": ("postgresql", "ssh"), "bastion": ("ssh",)}[ROLE]
    if verb in ("restart", "reload", "start", "stop", "enable", "disable", "daemon-reload"):
        return
    if verb == "is-active":
        ok = bool(units) and units[0] in avail
        print("active" if ok else "inactive")
        sys.exit(0 if ok else 3)
    if verb != "status":
        print("Unknown command verb '%s'." % verb, file=sys.stderr)
        sys.exit(1)
    if not units:
        print("● %s\n    State: running\n    Units: 284 loaded (incl. loaded aliases)" % NAME)
        return
    u = units[0]
    if u not in avail:
        print("Unit %s.service could not be found." % u, file=sys.stderr)
        sys.exit(4)
    unit, desc, path, pid, procs, mem, peak, cpu, docs = UNITS[u]
    since = BOOT + 14
    ago = int(NOW - since)
    d = ago // 86400
    rel = "%d days ago" % d if d < 31 else "%d month%s %d days ago" % (d // 30, "s" if d // 30 > 1 else "", d % 30)
    on, off = ("\033[0;1;32m", "\033[0m") if TTY else ("", "")
    print("%s●%s %s - %s" % (on, off, unit, desc))
    print("     Loaded: loaded (%s; enabled; preset: enabled)" % path)
    print("     Active: %sactive (running)%s since %s UTC; %s" % (on, off, time.strftime("%a %Y-%m-%d %H:%M:%S", time.gmtime(since)), rel))
    print("       Docs: %s" % docs)
    print("   Main PID: %d (%s)" % (pid, procs[0][1].split(":")[0].split()[0].split("/")[-1]))
    print("      Tasks: %d (limit: 9254)" % len(procs))
    print("     Memory: %s (peak: %s)" % (mem, peak))
    print("        CPU: %s" % cpu)
    print("     CGroup: /system.slice/%s" % unit)
    for i, (p, c) in enumerate(procs):
        print("             %s%d %s" % ("└─" if i == len(procs) - 1 else "├─", p, '"%s"' % c if c.startswith("nginx") else c))
    print()
    t0 = time.strftime("%b %d %H:%M:%S", time.gmtime(since))
    print("%s %s systemd[1]: Starting %s - %s..." % (t0, NAME, unit, desc))
    print("%s %s systemd[1]: Started %s - %s." % (t0, NAME, unit, desc))


# --- docker --------------------------------------------------------------------------------------
def cid(n):
    return hashlib.md5((NAME + n).encode()).hexdigest()[:12]


def table(rows):
    w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    for r in rows:
        print("   ".join(r[i].ljust(w[i]) for i in range(len(r))).rstrip())


def docker_main(args):
    rest = [a for a in args if not a.startswith("-")]
    allflag = any(a in ("-a", "--all") for a in args)
    if not rest:
        print("Usage:  docker [OPTIONS] COMMAND")
    elif rest[0] == "ps" or rest[:2] == ["container", "ls"]:
        rows = [("CONTAINER ID", "IMAGE", "COMMAND", "CREATED", "STATUS", "PORTS", "NAMES"),
                (cid("web"), "shop/web:2026.11.3", '"uvicorn src.main:ap…"', "2 days ago", "Up 2 days (healthy)", "0.0.0.0:8080->8080/tcp", "app-web-1"),
                (cid("worker"), "shop/worker:2026.11.3", '"python -m src.work…"', "2 days ago", "Up 2 days", "", "app-worker-1"),
                (cid("cache"), "redis:7-alpine", '"docker-entrypoint.s…"', "5 weeks ago", "Up 5 weeks", "6379/tcp", "app-cache-1")]
        if allflag:
            rows.append((cid("mig"), "shop/web:2026.11.2", '"alembic upgrade he…"', "9 days ago", "Exited (0) 9 days ago", "", "app-migrate-run-4c1"))
        table(rows)
    elif rest[0] == "images":
        table([("REPOSITORY", "TAG", "IMAGE ID", "CREATED", "SIZE"),
               ("registry.internal/shop/web", "2026.11.3", cid("iw"), "2 days ago", "412MB"),
               ("registry.internal/shop/worker", "2026.11.3", cid("iwk"), "2 days ago", "398MB"),
               ("registry.internal/shop/web", "2026.11.2", cid("iw2"), "9 days ago", "411MB"),
               ("redis", "7-alpine", cid("ir"), "5 weeks ago", "41.4MB")])
    else:
        print("Error response from daemon: unsupported in this environment", file=sys.stderr)
        sys.exit(1)


# --- journalctl ----------------------------------------------------------------------------------
def journal_lines(n):
    r = random.Random(NAME + "j")
    b64 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    sources = [("sshd", lambda: "Accepted publickey for deploy from %s port %d ssh2: ED25519 SHA256:%s" % (
        r.choice(["203.0.113.7", "198.51.100.23", "192.0.2.88"]), r.randint(40000, 60000), "".join(r.choice(b64) for _ in range(43)))),
        ("systemd", lambda: "Started session-%d.scope - Session %d of User deploy." % (r.randint(100, 900), r.randint(100, 900))),
        ("CRON", lambda: "(root) CMD (command -v debian-sa1 > /dev/null && debian-sa1 1 1)"),
        ("systemd-logind", lambda: "New session %d of user deploy." % r.randint(100, 900)),
        ("systemd", lambda: "logrotate.service: Deactivated successfully.")]
    if ROLE == "web":
        sources.append(("nginx", lambda: "2026/11/15 signal process started"))
        # Journal applicatif (journalctl -u app) : niveaux variés, pour la coloration de la sortie.
        app_msgs = [lambda: "INFO GET /api/orders 200 %dms" % r.randint(8, 60),
                    lambda: "INFO POST /api/cart 201 %dms" % r.randint(15, 90),
                    lambda: "INFO healthcheck ok",
                    lambda: "WARNING slow query on orders (%.1fs)" % r.uniform(1.2, 2.9),
                    lambda: "ERROR payment webhook timeout, retry %d/3" % r.randint(1, 2),
                    lambda: "INFO payment webhook delivered successfully",
                    lambda: "INFO cache warmup done in %dms" % r.randint(200, 900)]
        for _ in range(4):
            sources.append(("app", lambda: r.choice(app_msgs)()))
    if ROLE == "db":
        sources.append(("postgres", lambda: "checkpoint complete: wrote %d buffers" % r.randint(100, 4000)))
    out, t = [], NOW - 20
    for _ in range(n):
        src, fn = r.choice(sources)
        out.append("%s %s %s[%d]: %s" % (time.strftime("%b %d %H:%M:%S", time.gmtime(t)), NAME, src, r.randint(400, 9000), fn()))
        t -= r.uniform(40, 700)
    return list(reversed(out))


def journalctl_main(args):
    n = 10
    for i, a in enumerate(args):
        if a == "-n" and i + 1 < len(args):
            n = int(args[i + 1])
        elif a.startswith("-n") and a[2:].isdigit():
            n = int(a[2:])
    lines = journal_lines(n)
    for u in [args[i + 1] for i, a in enumerate(args) if a == "-u" and i + 1 < len(args)]:
        sel = [ln for ln in lines if " %s[" % u.replace(".service", "") in ln]
        lines = sel or lines[:3]
    for ln in lines:
        print(ln)


def who_main(args):
    print("deploy   pts/0        %s (198.51.100.23)" % time.strftime("%Y-%m-%d %H:%M", time.localtime(NOW - 180)))


def w_main(args):
    print(uptime_head())
    print("USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT")
    print("deploy   pts/0    198.51.100.23    %s    0.00s  0.03s  0.00s w" % time.strftime("%H:%M", time.localtime(NOW - 180)))


# --- ls -----------------------------------------------------------------------------------------
def colorize(name, st, enable):
    if not enable:
        return name
    if stat.S_ISDIR(st.st_mode):
        return "\033[01;34m%s\033[0m" % name
    if stat.S_ISLNK(st.st_mode):
        return "\033[01;36m%s\033[0m" % name
    if st.st_mode & 0o111:
        return "\033[01;32m%s\033[0m" % name
    if name.endswith((".gz", ".tar", ".zip", ".tgz")):
        return "\033[01;31m%s\033[0m" % name
    return name


def ls_main(args):
    flags, paths, color, end = set(), [], TTY, False
    for a in args:
        if end or not a.startswith("-") or a == "-":
            paths.append(a)
        elif a == "--":
            end = True
        elif a.startswith("--color"):
            mode = a.split("=")[1] if "=" in a else "always"
            color = (mode == "always") or (TTY and mode in ("auto", "tty", "if-tty"))
        elif a == "--human-readable":
            flags.add("h")
        elif a == "--all":
            flags.add("a")
        elif a.startswith("--"):
            pass
        else:
            flags.update(a[1:])
    long = "l" in flags
    cwd = cwd_virtual()
    status = 0
    targets = paths or ["."]
    shown_files, dirs = [], []
    for t in targets:
        try:
            real = fakefs.real_of(ROOT, t, follow=True, cwd=cwd)
            st = os.lstat(real)
        except (OSError, PermissionError):
            print("ls: cannot access '%s': No such file or directory" % t, file=sys.stderr)
            status = 2
            continue
        v = fakefs.vnorm(t, cwd)
        if stat.S_ISDIR(st.st_mode) and "d" not in flags:
            dirs.append((t, v, real))
        else:
            shown_files.append((t, v, real))

    def entries_of(items):
        out = []
        for name, v, real in items:
            try:
                st = os.lstat(real)
            except OSError:
                continue
            out.append((name, v, st, 4096 if stat.S_ISDIR(st.st_mode) else st.st_size))
        return out

    def render(ents):
        if "t" in flags:
            ents.sort(key=lambda e: -e[2].st_mtime)
        elif "S" in flags:
            ents.sort(key=lambda e: -e[3])
        else:
            ents.sort(key=lambda e: e[0].encode())
        if "r" in flags:
            ents.reverse()
        suffix = {}
        if "F" in flags:
            for e in ents:
                suffix[e[0]] = "/" if stat.S_ISDIR(e[2].st_mode) else ("*" if e[2].st_mode & 0o111 else "")
        if long:
            def hs(n):
                return human_kb(n / 1024.0, "ls") if "h" in flags and n >= 1024 else str(n)
            rows = []
            for name, v, st, size in ents:
                u, g, _, _ = fakefs.owner(v)
                rows.append((stat.filemode(st.st_mode), str(st.st_nlink), u, g, hs(size), fakefs.date_str(st.st_mtime), name, st))
            w = [max([len(r[i]) for r in rows] + [0]) for i in range(5)]
            for r in rows:
                print("%s %*s %-*s %-*s %*s %s %s%s" % (r[0], w[1], r[1], w[2], r[2], w[3], r[3], w[4], r[4], r[5],
                                                       colorize(r[6], r[7], color), suffix.get(r[6], "")))
            return
        names = [colorize(e[0], e[2], color) + suffix.get(e[0], "") for e in ents]
        plain = [e[0] + suffix.get(e[0], "") for e in ents]
        n = len(plain)
        if not n:
            return
        if not TTY or "1" in flags:
            for x in names:
                print(x)
            return
        width = shutil.get_terminal_size((80, 24)).columns
        cols = n
        while cols > 1:
            rn = math.ceil(n / cols)
            ws = [max(len(plain[i]) for i in range(c * rn, min(n, (c + 1) * rn))) + 2 for c in range(math.ceil(n / rn))]
            if sum(ws) - 2 <= width:
                break
            cols -= 1
        rn = math.ceil(n / cols)
        nc = math.ceil(n / rn)
        ws = [max(len(plain[i]) for i in range(c * rn, min(n, (c + 1) * rn))) + 2 for c in range(nc)]
        for r in range(rn):
            line = ""
            for c in range(nc):
                i = c * rn + r
                if i < n:
                    line += names[i] + " " * (ws[c] - len(plain[i]))
            print(line.rstrip())

    first = True
    if shown_files:
        render(entries_of(shown_files))
        first = False
    for t, v, real in dirs:
        if len(targets) > 1:
            if not first:
                print()
            print("%s:" % t)
        first = False
        items = [(n, fakefs.vnorm(v + "/" + n), os.path.join(real, n)) for n in os.listdir(real)
                 if "a" in flags or "A" in flags or not n.startswith(".")]
        if "a" in flags:
            pv = fakefs.vnorm(v + "/..")
            items += [(".", v, real), ("..", pv, ROOT if pv == "/" else ROOT + pv)]
        ents = entries_of(items)
        if long:
            blocks = sum(((e[3] + 4095) // 4096) * 4 for e in ents)
            print("total %s" % (human_kb(blocks, "ls") if "h" in flags else blocks))
        render(ents)
    sys.exit(status)


def motd():
    tot, used, free, cache, avail = mem_numbers()
    print("Welcome to Ubuntu 24.04.1 LTS (GNU/Linux %s x86_64)\n" % META["kernel"])
    print(" System information as of %s UTC\n" % time.strftime("%a %b %e %H:%M:%S %Y", time.gmtime(NOW)))
    print("  System load:  %-19.2fProcesses:             %d" % (loadavg()[0], META["procs"]))
    print("  Usage of /:   %-19sUsers logged in:       0" % ("%.1f%% of %.2fGB" % (META["disk_used_pct"], META["disk_gb"])))
    print("  Memory usage: %-19sIPv4 address for eth0: %s" % ("%d%%" % round(used * 100 / tot), IP))
    print("  Swap usage:   0%\n")
    print("3 updates can be applied immediately.")
    print("1 of these updates is a standard security update.")
    print("To see these additional updates run: apt list --upgradable\n")
    print("Last login: %s from 198.51.100.23" % time.strftime("%a %b %e %H:%M:%S %Y", time.gmtime(NOW - 17 * 3600 - 1234)))


def procd(d):
    """Tient à jour un faux /proc (loadavg, stat, meminfo, net/dev, uptime) tant que le processus parent vit."""
    os.makedirs(os.path.join(d, "net"), exist_ok=True)
    ppid = os.getppid()
    r = random.Random()
    cpus = META["cpus"]
    base = min(0.6, META["load"] / cpus + 0.05)
    idle, busy = int(UP * 100 * cpus * (1 - base)), int(UP * 100 * cpus * base)
    rx, tx = int(UP * 9000), int(UP * 21000)
    last, frac, tot_kb = time.time(), base, META["mem_kb"]
    used_f = META["mem_used_pct"] / 100.0

    def w(name, text):
        p = os.path.join(d, name)
        with open(p + ".tmp", "w") as f:
            f.write(text)
        os.replace(p + ".tmp", p)

    while os.getppid() == ppid:
        now = time.time()
        dt, last = now - last, now
        frac = min(0.9, max(0.02, frac + r.uniform(-0.04, 0.04) + (base - frac) * 0.1))
        busy += int(dt * 100 * cpus * frac)
        idle += int(dt * 100 * cpus * (1 - frac))
        rx += int(dt * r.uniform(60000, 520000))
        tx += int(dt * r.uniform(150000, 1100000))
        used_f = min(0.95, max(0.05, used_f + r.uniform(-0.002, 0.002)))
        ld = max(0.01, META["load"] + (frac - base) * cpus)
        w("loadavg", "%.2f %.2f %.2f 2/%d 48211\n" % (ld, ld * 0.93, ld * 0.88, META["procs"]))
        w("stat", "cpu  %d 0 %d %d 120 0 40 0 0 0\n" % (busy * 7 // 10, busy * 3 // 10, idle))
        avail = int(tot_kb * (1 - used_f))
        w("meminfo", "MemTotal:       %d kB\nMemFree:        %d kB\nMemAvailable:   %d kB\nBuffers:        %d kB\nCached:         %d kB\n" % (
            tot_kb, int(avail * 0.4), avail, int(tot_kb * 0.03), int(tot_kb * 0.24)))
        w("net/dev", "Inter-|   Receive                                                |  Transmit\n"
          " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
          "    lo: 8123456   41200    0    0    0     0          0         0  8123456   41200    0    0    0     0       0          0\n"
          "  eth0: %d %d    0    0    0     0          0         0 %d %d    0    0    0     0       0          0\n" % (rx, rx // 900, tx, tx // 1100))
        w("uptime", "%.2f %.2f\n" % (now - BOOT, (now - BOOT) * cpus * (1 - base)))
        time.sleep(0.5)


def sudo_main(args):
    # Jamais d'exec réel : la commande visée passe par les commandes factices (une trace Python révélerait la machine).
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 1
    rest = args[i:]
    if not rest:
        print("usage: sudo -h | -K | -k | -V", file=sys.stderr)
        sys.exit(1)
    run_cmd(os.path.basename(rest[0]), rest[1:])


def nginx_main(args):
    if "-t" in args:
        print("nginx: the configuration file /etc/nginx/nginx.conf syntax is ok", file=sys.stderr)
        print("nginx: configuration file /etc/nginx/nginx.conf test is successful", file=sys.stderr)
    elif "-v" in args:
        print("nginx version: nginx/1.24.0 (Ubuntu)", file=sys.stderr)


def lsb_main(args):
    if "-d" in args:
        print("Description:\tUbuntu 24.04.1 LTS")
    else:
        print("No LSB modules are available.\nDistributor ID:\tUbuntu\nDescription:\tUbuntu 24.04.1 LTS\nRelease:\t24.04\nCodename:\tnoble")


def main():
    me, args = os.path.basename(sys.argv[0]), sys.argv[1:]
    if me == "fake_cmds.py":
        if args and args[0] == "motd":
            return motd()
        if args and args[0] == "procd":
            return procd(args[1])
        sys.exit(2)
    groups = "deploy sudo docker" if ROLE == "web" else "deploy sudo"
    ids = "uid=1000(deploy) gid=1000(deploy) groups=1000(deploy),27(sudo)" + (",988(docker)" if ROLE == "web" else "")
    handlers = {
        "uptime": uptime_main, "df": df_main, "free": free_main, "uname": uname_main, "hostname": hostname_main,
        "whoami": lambda a: print("deploy"), "id": lambda a: print(ids), "groups": lambda a: print(groups),
        "systemctl": systemctl_main, "docker": docker_main, "journalctl": journalctl_main, "who": who_main, "w": w_main,
        "ls": ls_main, "sudo": sudo_main, "nginx": nginx_main, "lsb_release": lsb_main,
    }
    HANDLERS.update(handlers)
    run_cmd(me, args)


HANDLERS = {}


def run_cmd(me, args):
    fn = HANDLERS.get(me)
    if fn is None:
        print("%s: command not found" % me, file=sys.stderr)
        sys.exit(127)
    try:
        fn(args)
        sys.stdout.flush()
    except BrokenPipeError:
        pass


if __name__ == "__main__":
    main()
