#!/usr/bin/env python3
"""Sonde exécutée SUR LE « DISTANT » par la recette X11 non fiable : lit le cookie que sshd a reçu de ssh (ligne « add »
de xauth.stdin), le range dans <proxy-cookie>, puis ouvre DISPLAY (localhost:60xx) en le présentant comme cookie MIT."""
import os, socket, sys, time
stdin_file, proxy_out = sys.argv[1], sys.argv[2]
c = [l.split()[-1] for l in open(stdin_file) if l.startswith("add")][-1]
open(proxy_out, "w").write(c)
port = 6000 + int(os.environ["DISPLAY"].split(":")[1].split(".")[0])
s = socket.create_connection(("localhost", port))
s.sendall(b"l\0\x0b\0\0\0\x12\0\x10\0\0\0MIT-MAGIC-COOKIE-1\0\0" + bytes.fromhex(c))
time.sleep(0.5)
