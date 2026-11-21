#!/usr/bin/python3
"""Peuple la racine fictive d'un hôte du labo et écrit son meta.json.

Usage : seed_fs.py <dossier hôte> <nom> <ip> <rôle: web|db|bastion>
Tout est déterministe (graine = nom) et fictif : IP en plages de documentation, noms en .internal,
aucun secret plausible. Les dates sont ramenées à nov. 2026 (relatives à « maintenant »).
"""
import gzip
import json
import os
import random
import sys
import time

host_dir, NAME, IP, ROLE = sys.argv[1:5]
ROOT = os.path.join(host_dir, "root")
rnd = random.Random(NAME)
NOW = time.time()
DAY = 86400


def put(vpath, content="", mode=0o644, age_days=10.0, binary=None, sparse=None):
    """Crée un fichier fictif, daté de `age_days` jours avant maintenant."""
    p = ROOT + vpath
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if sparse is not None:
        with open(p, "wb") as f:
            f.write(binary or b"")
            f.truncate(sparse)
    else:
        with open(p, "wb") as f:
            f.write(binary if binary is not None else content.encode())
    os.chmod(p, mode)
    t = NOW - age_days * DAY
    os.utime(p, (t, t))


def mkdir(vpath, mode=0o755, age_days=30.0):
    p = ROOT + vpath
    os.makedirs(p, exist_ok=True)
    os.chmod(p, mode)
    t = NOW - age_days * DAY
    os.utime(p, (t, t))


# --- méta : cohérence entre uptime, free, df, /proc
meta = {
    "name": NAME, "ip": IP, "role": ROLE,
    "boot": int(NOW - rnd.randint(21, 96) * DAY - rnd.randint(0, 80000)),
    "cpus": {"web": 4, "db": 8, "bastion": 2}[ROLE],
    "mem_kb": {"web": 8014208, "db": 32779888, "bastion": 2005000}[ROLE],
    "mem_used_pct": {"web": 31, "db": 58, "bastion": 17}[ROLE],
    "disk_gb": {"web": 77.4, "db": 465.7, "bastion": 24.0}[ROLE],
    "disk_used_pct": {"web": 38, "db": 63, "bastion": 22}[ROLE],
    "load": {"web": 0.31, "db": 0.84, "bastion": 0.04}[ROLE],
    "procs": {"web": 148, "db": 212, "bastion": 96}[ROLE],
    "kernel": "6.8.0-48-generic",
}
json.dump(meta, open(os.path.join(host_dir, "meta.json"), "w"), indent=1)

# --- système
mkdir("/", age_days=200)
for d in ("/bin", "/boot", "/dev", "/lib", "/mnt", "/proc", "/root", "/run", "/sbin", "/sys", "/etc", "/var", "/var/log", "/var/www", "/home", "/tmp", "/opt", "/srv", "/usr", "/usr/local", "/usr/local/bin"):
    mkdir(d, age_days=120)
mkdir("/tmp", 0o777, age_days=0.2)
put("/etc/hostname", NAME + "\n", age_days=120)
put("/etc/hosts", "127.0.0.1 localhost\n127.0.1.1 %s.internal %s\n%s %s.internal\n\n::1 ip6-localhost ip6-loopback\n" % (NAME, NAME, IP, NAME), age_days=120)
put("/etc/os-release", """PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.1 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
UBUNTU_CODENAME=noble
LOGO=ubuntu-logo
""", age_days=120)
put("/etc/passwd", "root:x:0:0:root:/root:/bin/bash\nwww-data:x:33:33:www-data:/var/www:/usr/sbin/nologin\n"
    "postgres:x:114:121:PostgreSQL administrator,,,:/var/lib/postgresql:/bin/bash\n"
    "deploy:x:1000:1000:Deploy,,,:/home/deploy:/bin/bash\n", age_days=90)
put("/etc/resolv.conf", "nameserver 10.40.0.2\nsearch internal\n", age_days=90)
put("/etc/fstab", "UUID=0b1c6e9a-3f1d-4e0e-9a55-2d6f1f0a7c11 / ext4 defaults 0 1\nUUID=7E3A-1B2C /boot/efi vfat umask=0077 0 1\n", age_days=120)

