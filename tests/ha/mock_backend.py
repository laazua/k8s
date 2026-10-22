#!/usr/bin/env python3
"""T006 测试用 mock TLS apiserver（仅测试资产，不进入 role）。

返回形如 ``ok backend=<id>`` 的响应，便于断言 HAProxy 的负载均衡与后端摘除。
用法:
  python3 mock_backend.py --bind 10.99.0.1 --port 16443 --cert c.pem \
      --key k.pem --id ha1 --pid-file /path/mock.pid
"""
from __future__ import annotations

import argparse
import http.server
import os
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    backend_id = "unknown"

    def do_GET(self) -> None:  # noqa: N802 (stdlib 命名)
        body = f"ok backend={self.backend_id}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        # HAProxy 的 TCP 健康检查会建立连接但不做 TLS 握手；不刷屏。
        return


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address) -> None:  # noqa: ANN001
        # 健康检查/探测连接会触发 TLS 握手异常，忽略即可。
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()

    Handler.backend_id = args.id
    httpd = Server((args.bind, args.port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    with open(args.pid_file, "w", encoding="utf-8") as fh:
        fh.write(f"{os.getpid()}\n")
    try:
        httpd.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
