#!/usr/bin/env python3
"""Print the median TCP connect time in ms to HOST:PORT over N attempts.

Usage: tcp_rtt.py HOST PORT [N]
"""
import socket
import statistics
import sys
import time

host, port = sys.argv[1], int(sys.argv[2])
count = int(sys.argv[3]) if len(sys.argv) > 3 else 10
samples = []
for _ in range(count):
    start = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=3):
            samples.append((time.perf_counter() - start) * 1000)
    except OSError:
        pass
print(f"{statistics.median(samples):.1f}" if samples else "-1")