# --- compte deploy
home = "/home/deploy"
mkdir(home, 0o750, age_days=1)
put(home + "/.bashrc", "# ~/.bashrc : exécuté pour les shells interactifs non-login\ncase $- in *i*) ;; *) return;; esac\nHISTSIZE=1000\nalias ll='ls -alF'\n", age_days=90)
put(home + "/.profile", "# ~/.profile\nif [ -n \"$BASH_VERSION\" ]; then . \"$HOME/.bashrc\"; fi\n", age_days=90)
put(home + "/.bash_logout", "# ~/.bash_logout\n", age_days=90)
mkdir(home + "/.ssh", 0o700, age_days=60)
put(home + "/.ssh/known_hosts", "", 0o600, age_days=40)
put(home + "/notes.txt", "A faire :\n- tourner les logs nginx (logrotate ok)\n- verifier la sauvegarde du %s\n- mise a jour du noyau au prochain creneau\n" % (time.strftime("%d/%m", time.localtime(NOW + 6 * DAY))), age_days=3)
mkdir(home + "/scripts", age_days=20)
put(home + "/scripts/deploy.sh", "#!/bin/bash\n# Deploiement de l'application : bascule sur la derniere release\nset -euo pipefail\nAPP=/var/www/app\nREL=$(ls -1 \"$APP/releases\" | tail -n 1)\necho \"Release $REL\"\ndocker compose -f \"$APP/docker-compose.yml\" up -d\n", 0o755, age_days=12)
put(home + "/scripts/backup-db.sh", "#!/bin/bash\n# Sauvegarde quotidienne (pg_dump compresse)\nset -euo pipefail\nOUT=/var/backups/postgres/appdb-$(date +%F).sql.gz\npg_dump appdb | gzip > \"$OUT\"\n", 0o755, age_days=30)
put(home + "/scripts/rotate-logs.sh", "#!/bin/bash\nsudo logrotate -f /etc/logrotate.d/nginx\n", 0o755, age_days=45)
mkdir(home + "/downloads", age_days=5)
put(home + "/downloads/rapport-trafic-2026-10.csv", "date,requetes,erreurs_5xx\n" + "".join("2026-10-%02d,%d,%d\n" % (d, rnd.randint(41000, 98000), rnd.randint(0, 40)) for d in range(1, 32)), age_days=14)
put(home + "/downloads/migration-2026-11.sql", "-- migration du schema (fictive)\nALTER TABLE orders ADD COLUMN shipped_at timestamptz;\nCREATE INDEX idx_orders_shipped ON orders (shipped_at);\n", age_days=6)

# --- nginx (configs)
mkdir("/etc/nginx")
put("/etc/nginx/nginx.conf", """user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
""", age_days=80)
site = """upstream app_backend {
    server 127.0.0.1:8080;
    keepalive 16;
}

server {
    listen 80;
    server_name %s.internal;
    root /var/www/app/public;

    location /static/ {
        expires 7d;
    }

    location / {
        proxy_pass http://app_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
""" % NAME
mkdir("/etc/nginx/sites-available")
mkdir("/etc/nginx/sites-enabled")
mkdir("/etc/nginx/conf.d")
put("/etc/nginx/sites-available/app.conf", site, age_days=35)
put("/etc/nginx/sites-enabled/app.conf", site, age_days=35)
put("/etc/nginx/conf.d/gzip.conf", "gzip_types text/plain text/css application/json application/javascript;\n", age_days=80)
put("/etc/nginx/mime.types", "types {\n    text/html html htm;\n    text/css css;\n    application/javascript js;\n    image/png png;\n}\n", age_days=80)


