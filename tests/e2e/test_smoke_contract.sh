#!/usr/bin/env bash
# =============================================================================
#  T012 e2e 冒烟脚本契约验收（TDD：先红后绿）
#    A 接口/结构：文件、可执行、--help、参数校验、纯静态模式
#    B 真实沙箱冒烟：一条命令跑通控制面+节点+附加组件+DNS，输出 PASS/FAIL/SKIP 汇总
#    C 清理：进程/端口/沙箱目录/宿主 /etc/kubernetes 无残留
#  说明：镜像依赖项（系统 Pod Running、集群内 DNS、跨节点 Pod）在无镜像环境
#        必须以 SKIP 显式呈现，不得计入 PASS。
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
check_eq() { local d="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok "$d"; else bad "$d [期望=$want 实际=${got:-<空>}]"; fi; }

SMOKE=tests/e2e/smoke.sh
README=tests/e2e/README.md
OUT=/tmp/opencode/t012-smoke.log

echo "-- A1 文件与可执行"
check "存在 $SMOKE" test -f "$SMOKE"
check "存在 $README" test -f "$README"
check "$SMOKE 可执行" test -x "$SMOKE"
check "shebang 为 bash" bash -c 'head -1 "$1" | grep -qx "#!/usr/bin/env bash"' _ "$SMOKE"
check "启用 pipefail/未定义变量保护" bash -c 'grep -qE "^set -uo pipefail" "$1"' _ "$SMOKE"

echo "-- A2 接口（--help / 非法参数 / real 缺 kubeconfig）"
check_eq "--help rc=0" 0 "$("$SMOKE" --help >/dev/null 2>&1; echo $?)"
check "--help 说明 sandbox 模式" bash -c '"$1" --help 2>&1 | grep -q "sandbox"' _ "$SMOKE"
check "--help 说明 real 模式" bash -c '"$1" --help 2>&1 | grep -q "real"' _ "$SMOKE"
check_eq "未知参数 → rc=2" 2 "$("$SMOKE" --nonsense >/dev/null 2>&1; echo $?)"
check_eq "real 模式缺 --kubeconfig → rc=2" 2 "$("$SMOKE" --mode real >/dev/null 2>&1; echo $?)"

echo "-- A3 纯静态模式（秒级，无沙箱）"
s=$(date +%s)
"$SMOKE" --static-only >"$OUT.static" 2>&1; rc=$?
e=$(date +%s)
check_eq "--static-only rc=0" 0 "$rc"
check "含 RESULT=PASS" grep -qx 'RESULT=PASS' "$OUT.static"
check "含 PASS 计数且 >0" bash -c 'grep -qE "^PASS=[1-9][0-9]*" "$1"' _ "$OUT.static"
check "含 FAIL=0" grep -qx 'FAIL=0' "$OUT.static"
check "--static-only 不创建沙箱目录" bash -c '! ls -d /tmp/opencode/t012.* >/dev/null 2>&1'
printf '  （static-only 耗时 %ss）\n' "$((e-s))"

echo "-- B 真实沙箱冒烟（一条命令）"
PRE_ETC_K8S="$(test -e /etc/kubernetes && echo exists || echo absent)"
s=$(date +%s)
"$SMOKE" --mode sandbox >"$OUT" 2>&1; rc=$?
e=$(date +%s)
check_eq "sandbox 冒烟 rc=0（$((e-s))s）" 0 "$rc"
check "汇总 RESULT=PASS" grep -qx 'RESULT=PASS' "$OUT"
check_eq "汇总 FAIL=0" 0 "$(awk -F= '/^FAIL=/{print $2}' "$OUT")"
check "汇总 PASS>=15" bash -c '[ "$(awk -F= "/^PASS=/{print \$2}" "$1")" -ge 15 ]' _ "$OUT"
check "汇总 SKIP>=3（镜像依赖项显式受限）" bash -c '[ "$(awk -F= "/^SKIP=/{print \$2}" "$1")" -ge 3 ]' _ "$OUT"
check "节点注册检查为 PASS" bash -c 'grep -qE "^PASS +节点 .* 已注册" "$1"' _ "$OUT"
check "Ready 条件检查为 PASS" bash -c 'grep -qE "^PASS +节点 Ready 条件存在" "$1"' _ "$OUT"
check "admin kubeconfig 认证为 PASS" bash -c 'grep -qE "^PASS +admin kubeconfig" "$1"' _ "$OUT"
check "CoreDNS 集群域名解析为 PASS" bash -c 'grep -qE "^PASS +DNS kubernetes.default" "$1"' _ "$OUT"
check "系统 Pod 项为 SKIP（无镜像）" bash -c 'grep -qE "^SKIP +系统 Pod" "$1"' _ "$OUT"
check "跨节点 Pod 项为 SKIP（无镜像）" bash -c 'grep -qE "^SKIP +跨节点 Pod" "$1"' _ "$OUT"
check_not "输出中无 FAIL 行" bash -c 'grep -qE "^FAIL " "$1"' _ "$OUT"

echo "-- C 清理与宿主零污染"
check "无沙箱残留目录" bash -c '! ls -d /tmp/opencode/t012.* >/dev/null 2>&1'
check "无残留进程（沙箱二进制）" bash -c '! pgrep -f "^/tmp/opencode/t012\..*/usr/local/bin/(etcd|kube-apiserver|containerd|kubelet|coredns)" >/dev/null 2>&1'
check "端口 16443/12379/20250/20248/15353 已释放" \
  bash -c '! ss -ltn 2>/dev/null | grep -qE ":(16443|12379|20250|20248|15353)[[:space:]]"'
check_eq "宿主 /etc/kubernetes 未变化" "$PRE_ETC_K8S" "$(test -e /etc/kubernetes && echo exists || echo absent)"

echo "== 汇总: PASS=$pass FAIL=$fail =="
[[ "$fail" -eq 0 ]]
