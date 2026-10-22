#!/usr/bin/env bash
# =============================================================================
# 获取 haproxy / keepalived 二进制（仅解包到 /tmp/opencode/t006root，不安装 RPM）
#   本仓库的测试环境不把这两个包装进系统；测试只使用解包后的二进制：
#     HAPROXY_BIN=/tmp/opencode/t006root/usr/sbin/haproxy
#     KEEPALIVED_BIN=/tmp/opencode/t006root/usr/sbin/keepalived
#     LD_LIBRARY_PATH=/tmp/opencode/t006root/usr/lib64:/tmp/opencode/t006root/usr/lib64/mariadb
#   用法: tests/ha/provision_bins.sh [目标前缀]
#   依赖: dnf（或 curl）+ rpm2cpio + cpio。不会执行 rpm -i、不会写 /etc。
# =============================================================================
set -euo pipefail

PREFIX="${1:-/tmp/opencode/t006root}"
CACHE="${T006_RPM_CACHE:-/tmp/opencode/t006-rpms}"
mkdir -p "$PREFIX" "$CACHE"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少依赖: $1" >&2; exit 2; }; }
need rpm2cpio
need cpio

fetch() {
  local pkg="$1"
  if command -v dnf >/dev/null 2>&1; then
    echo "  dnf download $pkg"
    (cd "$CACHE" && dnf -q download "$pkg")
  else
    echo "缺少 dnf；请手动把 $pkg 的 RPM 放到 $CACHE" >&2
    exit 2
  fi
}

echo "== 下载 RPM 到 $CACHE（不安装）=="
fetch haproxy
fetch keepalived

echo "== 解包到 $PREFIX =="
for rpm in "$CACHE"/haproxy-*.rpm "$CACHE"/keepalived-*.rpm; do
  [[ -f "$rpm" ]] || { echo "未找到 RPM: $rpm" >&2; exit 1; }
  echo "  $(basename "$rpm")"
  rpm2cpio "$rpm" | (cd "$PREFIX" && cpio -idm --quiet)
done

cat <<EOF
== 完成 ==
  HAPROXY_BIN=$PREFIX/usr/sbin/haproxy
  KEEPALIVED_BIN=$PREFIX/usr/sbin/keepalived
  export LD_LIBRARY_PATH=$PREFIX/usr/lib64:$PREFIX/usr/lib64/mariadb
验证:
  \$HAPROXY_BIN -v
  \$KEEPALIVED_BIN --version
EOF
