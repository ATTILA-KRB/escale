#!/usr/bin/env python3
"""Faux serveur X11 minimal AVEC l'extension SECURITY, pour la recette X11 « non fiable » d'Escale.

Un vrai `xauth generate … untrusted` (celui de Homebrew) demande à l'écran un cookie MIT-MAGIC-COOKIE-1 « untrusted »
par la requête SECURITY/GenerateAuthorization : ce serveur la comprend et renvoie un vrai cookie aléatoire de 16 octets.
Il répond aussi juste ce qu'il faut à libX11/libxcb (prise de contact, QueryExtension, GetProperty, GetInputFocus).
Les connexions X rapatriées par ssh (-X) arrivent aussi ici : si la première requête n'est pas une prise de contact
valide, les octets reçus sont journalisés (« raw ») et le cookie présenté est comparé à ceux qui ont été générés.

Usage : fakex_security.py <socket-unix> <journal> <fichier-cookies>
  - journal : lignes « QueryExtension … », « GenerateAuthorization … <hex> », « CONNECT cookie=<hex> ok|inconnu ».
  - fichier-cookies : un cookie (hex) généré par ligne.
"""
import os, secrets, socket, struct, sys, threading

path, log, cookies = sys.argv[1], sys.argv[2], sys.argv[3]
SECURITY_OPCODE = 150
lock = threading.Lock()


def pad(n):
    return (4 - n % 4) % 4


def logline(s):
    with lock, open(log, "a") as f:
        f.write(s + "\n")


def recv_exact(c, n):
    buf = b""
    while len(buf) < n:
        chunk = c.recv(n - len(buf))
        if not chunk:
            return buf
        buf += chunk
    return buf


def setup_reply():
    vendor = b"fakeX"
    fmt = struct.pack("<BBB5x", 24, 32, 32)
    visual = struct.pack("<IBBHIII4x", 0x21, 4, 8, 256, 0xFF0000, 0xFF00, 0xFF)
    depth = struct.pack("<BxH4x", 24, 1) + visual
    screen = struct.pack("<IIIIIHHHHHHIBBBB", 0x20, 0x22, 0, 0xFFFFFF, 0, 800, 600, 200, 150, 1, 1, 0x21, 0, 0, 24, 1) + depth
    body = struct.pack("<IIIIHHBBBBBBBB4x", 0, 0x200000, 0x1FFFFF, 256, len(vendor), 0xFFFF, 1, 1, 0, 0, 32, 32, 8, 255)
    body += vendor + b"\0" * pad(len(vendor)) + fmt + screen
    return struct.pack("<BxHHH", 1, 11, 0, len(body) // 4) + body


def known_cookies():
    try:
        return set(open(cookies).read().split())
    except FileNotFoundError:
        return set()


def handle(c):
    try:
        hdr = recv_exact(c, 12)
        if len(hdr) < 12:
            return
        an, ad = struct.unpack("<HH", hdr[6:10])
        auth = recv_exact(c, an + pad(an) + ad + pad(ad))
        name = auth[:an]
        data = auth[an + pad(an):an + pad(an) + ad]
        if hdr[0] == 0x6C and name:  # connexion X « client » (octet 'l', petit boutisme)
            ok = "ok" if data.hex() in known_cookies() else "inconnu"
            logline("CONNECT proto=%s cookie=%s %s" % (name.decode(errors="replace"), data.hex(), ok))
        c.sendall(setup_reply())
        seq = 0
        while True:
            h = recv_exact(c, 4)
            if len(h) < 4:
                return
            op, sub, ln = h[0], h[1], struct.unpack("<H", h[2:4])[0]
            rest = recv_exact(c, ln * 4 - 4) if ln > 1 else b""
            seq = (seq + 1) & 0xFFFF
            if op == 98:  # QueryExtension
                n = struct.unpack("<H", rest[0:2])[0]
                ext = rest[4:4 + n]
                present = 1 if ext == b"SECURITY" else 0
                logline("QueryExtension " + ext.decode(errors="replace"))
                c.sendall(struct.pack("<BxHIBBBB20x", 1, seq, 0, present, SECURITY_OPCODE if present else 0, 0, 0))
            elif op == SECURITY_OPCODE and sub == 0:  # SecurityQueryVersion
                c.sendall(struct.pack("<BxHIHH20x", 1, seq, 0, 1, 0))
            elif op == SECURITY_OPCODE and sub == 1:  # SecurityGenerateAuthorization
                n = struct.unpack("<H", rest[0:2])[0]
                proto = rest[8:8 + n]
                cookie = secrets.token_bytes(16)
                with lock, open(cookies, "a") as f:
                    f.write(cookie.hex() + "\n")
                logline("GenerateAuthorization %s %s" % (proto.decode(errors="replace"), cookie.hex()))
                c.sendall(struct.pack("<BxHIIH18x", 1, seq, len(cookie) // 4, 0x1234, len(cookie)) + cookie)
            elif op == 20:  # GetProperty : propriété absente
                c.sendall(struct.pack("<BBHIIII12x", 1, 0, seq, 0, 0, 0, 0))
            elif op == 43:  # GetInputFocus (synchronisation)
                c.sendall(struct.pack("<BBHII20x", 1, 0, seq, 0, 0))
            # autres requêtes (CreateGC…) : sans réponse
    except Exception as e:  # noqa: BLE001
        logline("erreur " + repr(e))
    finally:
        c.close()


try:
    os.unlink(path)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX)
s.bind(path)
s.listen(8)
logline("pret")
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