# --- projet web (/var/www/app)
app = "/var/www/app"
mkdir(app, age_days=2)
put(app + "/docker-compose.yml", """services:
  web:
    image: registry.internal/shop/web:2026.11.3
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    env_file: .env
    depends_on:
      - cache
  worker:
    image: registry.internal/shop/worker:2026.11.3
    restart: unless-stopped
    env_file: .env
  cache:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - cache-data:/data

volumes:
  cache-data:
""", age_days=4)
put(app + "/.env.example", "APP_ENV=production\nAPP_PORT=8080\nDATABASE_URL=postgres://app@db-primary.internal:5432/appdb\nREDIS_URL=redis://cache:6379/0\nLOG_LEVEL=info\n# SECRET_KEY : a renseigner dans .env (non versionne)\nSECRET_KEY=\n", age_days=50)
put(app + "/README.md", "# shop-app\n\nApplication web (API + worker).\n\n## Deploiement\n\n    ./scripts/deploy.sh\n\nVoir `docker-compose.yml`.\n", age_days=50)
put(app + "/Makefile", "up:\n\tdocker compose up -d\n\nlogs:\n\tdocker compose logs -f --tail=100\n\nrestart:\n\tdocker compose restart web\n", age_days=50)
mkdir(app + "/src", age_days=4)
put(app + "/src/main.py", "from fastapi import FastAPI\n\nfrom .routes import orders, health\n\napp = FastAPI(title=\"shop-app\")\napp.include_router(health.router)\napp.include_router(orders.router, prefix=\"/api/v1\")\n", age_days=4)
put(app + "/src/routes.py", "# routes de l'API (extrait)\nfrom fastapi import APIRouter\n\nrouter = APIRouter()\n\n\n@router.get(\"/healthz\")\ndef healthz():\n    return {\"status\": \"ok\"}\n", age_days=9)
put(app + "/src/models.py", "from dataclasses import dataclass\n\n\n@dataclass\nclass Order:\n    id: int\n    customer_id: int\n    total_cents: int\n", age_days=20)
put(app + "/src/requirements.txt", "fastapi==0.115.4\nuvicorn==0.32.0\npsycopg==3.2.3\nredis==5.2.0\n", age_days=20)
mkdir(app + "/public", age_days=4)
put(app + "/public/index.html", "<!doctype html>\n<html lang=\"fr\"><head><meta charset=\"utf-8\"><title>Shop</title></head>\n<body><div id=\"app\"></div><script src=\"/static/app.js\"></script></body></html>\n", age_days=11)
mkdir(app + "/public/static", age_days=11)
put(app + "/public/static/app.css", "body{font:16px/1.5 system-ui;margin:0}\n" * 40, age_days=11)
put(app + "/public/static/app.js", "(function(){console.log('shop');})();\n" * 220, age_days=11)
put(app + "/public/static/logo.png", binary=b"\x89PNG\r\n\x1a\n" + bytes(rnd.getrandbits(8) for _ in range(6200)), age_days=70)
mkdir(app + "/releases", age_days=2)
for i, rel in enumerate(("20261105-1", "20261110-1", "20261113-2")):
    mkdir("%s/releases/%s" % (app, rel), age_days=10 - i * 3)
    put("%s/releases/%s/BUILD_INFO" % (app, rel), "build=%s\ncommit=%07x\nimage=registry.internal/shop/web:2026.11.%d\n" % (rel, rnd.getrandbits(28), i + 1), age_days=10 - i * 3)
    put("%s/releases/%s/app.tar.gz" % (app, rel), sparse=rnd.randint(18, 44) * 1024 * 1024 + rnd.randint(0, 99999), binary=gzip.compress(b"app"), age_days=10 - i * 3)

# --- logs
mkdir("/var/log/nginx", age_days=1)
ips = ["203.0.113.%d" % n for n in (7, 18, 42, 77, 130, 201)] + ["198.51.100.%d" % n for n in (5, 23, 64, 99, 172)] + ["192.0.2.%d" % n for n in (9, 31, 88, 140)]
paths = ["/", "/", "/api/v1/orders", "/api/v1/orders?page=2", "/api/v1/products", "/static/app.css", "/static/app.js",
         "/static/logo.png", "/healthz", "/login", "/cart", "/api/v1/orders/18342", "/favicon.ico"]
uas = ["Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
       "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", "curl/8.5.0", "kube-probe/1.30"]
codes = [200] * 14 + [304] * 3 + [301, 404, 404, 499, 500, 502]


def access_log(n, end_ts, span):
    lines = []
    for t in sorted(rnd.uniform(end_ts - span, end_ts) for _ in range(n)):
        ts = time.strftime("%d/%b/%Y:%H:%M:%S +0000", time.gmtime(t))
        code = rnd.choice(codes)
        size = 0 if code in (304, 499) else rnd.randint(180, 52000)
        lines.append('%s - - [%s] "GET %s HTTP/1.1" %d %d "-" "%s"\n' % (rnd.choice(ips), ts, rnd.choice(paths), code, size, rnd.choice(uas)))
    return "".join(lines)


if ROLE != "db":
    put("/var/log/nginx/access.log", access_log(3600, NOW - 30, 6 * 3600), 0o640, age_days=0.0003)
    put("/var/log/nginx/access.log.1", access_log(9000, NOW - 86400, 24 * 3600), 0o640, age_days=1)
    errs = ""
    for i in range(36):
        t = time.strftime("%Y/%m/%d %H:%M:%S", time.gmtime(NOW - rnd.randint(300, 40000)))
        errs += "%s %s\n" % (t, rnd.choice([
            "[error] 815#815: *%d connect() failed (111: Connection refused) while connecting to upstream, client: %s, server: %s.internal, request: \"GET /api/v1/orders HTTP/1.1\"",
            "[warn] 815#815: *%d upstream response is buffered to a temporary file /var/cache/nginx/proxy_temp/3/04/0000000043, client: %s, server: %s.internal",
            "[error] 816#816: *%d open() \"/var/www/app/public/robots.txt\" failed (2: No such file or directory), client: %s, server: %s.internal",
        ]) % (rnd.randint(1000, 90000), rnd.choice(ips), NAME))
    errs = "".join(sorted(errs.splitlines(True)))
    put("/var/log/nginx/error.log", errs, 0o640, age_days=0.01)
