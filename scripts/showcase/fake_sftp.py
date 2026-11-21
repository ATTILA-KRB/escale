#!/usr/bin/python3 -B
"""Faux serveur SFTP v3 (stdlib) du labo de captures.

Usage : fake_sftp.py <racine réelle>
Parle SFTP sur stdin/stdout (lancé par le wrapper sshd). Le FS exposé est la racine fictive : tous les
chemins renvoyés (REALPATH, noms) sont virtuels, propriétaires et uid/gid fictifs (deploy 1000, www-data 33).
Toute sortie de la racine (`..`, lien symbolique) est refusée. Paquets non gérés : SSH_FX_OP_UNSUPPORTED.
"""
import os
import stat
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import fakefs  # noqa: E402

# Types de paquets
INIT, VERSION, OPEN, CLOSE, READ, WRITE, LSTAT, FSTAT, SETSTAT, FSETSTAT = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
OPENDIR, READDIR, REMOVE, MKDIR, RMDIR, REALPATH, STAT, RENAME, READLINK, SYMLINK = 11, 12, 13, 14, 15, 16, 17, 18, 19, 20
EXTENDED = 200
STATUS, HANDLE, DATA, NAME, ATTRS = 101, 102, 103, 104, 105
OK, EOF, NO_SUCH_FILE, PERMISSION_DENIED, FAILURE, BAD_MESSAGE, OP_UNSUPPORTED = 0, 1, 2, 3, 4, 5, 8
MAX_PACKET = 1 << 20
MAX_READ = 256 * 1024

ROOT = os.path.realpath(sys.argv[1])
IN = sys.stdin.buffer
OUT = sys.stdout.buffer
handles = {}
next_handle = 1


