#!/usr/bin/env python3
"""从 roles/*/defaults/main.yml 生成 docs/variables.md（T016）。

用法:
  scripts/gen_vars_doc.py            # 重新生成 docs/variables.md
  scripts/gen_vars_doc.py --check    # 只校验：文档与 defaults 一致且覆盖全部 key
  scripts/gen_vars_doc.py --list     # 只打印 key（供测试断言）

「说明」列取自 defaults 中紧邻该 key 上方的注释块（没有就是 `-`）。
生成物必须提交，`--check` 在 full_flow.sh 静态段执行，防止文档与 defaults 漂移。
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "variables.md")
KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$")


def collect(path):
    rows, comments = [], []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.lstrip().startswith("#"):
                body = line.lstrip().lstrip("#").strip()
                if set(body) <= {"="} or body.startswith("---"):
                    comments = []
                else:
                    comments.append(body)
                continue
            if not line.strip():
                comments = []
                continue
            m = KEY_RE.match(line)
            if m:
                value = m.group(2).strip()
                if not value:
                    value = "（映射/列表，见 defaults）"
                elif value in (">-", "|", ">", "|-"):
                    value = "（多行，见 defaults）"
                rows.append((m.group(1), value, " ".join(comments) or "-"))
                comments = []
            else:
                comments = []
    return rows


def build():
    out = [
        "# 可配置项总表（由 `scripts/gen_vars_doc.py` 从 role defaults 生成）",
        "",
        "> 不是手写清单：`make test-e2e-full` 会执行 `scripts/gen_vars_doc.py --check`，",
        "> 任何 defaults 变更未同步到本文档都会让门禁变红。覆盖优先级：",
        "> `-e` / host_vars > group_vars > role defaults。",
        "",
        "| 变量 | 默认值 | 说明（来自 defaults 注释） |",
        "| --- | --- | --- |",
    ]
    total = 0
    for path in sorted(glob.glob(os.path.join(ROOT, "roles", "*", "defaults", "main.yml"))):
        role = os.path.basename(os.path.dirname(os.path.dirname(path)))
        rows = collect(path)
        total += len(rows)
        out.append(f"| **role: {role}** | | |")
        for key, value, comment in rows:
            esc = lambda s: s.replace("|", "\\|")
            out.append(f"| `{key}` | `{esc(value)}` | {esc(comment)} |")
    out.append("")
    out.append(f"共 **{total}** 个默认变量。")
    out.append("")
    return "\n".join(out), total


def main():
    text, total = build()
    if "--list" in sys.argv:
        for line in text.splitlines():
            m = re.match(r"^\| `([a-z0-9_]+)` \|", line)
            if m:
                print(m.group(1))
        return 0
    if "--check" in sys.argv:
        try:
            with open(OUT, encoding="utf-8") as fh:
                current = fh.read()
        except FileNotFoundError:
            print("docs/variables.md 缺失", file=sys.stderr)
            return 1
        if current != text:
            print("docs/variables.md 与 defaults 不一致（请运行 scripts/gen_vars_doc.py）", file=sys.stderr)
            return 1
        print(f"docs/variables.md 一致（{total} 个变量）")
        return 0
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"已生成 {OUT}（{total} 个变量）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
