#!/usr/bin/env python3
"""极简上游 DNS mock：*.upstream.test → A 记录，其余 NXDOMAIN。"""
import socket
import struct
import sys


def main():
    port = int(sys.argv[1])
    answer = sys.argv[2] if len(sys.argv) > 2 else "203.0.113.9"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", port))
    while True:
        data, addr = sock.recvfrom(4096)
        if len(data) < 12:
            continue
        off = 12
        labels = []
        while data[off] != 0:
            ln = data[off]
            labels.append(data[off + 1:off + 1 + ln].decode(errors="replace"))
            off += 1 + ln
        off += 1
        question = data[12:off + 4]
        qname = ".".join(labels)
        qid = data[:2]
        if qname.endswith("upstream.test"):
            flags, ancount = 0x8180, 1
            ans = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton(answer)
        else:
            flags, ancount, ans = 0x8183, 0, b""
        resp = qid + struct.pack("!HHHHH", flags, 1, ancount, 0, 0) + question + ans
        sock.sendto(resp, addr)


if __name__ == "__main__":
    main()
