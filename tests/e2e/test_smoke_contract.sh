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
# T017-1/D5：缺值必须 rc=2 立即退出且不打印 RESULT（timeout 30 兜底）
for opt in --mode --image --kubeconfig; do
  check_eq "缺值 $opt → rc=2（不挂起）" 2 "$(timeout 30 "$SMOKE" "$opt" >/dev/null 2>&1; echo $?)"
  check_not "缺值 $opt 时不打印 RESULT（不进入执行）" \
    bash -c 'timeout 30 "$1" "$2" 2>/dev/null | grep -q "^RESULT="' _ "$SMOKE" "$opt"
done
check_eq "--mode --image x（值像选项）→ rc=2" 2 "$(timeout 30 "$SMOKE" --mode --image x >/dev/null 2>&1; echo $?)"
check_not "值像选项时不打印 RESULT（不进入执行）" \
  bash -c 'timeout 30 "$1" --mode --image x 2>/dev/null | grep -q "^RESULT="' _ "$SMOKE"
# T017-D5：静态模式不需要 kubeconfig，--mode real 不得强制
check_eq "--static-only --mode real（无 kubeconfig）→ rc=0" 0 \
  "$("$SMOKE" --static-only --mode real >"$OUT.staticreal" 2>&1; echo $?)"
check "static-only+real 仍 RESULT=PASS" grep -qx 'RESULT=PASS' "$OUT.staticreal"
check "--static-only 提示 real 未执行（无 kubeconfig 仍可静态检查）" \
  bash -c '! grep -qE "^FAIL +" "$1"' _ "$OUT.staticreal"

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

echo "-- D real 模式负例（stub kubectl；不连真实集群）"
STUB="$(mktemp -d /tmp/opencode/e2e-stub.XXXXXX)" || exit 1
trap 'rm -rf "$STUB"' EXIT
KC="$STUB/kubeconfig"; : >"$KC"
cat >"$STUB/kubectl" <<'EOS'
#!/usr/bin/env bash
# 假 kubectl：E2E_STUB_MODE = unreachable | empty-nodes | healthy | job-forbidden
mode="${E2E_STUB_MODE:-unreachable}"
[[ "$mode" == unreachable ]] && { echo "The connection to the server 127.0.0.1:1 was refused" >&2; exit 1; }
a=" $* "
case "$a" in
  *" get --raw /healthz "*) echo ok; exit 0 ;;
  *" get nodes -o json "*)
    if [[ "$mode" == empty-nodes ]]; then echo '{"items":[]}';
    else echo '{"items":[{"metadata":{"name":"n1"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'; fi
    exit 0 ;;
  *" get pods -o json "*) echo '{"items":[{"metadata":{"name":"p1"},"status":{"phase":"Running"}}]}'; exit 0 ;;
  *" get svc kube-dns -o name "*) echo "service/kube-dns"; exit 0 ;;
  *" create job "*) echo "Error from server (Forbidden): jobs.batch is forbidden" >&2; exit 1 ;;
  *" delete job "*|*" wait "*) exit 0 ;;
esac
exit 1
EOS
chmod +x "$STUB/kubectl"
smoke_stub() {  # <mode> → 打印 rc，日志写 $STUB/<mode>.log
  local m="$1"
  E2E_STUB_MODE="$m" KUBECTL="$STUB/kubectl" timeout 60 "$SMOKE" \
    --mode real --kubeconfig "$KC" --image busybox-test:1.36 >"$STUB/$m.log" 2>&1
  echo $?
}

check_eq "API 不可达 → rc=1" 1 "$(smoke_stub unreachable)"
check "API 不可达 → RESULT=FAIL" grep -qx 'RESULT=FAIL' "$STUB/unreachable.log"
check "API 不可达 → 显式 FAIL 且带 rc" grep -qE '^FAIL +API 不可达.*rc' "$STUB/unreachable.log"
check_not "API 不可达 → 禁止 0/0 空集 PASS" \
  grep -qE '^PASS +全部节点 Ready（0/0）' "$STUB/unreachable.log"

check_eq "节点列表为空 → rc=1" 1 "$(smoke_stub empty-nodes)"
check "节点列表为空 → RESULT=FAIL" grep -qx 'RESULT=FAIL' "$STUB/empty-nodes.log"
check "节点列表为空 → 显式 FAIL（空集不算通过）" \
  grep -qE '^FAIL +节点列表为空' "$STUB/empty-nodes.log"
check_not "节点列表为空 → 禁止 0/0 空集 PASS" \
  grep -qE '^PASS +全部节点 Ready' "$STUB/empty-nodes.log"

check_eq "Job 创建被拒 → rc=1" 1 "$(smoke_stub job-forbidden)"
check "Job 创建被拒 → RESULT=FAIL" grep -qx 'RESULT=FAIL' "$STUB/job-forbidden.log"
check "Job 创建被拒 → FAIL 集群内 DNS" grep -qE '^FAIL +集群内 DNS' "$STUB/job-forbidden.log"
check "Job 创建被拒 → 失败信息含 API 原因（Forbidden）" \
  grep -qE '^FAIL +集群内 DNS.*Forbidden' "$STUB/job-forbidden.log"
check_not "Job 创建被拒 → 不得降级 SKIP" \
  grep -qE '^SKIP +集群内 DNS' "$STUB/job-forbidden.log"