def read_exact(n):
    buf = b""
    while len(buf) < n:
        chunk = IN.read(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def send(ptype, payload):
    OUT.write(struct.pack(">IB", len(payload) + 1, ptype) + payload)
    OUT.flush()


class Reader:
    def __init__(self, data):
        self.d, self.i = data, 0

    def u32(self):
        v = struct.unpack_from(">I", self.d, self.i)[0]
        self.i += 4
        return v

    def u64(self):
        v = struct.unpack_from(">Q", self.d, self.i)[0]
        self.i += 8
        return v

    def string(self):
        n = self.u32()
        if self.i + n > len(self.d):
            raise ValueError("chaîne tronquée")
        s = self.d[self.i:self.i + n]
        self.i += n
        return s

    def path(self):
        return self.string().decode("utf-8", "surrogateescape")

    def attrs(self):
        flags = self.u32()
        a = {}
        if flags & 0x1:
            a["size"] = self.u64()
        if flags & 0x2:
            a["uid"], a["gid"] = self.u32(), self.u32()
        if flags & 0x4:
            a["perm"] = self.u32()
        if flags & 0x8:
            a["atime"], a["mtime"] = self.u32(), self.u32()
        if flags & 0x80000000:
            for _ in range(self.u32()):
                self.string()
                self.string()
        return a


def s32(b):
    return struct.pack(">I", len(b)) + b


def status(rid, code, msg=""):
    send(STATUS, struct.pack(">II", rid, code) + s32(msg.encode()) + s32(b"en"))


def encode_attrs(v, st, size):
    u, g, uid, gid = fakefs.owner(v)
    return struct.pack(">IQIIIII", 0xF, size, uid, gid, st.st_mode, int(st.st_atime), int(st.st_mtime))


def err_status(rid, e):
    if isinstance(e, FileNotFoundError):
        status(rid, NO_SUCH_FILE, "No such file")
    elif isinstance(e, PermissionError):
        status(rid, PERMISSION_DENIED, "Permission denied")
    elif isinstance(e, FileExistsError):
        status(rid, FAILURE, "File exists")
    elif isinstance(e, NotADirectoryError):
        status(rid, FAILURE, "Not a directory")
    elif isinstance(e, IsADirectoryError):
        status(rid, FAILURE, "Is a directory")
    elif isinstance(e, OSError) and e.errno == 66:
        status(rid, FAILURE, "Directory not empty")
    else:
        status(rid, FAILURE, "Failure")


def new_handle(obj):
    global next_handle
    h = str(next_handle).encode()
    next_handle += 1
    handles[h] = obj
    return h


def apply_setstat(real, a):
    if "perm" in a:
        os.chmod(real, a["perm"] & 0o7777)
    if "mtime" in a:
        os.utime(real, (a.get("atime", a["mtime"]), a["mtime"]))
    if "size" in a:
        os.truncate(real, a["size"])


def handle_packet(ptype, data):
    r = Reader(data)
    if ptype == EXTENDED:
        rid = r.u32()
        name = r.string().decode()
        if name == "posix-rename@openssh.com":
            old, new = r.path(), r.path()
            try:
                os.rename(fakefs.real_of(ROOT, old, follow=False), fakefs.real_of(ROOT, new, follow=False))
                status(rid, OK)
            except Exception as e:  # noqa: BLE001
                err_status(rid, e)
        else:
            status(rid, OP_UNSUPPORTED, "Operation unsupported")
        return
    rid = r.u32()
    try:
        if ptype in (REALPATH,):
            v = fakefs.vnorm(r.path())
            send(NAME, struct.pack(">II", rid, 1) + s32(v.encode()) + s32(v.encode()) + struct.pack(">I", 0))
        elif ptype in (STAT, LSTAT):
            v = fakefs.vnorm(r.path())
            real = fakefs.real_of(ROOT, v, follow=(ptype == STAT))
            st = os.stat(real) if ptype == STAT else os.lstat(real)
            size = 4096 if stat.S_ISDIR(st.st_mode) else st.st_size
            send(ATTRS, struct.pack(">I", rid) + encode_attrs(v, st, size))
        elif ptype == FSTAT:
            h = handles.get(r.string())
            if not h:
                return status(rid, FAILURE, "Bad handle")
            st = os.fstat(h["fd"]) if h["kind"] == "file" else os.stat(h["real"])
            size = 4096 if stat.S_ISDIR(st.st_mode) else st.st_size
            send(ATTRS, struct.pack(">I", rid) + encode_attrs(h["v"], st, size))
        elif ptype == OPENDIR:
            v = fakefs.vnorm(r.path())
            real = fakefs.real_of(ROOT, v)
            if not os.path.isdir(real):
                return status(rid, NO_SUCH_FILE, "No such file")
            names = [".", ".."] + sorted(os.listdir(real), key=lambda n: n.lower())
            h = new_handle({"kind": "dir", "v": v, "real": real, "names": names, "pos": 0})
            send(HANDLE, struct.pack(">I", rid) + s32(h))
        elif ptype == READDIR:
            h = handles.get(r.string())
            if not h or h["kind"] != "dir":
                return status(rid, FAILURE, "Bad handle")
            if h["pos"] >= len(h["names"]):
                return status(rid, EOF, "End of file")
            batch = h["names"][h["pos"]:h["pos"] + 64]
            h["pos"] += len(batch)
            body = b""
            n = 0
            for name in batch:
                try:
                    if name == ".":
                        cv, cr = h["v"], h["real"]
                    elif name == "..":
                        cv = fakefs.vnorm(h["v"] + "/..")
                        cr = ROOT if cv == "/" else ROOT + cv
                    else:
                        cv = fakefs.vnorm(h["v"] + "/" + name)
                        cr = os.path.join(h["real"], name)
                    st = os.lstat(cr)
                except OSError:
                    continue
                size = 4096 if stat.S_ISDIR(st.st_mode) else st.st_size
                body += s32(name.encode("utf-8", "surrogateescape")) + s32(fakefs.long_entry(name, cv, st, size).encode("utf-8", "surrogateescape")) + encode_attrs(cv, st, size)
                n += 1
            send(NAME, struct.pack(">II", rid, n) + body)
        elif ptype == OPEN:
            v = fakefs.vnorm(r.path())
            pflags = r.u32()
            a = r.attrs()
            real = fakefs.real_of(ROOT, v)
            flags = 0
            acc = pflags & 3
            flags |= os.O_RDWR if acc == 3 else (os.O_WRONLY if acc == 2 else os.O_RDONLY)
            if pflags & 0x4:
                flags |= os.O_APPEND
            if pflags & 0x8:
                flags |= os.O_CREAT
            if pflags & 0x10:
                flags |= os.O_TRUNC
            if pflags & 0x20:
                flags |= os.O_EXCL
            fd = os.open(real, flags, a.get("perm", 0o644) & 0o777)
            h = new_handle({"kind": "file", "v": v, "real": real, "fd": fd})
            send(HANDLE, struct.pack(">I", rid) + s32(h))
        elif ptype == CLOSE:
            hid = r.string()
            h = handles.pop(hid, None)
            if h and h["kind"] == "file":
                os.close(h["fd"])
            status(rid, OK if h else FAILURE, "" if h else "Bad handle")
        elif ptype == READ:
            h = handles.get(r.string())
            off, ln = r.u64(), min(r.u32(), MAX_READ)
            if not h or h["kind"] != "file":
                return status(rid, FAILURE, "Bad handle")
            chunk = os.pread(h["fd"], ln, off)
            if not chunk:
                return status(rid, EOF, "End of file")
            send(DATA, struct.pack(">I", rid) + s32(chunk))
        elif ptype == WRITE:
            h = handles.get(r.string())
            off = r.u64()
            chunk = r.string()
            if not h or h["kind"] != "file":
                return status(rid, FAILURE, "Bad handle")
            os.pwrite(h["fd"], chunk, off)
            status(rid, OK)
        elif ptype == MKDIR:
            v = r.path()
            a = r.attrs()
            os.mkdir(fakefs.real_of(ROOT, v, follow=False), a.get("perm", 0o755) & 0o777)
            status(rid, OK)
        elif ptype == RMDIR:
            os.rmdir(fakefs.real_of(ROOT, r.path(), follow=False))
            status(rid, OK)
        elif ptype == REMOVE:
            real = fakefs.real_of(ROOT, r.path(), follow=False)
            if os.path.isdir(real) and not os.path.islink(real):
                return status(rid, FAILURE, "Is a directory")
            os.remove(real)
            status(rid, OK)
        elif ptype == RENAME:
            old, new = fakefs.real_of(ROOT, r.path(), follow=False), fakefs.real_of(ROOT, r.path(), follow=False)
            if os.path.lexists(new):
                return status(rid, FAILURE, "File exists")
            os.rename(old, new)
            status(rid, OK)
        elif ptype == SETSTAT:
            real = fakefs.real_of(ROOT, r.path())
            apply_setstat(real, r.attrs())
            status(rid, OK)
        elif ptype == FSETSTAT:
            h = handles.get(r.string())
            if not h:
                return status(rid, FAILURE, "Bad handle")
            apply_setstat(h["real"], r.attrs())
            status(rid, OK)
        else:  # READLINK, SYMLINK et inconnus
            status(rid, OP_UNSUPPORTED, "Operation unsupported")
    except (struct.error, ValueError):
        status(rid, BAD_MESSAGE, "Bad message")
    except OSError as e:
        err_status(rid, e)


def main():
    try:
        hdr = read_exact(5)
        ln, ptype = struct.unpack(">IB", hdr)
        if ptype != INIT:
            return 1
        read_exact(ln - 1)
        # VERSION 3 + extension posix-rename
        send(VERSION, struct.pack(">I", 3) + s32(b"posix-rename@openssh.com") + s32(b"1"))
        while True:
            ln, ptype = struct.unpack(">IB", read_exact(5))
            if ln < 1 or ln > MAX_PACKET:
                return 1
            data = read_exact(ln - 1)
            handle_packet(ptype, data)
    except EOFError:
        return 0


if __name__ == "__main__":
    sys.exit(main())
