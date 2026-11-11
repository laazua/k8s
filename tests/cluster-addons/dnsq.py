#!/usr/bin/env python3
"""极简 DNS 查询器（仅 A 记录），用于无 dig 环境的验收。

用法: dnsq.py <server> <port> <name>
输出: RCODE=<n> 与每行 A=<ip>；超时退出码 2。
"""
import random
import socket
import struct
import sys


def enc_name(name):
    out = b""
    for label in name.rstrip(".").split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def dec_name(data, off):
    labels = []
    jumped = False
    start = off
    while True:
        ln = data[off]
        if ln == 0:
            off += 1
            break
        if ln & 0xC0 == 0xC0:
            ptr = ((ln & 0x3F) << 8) | data[off + 1]
            if not jumped:
                start = off + 2
            jumped = True
            off = ptr
            continue
        labels.append(data[off + 1:off + 1 + ln].decode(errors="replace"))
        off += 1 + ln
    return ".".join(labels), (start if jumped else off)


def main():
    if len(sys.argv) != 4:
        print("usage: dnsq.py <server> <port> <name>")
        return 2
    server, port, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    qid = random.randint(0, 65535)
    pkt = (
        struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
        + enc_name(name)
        + struct.pack("!HH", 1, 1)
    )
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(3)
    try:
        sock.sendto(pkt, (server, port))
        data, _ = sock.recvfrom(4096)
    except OSError:
        print("TIMEOUT")
        return 2
    rcode = data[3] & 0x0F
    print("RCODE=%d" % rcode)
    ancount = struct.unpack("!H", data[6:8])[0]
    off = 12
    _, off = dec_name(data, off)
    off += 4
    for _ in range(ancount):
        _, off = dec_name(data, off)
        rtype, _rclass, _ttl, rdlen = struct.unpack("!HHIH", data[off:off + 10])
        off += 10
        rdata = data[off:off + rdlen]
        off += rdlen
        if rtype == 1 and rdlen == 4:
            print("A=%d.%d.%d.%d" % tuple(rdata))
    return 0


if __name__ == "__main__":
    sys.exit(main())
