#!/usr/bin/env python3
"""从 systemd unit 中提取 ExecStart 并按 shell 规则拆成 argv（每行一个参数）。

用途：测试不启动真实 systemd，而是**直接使用 role 渲染出的 unit 的 ExecStart** 拉起进程，
从而让「unit 内容正确」与「进程真的能起来」由同一份事实驱动。
"""
import re
import shlex
import sys


def main(path: str) -> int:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    match = re.search(r"^ExecStart\s*=\s*(.*?)(?=^\S|\Z)", text, re.M | re.S)
    if not match:
        print(f"no ExecStart in {path}", file=sys.stderr)
        return 2
    cmd = re.sub(r"\\\s*\n", " ", match.group(1))
    for arg in shlex.split(cmd):
        print(arg)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
