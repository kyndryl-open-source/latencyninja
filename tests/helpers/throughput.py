#!/usr/bin/env python3
"""Print TCP throughput in Mbit/s to or from a test listener.

Usage: throughput.py HOST upload|download [SECONDS]

upload sends to the sink on port 5001, download reads from the source on port 5002.
The first second is skipped to leave TCP slow start out of the measurement. Uploads use a
small send buffer so that bytes counted as sent closely track bytes actually delivered.
"""
import socket
import sys
import time

host, mode = sys.argv[1], sys.argv[2]
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 4
warmup = 1.0
chunk = b"\0" * 16384

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    if mode == "upload":
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 16384)
    s.settimeout(5)
    s.connect((host, 5001 if mode == "upload" else 5002))
    start = time.monotonic()
    counted = 0
    measure_start = None
    while True:
        now = time.monotonic()
        if now - start >= warmup + seconds:
            break
        n = s.send(chunk) if mode == "upload" else len(s.recv(65536))
        if now - start >= warmup:
            if measure_start is None:
                measure_start = now
            counted += n
    elapsed = time.monotonic() - measure_start if measure_start else 0
print(f"{counted * 8 / elapsed / 1e6:.2f}" if elapsed else "0")
