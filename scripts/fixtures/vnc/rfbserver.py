#!/usr/bin/env python3
"""Serveur RFB 3.8 de test (stdlib seule) pour `scripts/selftest-vnc.sh`.

- Authentification VNC (DES) : mot de passe dans $ESCALE_VNCTEST_PASSWORD (jamais écrit sur disque).
  La réponse attendue est calculée par un DES en Python pur (aucun outil externe).
- Port 0 : le port choisi est écrit dans le fichier donné par --port-file.
- Premier FramebufferUpdateRequest non incrémental : motif connu, en Raw, Hextile, ZRLE (flux zlib persistant),
  CopyRect, plus le pseudo-encodage Cursor. Écran 160x96.
- Déclencheurs en bande, par KeyEvent (appui) : 'z' -> DesktopSize 200x120 puis fond uni ; 'c' -> ServerCutText ;
  'b' -> Bell.
- Journal (--log) : une ligne par événement client (key, ptr, cut, setenc, auth, disconnect), vidée à chaque ligne.
"""
import argparse, os, random, socket, struct, subprocess, sys, threading, zlib

W, H = 160, 96


# DES (FIPS 46-3) en Python pur : le /usr/bin/openssl du systeme (LibreSSL) n'a pas de fournisseur « legacy »,
# et la recette ne doit dependre d'aucun outil Homebrew.
_PC1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,
        63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4]
_PC2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,
        41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32]
_SHIFTS = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1]
_IP = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,
       57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7]
_FP = [40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,
       36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25]
_E = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,
      24,25,26,27,28,29,28,29,30,31,32,1]
