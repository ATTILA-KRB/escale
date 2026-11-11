#!/usr/bin/env python3
"""Serveur RFB 3.8 de test (stdlib seule) pour `scripts/selftest-vnc.sh`.

- Authentification VNC (DES) : mot de passe dans $ESCALE_VNCTEST_PASSWORD (jamais écrit sur disque).
  La réponse attendue est calculée par `openssl enc -des-ecb` (fournisseur « legacy »).
- Port 0 : le port choisi est écrit dans le fichier donné par --port-file.
- Premier FramebufferUpdateRequest non incrémental : motif connu, en Raw, Hextile, ZRLE (flux zlib persistant),
  CopyRect, plus le pseudo-encodage Cursor. Écran 160x96.
- Déclencheurs en bande, par KeyEvent (appui) : 'z' -> DesktopSize 200x120 puis fond uni ; 'c' -> ServerCutText ;
  'b' -> Bell.
- Journal (--log) : une ligne par événement client (key, ptr, cut, setenc, auth, disconnect), vidée à chaque ligne.
"""
import argparse, os, random, socket, struct, subprocess, sys, threading, zlib

W, H = 160, 96


def des_ecb(key8: bytes, block: bytes) -> bytes:
    out = subprocess.run(
        ["openssl", "enc", "-des-ecb", "-provider", "legacy", "-provider", "default", "-nopad", "-K", key8.hex()],
        input=block, capture_output=True, check=True).stdout
    return out


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
