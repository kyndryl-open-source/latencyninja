#!/usr/bin/env python3
"""Test target listeners.

Usage: listener.py PORT...

Port 5001 is a sink (reads and discards data), port 5002 is a source (sends data until the
client disconnects); both are used for throughput tests. Every other port accepts and
immediately closes connections (used for TCP connect time tests).
"""
import selectors
import socket
import sys
import threading

SINK_PORT, SOURCE_PORT = 5001, 5002
CHUNK = b"\0" * 65536


def sink(conn):
    with conn:
        while conn.recv(65536):
            pass


def source(conn):
    with conn:
        try:
            while True:
                conn.sendall(CHUNK)
        except OSError:
            pass


sel = selectors.DefaultSelector()
for port in map(int, sys.argv[1:]):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
    s.listen(128)
    s.setblocking(False)
    sel.register(s, selectors.EVENT_READ, port)

while True:
    for key, _ in sel.select():
        try:
            conn, _ = key.fileobj.accept()
        except OSError:
            continue
        conn.setblocking(True)
        if key.data == SINK_PORT:
            threading.Thread(target=sink, args=(conn,), daemon=True).start()
        elif key.data == SOURCE_PORT:
            threading.Thread(target=source, args=(conn,), daemon=True).start()
        else:
            conn.close()