put("/var/log/syslog", "".join("%s %s systemd[1]: Finished logrotate.service - Rotate log files.\n" % (time.strftime("%b %e %H:%M:%S", time.localtime(NOW - i * 3600)), NAME) for i in range(24, 0, -1)), 0o640, age_days=0.01)
put("/var/log/auth.log", "".join("%s %s sshd[%d]: Accepted publickey for deploy from %s port %d ssh2: ED25519 SHA256:%s\n" % (
    time.strftime("%b %e %H:%M:%S", time.localtime(NOW - i * 5400)), NAME, rnd.randint(1000, 9000), rnd.choice(ips), rnd.randint(40000, 60000),
    "".join(rnd.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") for _ in range(43))) for i in range(20, 0, -1)), 0o640, age_days=0.01)

# --- spécifique au rôle
if ROLE == "db":
    mkdir("/var/backups", age_days=100)
    mkdir("/var/backups/postgres", 0o750, age_days=1)
    for d in range(1, 15):
        sz = rnd.randint(110, 190) * 1024 * 1024 + rnd.randint(0, 999999) if d % 7 else rnd.randint(40, 80) * 1024 * 1024
        put("/var/backups/postgres/appdb-2026-11-%02d.sql.gz" % d, sparse=sz, binary=gzip.compress(b"-- dump"), age_days=15 - d)
    put("/var/backups/postgres/appdb-2026-11-15.sql.gz.part", sparse=22 * 1024 * 1024, binary=b"\x1f\x8b", age_days=0.01)
    mkdir("/etc/postgresql/16/main", age_days=100)
    put("/etc/postgresql/16/main/postgresql.conf", "listen_addresses = '10.40.2.10'\nport = 5432\nmax_connections = 200\nshared_buffers = 8GB\nwal_level = replica\narchive_mode = on\n", age_days=40)
    put("/etc/postgresql/16/main/pg_hba.conf", "local all postgres peer\nhost appdb app 10.40.1.0/24 scram-sha-256\nhost replication replica 10.40.2.11/32 scram-sha-256\n", age_days=40)
    mkdir("/var/log/postgresql", age_days=1)
    put("/var/log/postgresql/postgresql-16-main.log", "".join("%s UTC [%d] LOG:  checkpoint complete: wrote %d buffers (%.1f%%); sync files=%d, longest=0.%03d s\n" % (
        time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(NOW - i * 300)), 1180 + i % 3, rnd.randint(120, 4800), rnd.uniform(0.7, 29), rnd.randint(12, 90), rnd.randint(1, 400)) for i in range(60, 0, -1)), 0o640, age_days=0.01)
if ROLE == "bastion":
    mkdir("/etc/ssh", age_days=120)
    put("/etc/ssh/sshd_config", "Port 22\nPermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowTcpForwarding yes\nClientAliveInterval 60\n", age_days=70)
    put("/home/deploy/hosts-internes.txt", "web-01  10.40.1.11\nweb-02  10.40.1.12\ndb-primary  10.40.2.10\ndb-replica  10.40.2.11\ncache-01  10.40.2.20\n", age_days=8)

# Les serveurs qui ne sont pas des frontaux web n'ont ni nginx ni application.
if ROLE != "web":
    import shutil
    for d in ("/etc/nginx", "/var/www", "/var/log/nginx"):
        shutil.rmtree(ROOT + d, ignore_errors=True)
    os.makedirs(ROOT + "/var/www", exist_ok=True)

# Les dossiers parents sont datés après la création de leurs fichiers : chaque dossier prend la date de son
# contenu le plus récent (bas en haut), ce qui reste cohérent (une release du 5 nov. a un dossier du 5 nov.).
for dirpath, dirs, files in os.walk(ROOT, topdown=False):
    ts = [os.lstat(os.path.join(dirpath, n)).st_mtime for n in dirs + files]
    if ts:
        t = max(ts) - rnd.random() * 3600
        os.utime(dirpath, (t, t))
for d in ("/var/www/app", "/home/deploy", "/var/log/nginx", "/tmp"):
    t = NOW - rnd.random() * 0.4 * DAY
    if os.path.isdir(ROOT + d):
        os.utime(ROOT + d, (t, t))
for d in ("/", "/home", "/var", "/var/www", "/var/log", "/etc", "/usr", "/opt", "/srv"):
    t = NOW - (60 + rnd.random() * 90) * DAY
    os.utime(ROOT + d, (t, t))
