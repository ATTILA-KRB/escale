"""Brique commune du labo de captures : chemins virtuels, propriétaires fictifs, formats de listing.

Le « serveur » ne montre jamais un chemin réel : tout est exprimé en chemins virtuels (/home/deploy…)
adossés à un dossier réel (la racine fictive). Python 3.9 (stdlib) suffit.
"""
import os
import stat
import time

HOME = "/home/deploy"


def vnorm(vpath, cwd=HOME):
    """Normalise un chemin virtuel (relatif à `cwd`), `..` bloqué à la racine."""
    if not vpath.startswith("/"):
        vpath = cwd + "/" + vpath
    parts = []
    for p in vpath.split("/"):
        if p in ("", "."):
            continue
        if p == "..":
            if parts:
                parts.pop()
            continue
        parts.append(p)
    return "/" + "/".join(parts)


def real_of(root, vpath, follow=True, cwd=HOME):
    """Chemin réel d'un chemin virtuel. Lève PermissionError si le résultat sortirait de la racine
    (lien symbolique compris). `follow=False` : le dernier composant n'est pas suivi (lstat, remove)."""
    v = vnorm(vpath, cwd)
    r = root if v == "/" else root + v
    rr = os.path.realpath(root)
    probe = os.path.realpath(r) if (follow or v == "/") else os.path.join(os.path.realpath(os.path.dirname(r)), os.path.basename(r))
    if not (probe == rr or probe.startswith(rr + os.sep)):
        raise PermissionError("hors racine")
    return r


def to_virtual(root, real):
    """Chemin virtuel d'un chemin réel sous la racine (« / » si c'est la racine)."""
    rr = os.path.realpath(root)
    p = os.path.realpath(real) if os.path.exists(real) else real
    if p == rr:
        return "/"
    if p.startswith(rr + os.sep):
        return p[len(rr):]
    return "/"


def owner(v):
    """(utilisateur, groupe, uid, gid) fictifs d'un chemin virtuel."""
    if v == "/var/www" or v.startswith("/var/www/"):
        return ("deploy", "www-data", 1000, 33)
    if v.startswith("/var/log/nginx"):
        return ("www-data", "adm", 33, 4)
    if v.startswith("/var/log"):
        return ("root", "adm", 0, 4)
    if v.startswith("/var/backups/postgres"):
        return ("postgres", "postgres", 114, 121)
    if v == HOME or v.startswith(HOME + "/"):
        return ("deploy", "deploy", 1000, 1000)
    return ("root", "root", 0, 0)


def fake_stat(real):
    """os.lstat avec taille de dossier fictive (4096) : les tailles réelles d'APFS ne ressemblent à rien."""
    st = os.lstat(real)
    size = 4096 if stat.S_ISDIR(st.st_mode) else st.st_size
    return st, size


def date_str(mtime, now=None):
    now = now or time.time()
    t = time.localtime(mtime)
    if abs(now - mtime) < 182 * 86400:
        return time.strftime("%b %e %H:%M", t)
    return time.strftime("%b %e  %Y", t)


def long_entry(name, v, st, size):
    u, g, _, _ = owner(v)
    return "%s %3d %-8s %-8s %8d %s %s" % (stat.filemode(st.st_mode), st.st_nlink, u, g, size, date_str(st.st_mtime), name)
