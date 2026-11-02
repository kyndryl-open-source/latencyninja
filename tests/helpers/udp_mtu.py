#!/usr/bin/env python3
"""Check which UDP datagram sizes get through.

Usage: udp_mtu.py recv ADDRESS PORT SECONDS     print the IP packet sizes received, sorted
       udp_mtu.py send ADDRESS PORT SIZE...     send one datagram per IP packet size (28 bytes of headers included)
"""
import socket
import sys
import time

mode, address, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    if mode == "recv":
        s.bind((address, port))
        end = time.monotonic() + float(sys.argv[4])
        sizes = set()
        while time.monotonic() < end:
            s.settimeout(max(end - time.monotonic(), 0.01))
            try:
                sizes.add(len(s.recv(70000)) + 28)
            except socket.timeout:
                break
        print(" ".join(str(n) for n in sorted(sizes)))
    else:
        for size in map(int, sys.argv[4:]):
            s.sendto(b"x" * (size - 28), (address, port))
            time.sleep(0.05)
