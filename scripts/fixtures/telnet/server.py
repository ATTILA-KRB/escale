#!/usr/bin/env python3
"""Serveur Telnet de test (stdlib seule) pour scripts/selftest-telnet.sh.

Écoute sur 127.0.0.1, port libre (bind sur 0) écrit dans --port-file. Négocie ECHO / SGA / NAWS / TERMINAL-TYPE,
affiche une bannière puis l'invite « login: », renvoie ce qu'on tape (écho côté serveur), ferme sur la ligne « bye ».
Journal (--log), une ligne par événement : CONNECT, WILL/WONT/DO/DONT <opt>, TTYPE <type>, NAWS <cols>x<rows>,
DATA <hex des octets reçus après dés-échappement de IAC IAC>, CLOSE.
"""
import argparse
import socket
import threading

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
ECHO, SGA, TTYPE, NAWS = 1, 3, 24, 31

ap = argparse.ArgumentParser()
ap.add_argument("--port-file", required=True)
ap.add_argument("--log", required=True)
args = ap.parse_args()

log_lock = threading.Lock()


def log(line):
    with log_lock, open(args.log, "a") as f:
        f.write(line + "\n")


def serve(conn, n):
    log(f"CONNECT {n}")
    send = conn.sendall
    send(bytes([IAC, DO, TTYPE, IAC, DO, NAWS, IAC, WILL, ECHO, IAC, WILL, SGA, IAC, DO, SGA]))
    send(b"Escale Telnet test\r\nBienvenue sur le serveur de recette.\r\nlogin: ")
    state, verb, sb, line = "data", 0, bytearray(), bytearray()
    after_cr = False
    closing = False
    try:
        while not closing:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data = bytearray()
            for b in chunk:
                if state == "data":
                    if b == IAC:
                        state = "iac"
                    else:
                        data.append(b)
                elif state == "iac":
                    if b == IAC:
                        data.append(IAC); state = "data"
                    elif b in (WILL, WONT, DO, DONT):
                        verb = b; state = "verb"
                    elif b == SB:
                        sb = bytearray(); state = "sb"
                    else:
                        state = "data"
                elif state == "verb":
                    name = {WILL: "WILL", WONT: "WONT", DO: "DO", DONT: "DONT"}[verb]
                    log(f"{name} {b}")
                    if verb == WILL and b == TTYPE:
                        send(bytes([IAC, SB, TTYPE, 1, IAC, SE]))
                    state = "data"
                elif state == "sb":
                    if b == IAC:
                        state = "sbiac"
                    else:
                        sb.append(b)
                elif state == "sbiac":
                    if b == IAC:
                        sb.append(IAC); state = "sb"
                    elif b == SE:
                        if sb and sb[0] == TTYPE and len(sb) > 1 and sb[1] == 0:
                            log("TTYPE " + sb[2:].decode("ascii", "replace"))
                        elif sb and sb[0] == NAWS and len(sb) == 5:
                            log(f"NAWS {sb[1] * 256 + sb[2]}x{sb[3] * 256 + sb[4]}")
                        state = "data"
                    else:
                        state = "data"
            if data:
                log("DATA " + data.hex())
            out = bytearray()
            for b in data:
                if after_cr:
                    after_cr = False
                    if b in (0, 10):
                        continue
                if b == 13:
                    after_cr = True
                    text = line.decode("latin-1")
                    line.clear()
                    if text == "bye":
                        out += b"\r\nAu revoir\r\n"; closing = True; break
                    out += ("\r\nRecu: " + text + "\r\nlogin: ").encode("latin-1")
                elif 32 <= b < 127:
                    line.append(b); out.append(b)  # écho côté serveur
            if out:
                send(bytes(out))
    except OSError:
        pass
    finally:
        log("CLOSE")
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        conn.close()


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
open(args.port_file, "w").write(str(srv.getsockname()[1]))
count = 0
while True:
    c, _ = srv.accept()
    count += 1
    threading.Thread(target=serve, args=(c, count), daemon=True).start()
