#!/usr/bin/env python3
"""T010 Cilium 清单检查器。

用法：
  manifest.py <file> kinds
  manifest.py <file> count
  manifest.py <file> check-required [EXTRA_KIND ...]
  manifest.py <file> get-config <key>
  manifest.py <file> get <Kind> <name> <dotted.path>
  manifest.py <file> find <Kind>

`get` 的值打印：bool -> true/false，None -> null，其它 -> str。
该脚本只读，供 tests/cilium/test_cilium_role.sh 断言使用。
"""
import re
import sys

import yaml

TOKEN = re.compile(r"([^.\[\]]+)|\[(\d+)\]")


def load(path):
    with open(path, encoding="utf-8") as fh:
        return [doc for doc in yaml.safe_load_all(fh) if doc]


def find(docs, kind, name=None):
    for doc in docs:
        if doc.get("kind") != kind:
            continue
        if name is None or doc.get("metadata", {}).get("name") == name:
            return doc
    return None


def resolve(node, path):
    for key, index in TOKEN.findall(path):
        node = node[key] if key else node[int(index)]
    return node


def render(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (dict, list)):
        return yaml.safe_dump(value, default_flow_style=True).strip()
    return str(value)


def main(argv):
    if len(argv) < 3:
        print("usage: manifest.py <file> <command> ...", file=sys.stderr)
        return 2
    path, command, args = argv[1], argv[2], argv[3:]
    docs = load(path)

    if command == "count":
        print(len(docs))
        return 0

    if command == "kinds":
        for kind in sorted({doc.get("kind", "<none>") for doc in docs}):
            print(kind)
        return 0

    if command == "find":
        doc = find(docs, args[0])
        if doc is None:
            print("missing kind: %s" % args[0], file=sys.stderr)
            return 1
        print(doc.get("metadata", {}).get("name", ""))
        return 0

    if command == "check-required":
        required = ["DaemonSet", "ConfigMap", "ServiceAccount", "ClusterRole", "ClusterRoleBinding"]
        required += args
        missing = [kind for kind in required if find(docs, kind) is None]
        if missing:
            print("missing kinds: %s" % ", ".join(missing), file=sys.stderr)
            return 1
        for doc in docs:
            if not doc.get("apiVersion") or not doc.get("kind"):
                print("document without apiVersion/kind: %r" % doc, file=sys.stderr)
                return 1
            if not doc.get("metadata", {}).get("name"):
                print("document without metadata.name: kind=%s" % doc.get("kind"), file=sys.stderr)
                return 1
        print("ok")
        return 0

    if command == "get-config":
        doc = find(docs, "ConfigMap")
        if doc is None:
            print("missing ConfigMap", file=sys.stderr)
            return 1
        data = doc.get("data") or {}
        if args[0] not in data:
            print("missing ConfigMap key: %s" % args[0], file=sys.stderr)
            return 1
        print(render(data[args[0]]))
        return 0

    if command == "get":
        if len(args) != 3:
            print("usage: get <Kind> <name> <dotted.path>", file=sys.stderr)
            return 2
        doc = find(docs, args[0], args[1])
        if doc is None:
            print("missing %s/%s" % (args[0], args[1]), file=sys.stderr)
            return 1
        try:
            print(render(resolve(doc, args[2])))
        except (KeyError, IndexError, TypeError) as exc:
            print("cannot resolve %s: %s" % (args[2], exc), file=sys.stderr)
            return 1
        return 0

    print("unknown command: %s" % command, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
