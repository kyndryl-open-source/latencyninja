# Small image for the lab containers: the tools you measure with, nothing of Latency Ninja itself.
# Latency Ninja runs on the host and enters the container's network namespace (--container).
FROM debian:12-slim

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        iproute2 iputils-ping curl iperf3 python3 tcpdump ca-certificates \
 && rm -rf /var/lib/apt/lists/*
