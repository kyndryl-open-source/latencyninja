#!/usr/bin/env python3
"""Accept-and-close TCP listeners on the given ports (used as test targets)."""
import selectors
import socket
import sys

sel = selectors.DefaultSelector()
for port in map(int, sys.argv[1:]):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
    s.listen(128)
    s.setblocking(False)
    sel.register(s, selectors.EVENT_READ)

while True:
    for key, _ in sel.select():
        try:
            conn, _ = key.fileobj.accept()
            conn.close()
        except OSError:
            pass