check_not "Job 创建被拒 → 不得 RESULT=PASS" grep -qx 'RESULT=PASS' "$STUB/job-forbidden.log"
rm -rf "$STUB"; trap - EXIT

echo "-- E 清理语义（T017-4：RESULT 在 cleanup 之后，失败可见）"
check "RESULT 打印在显式 cleanup 调用之后" bash -c '
  c=$(grep -nE "^cleanup( |$)" "$1" | head -1 | cut -d: -f1)
  r=$(grep -n "^printf .RESULT=" "$1" | head -1 | cut -d: -f1)
  [ -n "$c" ] && [ -n "$r" ] && [ "$r" -gt "$c" ]' _ "$SMOKE"
check "cleanup 失败路径调用 bad（计入 RESULT）" bash -c '
  awk "/^cleanup\(\)/,/^}/" "$1" | grep -q "bad \"清理失败"' _ "$SMOKE"
check "cleanup 删除后校验沙箱目录已消失（不再静默）" bash -c '
  awk "/^cleanup\(\)/,/^}/" "$1" | grep -q "沙箱目录未删除"' _ "$SMOKE"
check "保留 trap EXIT 兜底（异常退出仍清理）" grep -q '^trap cleanup EXIT' "$SMOKE"
check "cleanup 失败 → 计入 FAIL 且返回非 0（动态：sudo 故障注入）" bash -c '
  d=$(mktemp -d /tmp/opencode/e2e-cl.XXXXXX) || exit 1
  mkdir -p "$d/sb"; echo x >"$d/sb/f"
  fail=0; bad() { fail=$((fail+1)); }
  WRAPPER=(); CLEANED=0; SB="$d/sb"
  PRE_KERNEL_PANIC=""; PRE_KERNEL_PANIC_ON_OOPS=""; PRE_KUBEPODS_SLICES=""
  stop_proc() { return 0; }; cleanup_new_kubepods() { return 0; }; restore_kernel_tunables() { return 0; }
  sudo() { return 1; }
  eval "$(awk "/^cleanup\(\)/,/^}/" "$1")"
  cleanup; rc=$?
  [[ "$rc" -ne 0 && "$fail" -ge 1 && -e "$SB" ]]
  r=$?; rm -rf "$d"; exit $r' _ "$SMOKE"

echo "-- B 真实沙箱冒烟（一条命令）"
PRE_ETC_K8S="$(test -e /etc/kubernetes && echo exists || echo absent)"
s=$(date +%s)
"$SMOKE" --mode sandbox >"$OUT" 2>&1; rc=$?
e=$(date +%s)
check_eq "sandbox 冒烟 rc=0（$((e-s))s）" 0 "$rc"
check "汇总 RESULT=PASS" grep -qx 'RESULT=PASS' "$OUT"
check_eq "汇总 FAIL=0" 0 "$(awk -F= '/^FAIL=/{print $2}' "$OUT")"
check_eq "汇总 PASS=30（固化，防 SKIP 漂移）" 30 "$(awk -F= '/^PASS=/{print $2}' "$OUT")"
check_eq "汇总 SKIP=3（恰好，防 SKIP 吞检查）" 3 "$(awk -F= '/^SKIP=/{print $2}' "$OUT")"
check "SKIP 文案: 系统 Pod Running" grep -qE '^SKIP +系统 Pod Running' "$OUT"
check "SKIP 文案: 集群内 DNS（无镜像）" grep -qE '^SKIP +集群内 DNS' "$OUT"
check "SKIP 文案: 跨节点 Pod 互通" grep -qE '^SKIP +跨节点 Pod' "$OUT"
check "节点注册检查为 PASS" bash -c 'grep -qE "^PASS +节点 .* 已注册" "$1"' _ "$OUT"
check "Ready 条件检查为 PASS" bash -c 'grep -qE "^PASS +节点 Ready 条件存在" "$1"' _ "$OUT"
check "admin kubeconfig 认证为 PASS" bash -c 'grep -qE "^PASS +admin kubeconfig" "$1"' _ "$OUT"
check "CoreDNS 集群域名解析为 PASS" bash -c 'grep -qE "^PASS +DNS kubernetes.default" "$1"' _ "$OUT"
check_not "输出中无 FAIL 行" bash -c 'grep -qE "^FAIL " "$1"' _ "$OUT"

echo "-- C 清理与宿主零污染"
check "无沙箱残留目录" bash -c '! ls -d /tmp/opencode/t012.* >/dev/null 2>&1'
check "无残留进程（沙箱二进制）" bash -c '! pgrep -f "^/tmp/opencode/t012\..*/usr/local/bin/(etcd|kube-apiserver|containerd|kubelet|coredns)" >/dev/null 2>&1'
check "端口 16443/12379/20250/20248/15353 已释放" \
  bash -c '! ss -ltn 2>/dev/null | grep -qE ":(16443|12379|20250|20248|15353)[[:space:]]"'
check_eq "宿主 /etc/kubernetes 未变化" "$PRE_ETC_K8S" "$(test -e /etc/kubernetes && echo exists || echo absent)"

echo "== 汇总: PASS=$pass FAIL=$fail =="
[[ "$fail" -eq 0 ]]