_P = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25]
_S = [
 [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
 [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
 [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
 [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14],
 [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
 [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
 [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
 [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11]]


def _perm(v, table, width):
    return sum(((v >> (width - t)) & 1) << (len(table) - 1 - i) for i, t in enumerate(table))


def des_ecb(key8: bytes, block: bytes) -> bytes:
    k = _perm(int.from_bytes(key8, "big"), _PC1, 64)
    c, d = k >> 28, k & 0xFFFFFFF
    subkeys = []
    for sh in _SHIFTS:
        c = ((c << sh) | (c >> (28 - sh))) & 0xFFFFFFF
        d = ((d << sh) | (d >> (28 - sh))) & 0xFFFFFFF
        subkeys.append(_perm((c << 28) | d, _PC2, 56))
    v = _perm(int.from_bytes(block, "big"), _IP, 64)
    l, r = v >> 32, v & 0xFFFFFFFF
    for sk in subkeys:
        x = _perm(r, _E, 32) ^ sk
        out = 0
        for i in range(8):
            six = (x >> (42 - 6 * i)) & 0x3F
            out = (out << 4) | _S[i][(((six & 0x20) >> 4) | (six & 1)) * 16 + ((six >> 1) & 0xF)]
        l, r = r, l ^ _perm(out, _P, 32)
    return _perm((r << 32) | l, _FP, 64).to_bytes(8, "big")


def vnc_response(password: str, challenge: bytes) -> bytes:
    raw = password.encode("latin-1", "replace")[:8].ljust(8, b"\0")
    key = bytes(int(f"{b:08b}"[::-1], 2) for b in raw)  # octets de clé bit-inversés (particularité VNC)
    return des_ecb(key, challenge[:8]) + des_ecb(key, challenge[8:])


def px(r, g, b):
    return bytes([b, g, r, 0])


def rect_header(x, y, w, h, enc):
    return struct.pack(">HHHHi", x, y, w, h, enc)


class Conn(threading.Thread):
    def __init__(self, sock, log, password):
        super().__init__(daemon=True)
        self.s, self.log, self.password = sock, log, password
        self.z = zlib.compressobj()
        self.size = (W, H)
        self.resized = False
        self.sent_initial = False

    def read(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise EOFError
            buf += chunk
        return buf

    # --- motif connu
    def initial_update(self, encodings):
        rects = []
        # Raw (0,0,80,48) : r = 3x, g = 5y, b = (x+y) % 256
        data = b"".join(px(3 * x, 5 * y, (x + y) % 256) for y in range(48) for x in range(80))
        rects.append(rect_header(0, 0, 80, 48, 0) + data)
        # Hextile (80,0,80,48) : 5x3 tuiles de 16
        tiles = bytearray()
        tiles += bytes([0x02 | 0x04 | 0x08]) + px(10, 10, 200)[:4] + px(250, 250, 0)[:4] + bytes([1, (2 << 4) | 3, (3 << 4) | 4])
        for t in range(1, 15):
            if t == 4:
                tiles += bytes([0x01]) + px(7, 77, 177) * 256  # tuile brute
            else:
                tiles += bytes([0x00])  # fond précédent
        rects.append(rect_header(80, 0, 80, 48, 5) + bytes(tiles))
        # ZRLE (0,48,160,48) : tuiles 64x64 -> 64, 64, 32 de large
        t0 = bytes([1]) + bytes([0, 200, 0])  # uni, CPIXEL B,G,R = vert
        t1 = bytes([1]) + bytes([200, 0, 200])  # uni, B=200,G=0,R=200 (magenta)
        run = 32 * 48 - 1
        t2 = bytes([128]) + bytes([90, 90, 90]) + bytes([255] * (run // 255)) + bytes([run % 255])
        comp = self.z.compress(t0 + t1 + t2) + self.z.flush(zlib.Z_SYNC_FLUSH)
        rects.append(rect_header(0, 48, 160, 48, 16) + struct.pack(">I", len(comp)) + comp)
        # CopyRect (120,24,40,24) <- (0,0)
        rects.append(rect_header(120, 24, 40, 24, 1) + struct.pack(">HH", 0, 0))
        if -239 in encodings:  # curseur 4x4 rouge, point chaud (1,1)
            cur = px(255, 0, 0) * 16 + bytes([0b11110000] * 4)
            rects.append(rect_header(1, 1, 4, 4, -239) + cur)
        return struct.pack(">BxH", 0, len(rects)) + b"".join(rects)

    def run(self):
        s = self.s
        try:
            s.sendall(b"RFB 003.008\n")
            self.read(12)
            s.sendall(bytes([1, 2]))
            self.read(1)
            challenge = bytes(random.randrange(256) for _ in range(16))
            s.sendall(challenge)
            answer = self.read(16)
            if answer != vnc_response(self.password, challenge):
                reason = "Mot de passe refuse par le serveur de test".encode()
                s.sendall(struct.pack(">I", 1) + struct.pack(">I", len(reason)) + reason)
                self.log("auth fail")
                return
            s.sendall(struct.pack(">I", 0))
            self.log("auth ok")
            self.log(f"clientinit shared={self.read(1)[0]}")
            name = b"escale-test"
            fmt = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
            s.sendall(struct.pack(">HH", W, H) + fmt + struct.pack(">I", len(name)) + name)
            encodings = []
            while True:
                t = self.read(1)[0]
                if t == 0:
                    self.read(19)
                elif t == 2:
                    _, n = struct.unpack(">BH", self.read(3))
                    encodings = list(struct.unpack(f">{n}i", self.read(4 * n)))
                    self.log("setenc " + " ".join(map(str, encodings)))
                elif t == 3:
                    inc, x, y, w, h = struct.unpack(">BHHHH", self.read(9))
                    self.log(f"fbreq inc={inc} {x},{y} {w}x{h}")
                    if not inc and not self.sent_initial:
                        self.sent_initial = True
                        s.sendall(self.initial_update(encodings))
                    elif not inc and self.resized:
                        self.resized = False
                        w2, h2 = self.size
                        s.sendall(struct.pack(">BxH", 0, 1) + rect_header(0, 0, w2, h2, 0) + px(1, 2, 3) * (w2 * h2))
                elif t == 4:
                    down, _, key = struct.unpack(">BHI", self.read(7))
                    self.log(f"key {'down' if down else 'up'} {key:#x}")
                    if down and key == ord("z"):
                        self.size, self.resized = (200, 120), True
                        s.sendall(struct.pack(">BxH", 0, 1) + rect_header(0, 0, 200, 120, -223))
                    elif down and key == ord("c"):
                        txt = "texte-serveur é".encode("latin-1")
                        s.sendall(bytes([3, 0, 0, 0]) + struct.pack(">I", len(txt)) + txt)
                    elif down and key == ord("b"):
                        s.sendall(bytes([2]))
                elif t == 5:
                    mask, x, y = struct.unpack(">BHH", self.read(5))
                    self.log(f"ptr {x} {y} {mask}")
                elif t == 6:
                    n = struct.unpack(">3xI", self.read(7))[0]
                    self.log("cut " + self.read(n).decode("latin-1"))
                else:
                    self.log(f"message inconnu {t}")
                    return
        except (EOFError, ConnectionError, OSError):
            pass
        finally:
            self.log("disconnect")
            s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--log", required=True)
    a = ap.parse_args()
    password = os.environ.get("ESCALE_VNCTEST_PASSWORD", "")
    lock = threading.Lock()
    logf = open(a.log, "a", buffering=1)

    def log(line):
        with lock:
            logf.write(line + "\n")
            logf.flush()

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)
    with open(a.port_file + ".tmp", "w") as f:
        f.write(str(srv.getsockname()[1]))
    os.rename(a.port_file + ".tmp", a.port_file)
    while True:
        c, _ = srv.accept()
        Conn(c, log, password).start()


if __name__ == "__main__":
    main()
