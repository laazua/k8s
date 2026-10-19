#!/usr/bin/env python3
"""T003 测试用本地 mock 服务（完全离线、可重复）。

三个服务（均绑定 127.0.0.1 的随机端口，启动后把端口写入 --ports-file 的 JSON）：

  origin : 静态文件源（--fixture-dir），用于「正常下载 / 错误 hash / 幂等」用例；
           每个请求写一行到 --origin-log。
  flaky  : 「不稳定源」——每个 path 的**首次**请求返回 503，其后返回 --flaky-fixture 内容；
           每个请求写一行（含状态码）到 --flaky-log，用于断言重试确实发生。
  proxy  : 记录型正向代理——把请求行追加到 --proxy-log，然后转发给真实目标；
           用于断言「请求确实经代理」与「no_proxy 时不走代理」。

用法: python3 mock_servers.py --fixture-dir DIR --flaky-fixture FILE \
          --ports-file PORTS.json [--origin-log F] [--flaky-log F] [--proxy-log F]
"""
import argparse
import http.client
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def log_line(path, line):
    if not path:
        return
    with open(path, "a") as fh:
        fh.write(line + "\n")


def origin_handler(fixture_dir, log_path):
    root = os.path.abspath(fixture_dir)

    class OriginHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            rel = urlsplit(self.path).path.lstrip("/")
            target = os.path.abspath(os.path.join(root, rel))
            if not target.startswith(root + os.sep) or not os.path.isfile(target):
                log_line(log_path, "ORIGIN GET %s 404" % self.path)
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            with open(target, "rb") as fh:
                body = fh.read()
            log_line(log_path, "ORIGIN GET %s 200" % self.path)
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return OriginHandler


def flaky_handler(flaky_fixture, log_path):
    with open(flaky_fixture, "rb") as fh:
        body = fh.read()
    hits = {}
    lock = threading.Lock()

    class FlakyHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            with lock:
                n = hits.get(self.path, 0) + 1
                hits[self.path] = n
            if n == 1:
                log_line(log_path, "FLAKY GET %s 503" % self.path)
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            log_line(log_path, "FLAKY GET %s 200" % self.path)
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return FlakyHandler


def proxy_handler(log_path):
    class ProxyHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            log_line(log_path, "PROXY GET %s" % self.path)
            parts = urlsplit(self.path)
            if not parts.scheme or not parts.hostname:
                self.send_response(400)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            path = parts.path + (("?" + parts.query) if parts.query else "")
            try:
                conn = http.client.HTTPConnection(
                    parts.hostname, parts.port or 80, timeout=10
                )
                conn.request("GET", path, headers={"Host": parts.netloc})
                resp = conn.getresponse()
                status, payload = resp.status, resp.read()
                conn.close()
            except Exception as exc:  # noqa: BLE001 - 记录后回 502，便于排障
                log_line(log_path, "PROXY ERROR %s %s" % (self.path, exc))
                self.send_response(502)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(status)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    return ProxyHandler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture-dir", required=True)
    parser.add_argument("--flaky-fixture", required=True)
    parser.add_argument("--ports-file", required=True)
    parser.add_argument("--origin-log")
    parser.add_argument("--flaky-log")
    parser.add_argument("--proxy-log")
    args = parser.parse_args()

    servers = {
        "origin": ThreadingHTTPServer(
            ("127.0.0.1", 0), origin_handler(args.fixture_dir, args.origin_log)
        ),
        "flaky": ThreadingHTTPServer(
            ("127.0.0.1", 0), flaky_handler(args.flaky_fixture, args.flaky_log)
        ),
        "proxy": ThreadingHTTPServer(
            ("127.0.0.1", 0), proxy_handler(args.proxy_log)
        ),
    }
    ports = {name: srv.server_address[1] for name, srv in servers.items()}
    for srv in servers.values():
        threading.Thread(target=srv.serve_forever, daemon=True).start()

    tmp = args.ports_file + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(ports, fh)
    os.replace(tmp, args.ports_file)

    threading.Event().wait()


if __name__ == "__main__":
    main()
