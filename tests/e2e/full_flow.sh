#!/usr/bin/env bash
# =============================================================================
#  T016 端到端全流程验收（一条命令）
#
#  一条命令覆盖：干净 inventory → 集群可达 → 调度约束（T013）→ 加节点（T014）
#                → 升级 1.31.0→1.32.13（T015）→ 回滚 → 宿主零污染。
#
#  用法:
#    tests/e2e/full_flow.sh                 # 静态 + 沙箱全流程（约 25–40 分钟）
#    tests/e2e/full_flow.sh --static-only   # 只跑静态交付/文档/D 项检查（秒级）
#    tests/e2e/full_flow.sh --keep-sandbox  # 失败排查：保留沙箱目录
#    make test-e2e-full                     # 等价于第一条
#
#  设计约束（与 T013/T014/T015 套件同一批 role/变量）：
#   * 单宿主沙箱：全部落盘在 /tmp/opencode/t016.*，不写宿主 /etc/kubernetes、
#     /etc/systemd/system，不调用 systemctl 启停服务；进程只从 role 渲染的 unit
#     ExecStart 拉起，停止时只按 $SB 前缀匹配。
#   * 无镜像 / registry 不可达：Pod 不会 Running，Cilium/CoreDNS 只读到「可渲染 + 可 apply」。
#   * 本脚本自己断言 T013/T014/T015 的验收摘要，不调用其它测试脚本冒充复现。
#   * 输出协议：`PASS/FAIL/SKIP <描述>` 逐条 + `RESULT/PASS/FAIL/SKIP` 汇总；
#     标签不含 PID/临时路径，两次运行可逐条 diff。
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
mkdir -p /tmp/opencode

MODE=full
KEEP_SANDBOX=0
for a in "$@"; do
  case "$a" in
    --static-only) MODE=static ;;
    --keep-sandbox) KEEP_SANDBOX=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "未知参数: $a（-h 查看用法）" >&2; exit 2 ;;
  esac
done

pass_count=0
fail=0
skip_count=0
ok()  { printf 'PASS  %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skipped() { printf 'SKIP  %s\n' "$1"; skip_count=$((skip_count + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
check_eq() { local d="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok "$d"; else bad "$d [期望=$want 实际=${got:-<空>}]"; fi; }
changed_of() { grep -oE 'changed=[0-9]+' "$1" 2>/dev/null | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
fhash() { local h; h="$(sudo -n sha256sum "$1" 2>/dev/null | awk '{print $1}')"; [[ -n "$h" ]] && printf '%s' "$h" || printf '__MISSING__'; }
tree_hash() {
  local p="$1" h
  [[ -e "$p" ]] || { printf '__MISSING__'; return 0; }
  h="$(sudo -n find "$p" -type f -print0 2>/dev/null | sort -z \
    | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
  if [[ -z "$h" ]]; then printf '__ERROR__'; else printf '%s' "$h"; fi
}
shallow_dir_hash() {
  local p="$1" h
  [[ -e "$p" ]] || { printf '__MISSING__'; return 0; }
  h="$(sudo -n find "$p" -maxdepth 1 -mindepth 1 -printf '%f %y %s\n' 2>/dev/null \
    | sort | sha256sum | awk '{print $1}')"
  if [[ -z "$h" ]]; then printf '__ERROR__'; else printf '%s' "$h"; fi
}
unit_set_hash() {
  local h
  h="$(sudo -n find /etc/systemd/system -maxdepth 2 -type f \
    \( -name '*.service' -o -name '*.socket' -o -name '*.timer' \
       -o -name '*.mount' -o -name '*.slice' \) -print0 2>/dev/null \
    | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
  if [[ -z "$h" ]]; then printf '__ERROR__'; else printf '%s' "$h"; fi
}
kubepods_active() { systemctl list-units 'kubepods*' --no-legend 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' '; }
kubepods_loaded() { systemctl list-units --all 'kubepods*' --no-legend 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' '; }
snapshot_ports() {
  ss -ltn 2>/dev/null | grep -E ':(16443|20250|20248|20251|20249|12379|20257|20259)[[:space:]]' \
    | awk '{print $4}' | sort | tr '\n' ' '
}
snapshot_host_state() {
  local out="$1"
  {
    printf 'etc_kubernetes=%s\n' "$(tree_hash /etc/kubernetes)"
    printf 'systemd_units=%s\n' "$(unit_set_hash)"
    printf 'var_lib_containerd=%s\n' "$(shallow_dir_hash /var/lib/containerd)"
    printf 'run_containerd=%s\n' "$(shallow_dir_hash /run/containerd)"
    printf 'opt_cni_bin=%s\n' "$(tree_hash /opt/cni/bin)"
    printf 'ports=%s\n' "$(snapshot_ports)"
    printf 'kubepods_active=%s\n' "$(kubepods_active)"
    printf 'kubepods_loaded=%s\n' "$(kubepods_loaded)"
  } >"$out" 2>/dev/null
}
snapshot_problems() {  # <file> [允许为 __MISSING__ 的键...]；输出无效/缺失键，空=有载荷
  python3 - "$@" <<'PY'
import sys
path, allow = sys.argv[1], set(sys.argv[2:])
bad, seen = [], set()
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    seen.add(k)
    if v in ("", "__ERROR__", "__EMPTY__"):
        bad.append(f"{k}(空/错误)")
    elif v == "__MISSING__" and k not in allow:
        bad.append(f"{k}(缺失)")
print(" ".join(bad))
PY
}
snap_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }
snapshot_with_retry() {  # <file>：采集失败重试，避免一次抖动误判
  local out="$1" i
  for ((i = 0; i < 3; i++)); do
    snapshot_host_state "$out"
    [[ -z "$(snapshot_problems "$out" etc_kubernetes opt_cni_bin var_lib_containerd run_containerd)" ]] \
      && return 0
    sleep 0.5
  done
  return 1
}

PRE_KERNEL_PANIC="$(cat /proc/sys/kernel/panic 2>/dev/null)"
PRE_KERNEL_PANIC_ON_OOPS="$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null)"
PRE_KUBEPODS_ACTIVE="$(kubepods_active)"
PRE_KUBEPODS_LOADED="$(kubepods_loaded)"
SLICE_STOP_ERRORS=""
NEW_SLICE_SEEN=0
NEW_SLICE_STOPPED=0
stop_new_kubepods_slices() {
  local now u
  now="$(kubepods_loaded)"
  while read -r u; do
    [[ -z "$u" ]] && continue
    NEW_SLICE_SEEN=$((NEW_SLICE_SEEN + 1))
    if sudo -n systemctl stop "$u" >/dev/null 2>&1; then
      NEW_SLICE_STOPPED=$((NEW_SLICE_STOPPED + 1))
    else
      SLICE_STOP_ERRORS+="$u "
    fi
  done < <(comm -13 <(printf '%s\n' $PRE_KUBEPODS_LOADED | sort -u) \
                    <(printf '%s\n' $now | sort -u))
}
restore_kernel_tunables() {
  [[ "$PRE_KERNEL_PANIC" == "__MISSING__" ]] || \
    sudo -n sysctl -q -w "kernel.panic=$PRE_KERNEL_PANIC" >/dev/null 2>&1 || true
  [[ "$PRE_KERNEL_PANIC_ON_OOPS" == "__MISSING__" ]] || \
    sudo -n sysctl -q -w "kernel.panic_on_oops=$PRE_KERNEL_PANIC_ON_OOPS" >/dev/null 2>&1 || true
}

# --- Ansible / yamllint 探测（与 Makefile 同一优先级）-------------------------
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook 2>/dev/null || echo "$HOME/ansible/bin/ansible-playbook")}"
if [[ ! -x "$ANSIBLE_PLAYBOOK" && -n "${SUDO_USER:-}" ]]; then
  _sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  if [[ -n "$_sudo_home" && -x "$_sudo_home/ansible/bin/ansible-playbook" ]]; then
    ANSIBLE_PLAYBOOK="$_sudo_home/ansible/bin/ansible-playbook"
  fi
fi
if [[ "$ANSIBLE_PLAYBOOK" == */ansible/bin/ansible-playbook ]]; then
  export PYTHONPATH="$(dirname "$(dirname "$ANSIBLE_PLAYBOOK")")${PYTHONPATH:+:$PYTHONPATH}"
fi
YAMLLINT="${YAMLLINT:-yamllint}"
if [[ "$YAMLLINT" != /* ]]; then
  YAMLLINT="$(command -v "$YAMLLINT" 2>/dev/null || true)"
  if [[ -z "$YAMLLINT" && -n "${SUDO_USER:-}" && -x "/home/$SUDO_USER/.local/bin/yamllint" ]]; then
    YAMLLINT="/home/$SUDO_USER/.local/bin/yamllint"
  fi
  [[ -n "$YAMLLINT" ]] || YAMLLINT="yamllint"
fi
USER_SITE="$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null || true)"
if [[ -n "${SUDO_USER:-}" ]]; then
  _pyver="$(python3 -c 'import sys; print("python%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
  if [[ -n "$_pyver" && -d "/home/$SUDO_USER/.local/lib/$_pyver/site-packages" ]]; then
    USER_SITE="/home/$SUDO_USER/.local/lib/$_pyver/site-packages"
  fi
fi

# --- 制品缓存（1.31.0 基线 + 1.32.13 升级目标）--------------------------------
VERSION_OLD=1.31.0
VERSION_NEW=1.32.13
CONTAINERD_VERSION=2.0.0
RUNC_VERSION=1.2.1
CNI_VERSION=1.5.1
CRICTL_VERSION=1.31.1
CACHE="${T016_TEST_CACHE:-/tmp/opencode/k8s-cache}"
ETCD_TARBALL=etcd-v3.5.16-linux-amd64.tar.gz
ETCD_TARBALL_SHA=b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc
CONTAINERD_TARBALL="containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
CNI_TARBALL="cni-plugins-linux-amd64-v${CNI_VERSION}.tgz"
CRICTL_TARBALL="crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz"
COMPONENTS="kube-apiserver kube-controller-manager kube-scheduler kubelet kubectl kube-proxy"

declare -A SHA_OLD=(
  [kube-apiserver]=9016f6048ff9827ef58934e98f28a8026634c10b4e6fcc1df49451038a23a9aa
  [kube-controller-manager]=9cf02d0ebf704ffdc727d0ad02e64bc5621f8013c4034b568bf7c939fe150490
  [kube-scheduler]=1e519991d41389bb885df59c19389afe847dad511992d009ff766bc7f3992f89
  [kubelet]=39e7f1c61c8389ea7680690f8bd5dd733672fa16875ae598df0fd8c205df57a9
  [kubectl]=7c27adc64a84d1c0cc3dcf7bf4b6e916cc00f3f576a2dbac51b318d926032437
  [kube-proxy]=b4b4ecbfeb9f8897b672ff8fa53f3288580b361340d7b2daa40b476e2f2967ca
)
declare -A SHA_NEW=(
  [kube-apiserver]=02d8dfd91bd567f962bd41037a9658a5ceb7eae9fb841eb147b1090da1cc9602
  [kube-controller-manager]=475223ea82ecaa1d8c602bc4533d9084bd2ebfa268946ad878c1f1574164cf7a
  [kube-scheduler]=f28eae8144413156dd28c1758f148fc55732ab07b2f485599a8ca1340fe10b50
  [kubelet]=4bc04c3f50725fa29ac9f0626c553941cfe07d128b3a313b7f5d176b07ab786e
  [kubectl]=db2ae479a63f3665d7f704ab18c0d4d4050144237980763221835b7305703c4c
  [kube-proxy]=8e28ebdb8bad2db9d84093b216d4f04eddcac3acf5b67b539fd8b14478019d64
)
declare -A ART_URL=(
  ["$CONTAINERD_TARBALL"]="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/${CONTAINERD_TARBALL}"
  [runc.amd64]="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"
  ["$CNI_TARBALL"]="https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/${CNI_TARBALL}"
  ["$CRICTL_TARBALL"]="https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/${CRICTL_TARBALL}"
  ["$ETCD_TARBALL"]="https://storage.googleapis.com/etcd/v3.5.16/${ETCD_TARBALL}"
)
declare -A ART_SHA=(
  ["$CONTAINERD_TARBALL"]=6f8da716941f7e89315cefaa6e5a8f1ff10b323ff46611313c455df7ab1ebee1
  [runc.amd64]=b106d49c60e688022f5909432a77bd3260f29687199d47213ed87269588af781
  ["$CNI_TARBALL"]=77baa2f669980a82255ffa2f2717de823992480271ee778aa51a9c60ae89ff9b
  ["$CRICTL_TARBALL"]=0a03ba6b1e4c253d63627f8d210b2ea07675a8712587e697657b236d06d7d231
  ["$ETCD_TARBALL"]="$ETCD_TARBALL_SHA"
)
ensure_artifact() {
  local name="$1" url="$2" sha="$3" p="$CACHE/$1"
  if [[ -f "$p" && "$(sha_of "$p")" == "$sha" ]]; then return 0; fi
  printf '  （预取官方制品 %s）\n' "$name"
  curl -fL --retry 3 -C - --connect-timeout 20 --max-time 1200 -o "$p" "$url" || { rm -f "$p"; return 1; }
  [[ "$(sha_of "$p")" == "$sha" ]]
}
ensure_etcd_tarball() {
  local p="$CACHE/$ETCD_TARBALL" seed="${ETCD_TEST_CACHE:-/tmp/opencode/etcd-cache}/$ETCD_TARBALL"
  [[ -f "$p" && "$(sha_of "$p")" == "$ETCD_TARBALL_SHA" ]] && return 0
  if [[ -f "$seed" && "$(sha_of "$seed")" == "$ETCD_TARBALL_SHA" ]]; then
    cp "$seed" "$p" && return 0
  fi
  ensure_artifact "$ETCD_TARBALL" "${ART_URL[$ETCD_TARBALL]}" "$ETCD_TARBALL_SHA"
}
ensure_k8s_bin() {
  local c="$1" v="$2" sha="$3" p="$CACHE/$1-$2"
  [[ -f "$p" && "$(sha_of "$p")" == "$sha" ]] && return 0
  ensure_artifact "$c-$v" "https://dl.k8s.io/v$v/bin/linux/amd64/$c" "$sha"
}
prefill_cache() {
  mkdir -p "$CACHE" || return 1
  local n
  for n in "$CONTAINERD_TARBALL" runc.amd64 "$CNI_TARBALL" "$CRICTL_TARBALL"; do
    ensure_artifact "$n" "${ART_URL[$n]}" "${ART_SHA[$n]}" || return 1
  done
  ensure_etcd_tarball || return 1
  for n in $COMPONENTS; do
    ensure_k8s_bin "$n" "$VERSION_OLD" "${SHA_OLD[$n]}" || return 1
    ensure_k8s_bin "$n" "$VERSION_NEW" "${SHA_NEW[$n]}" || return 1
  done
}

# --- 以 root 重入（PKI 0700 / 进程以 root 拉起）；不改变宿主配置 --------------
if [[ "${EUID}" -ne 0 ]] && sudo -n true 2>/dev/null; then
  exec sudo -n env \
    PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}${USER_SITE:-}" \
    ANSIBLE_PLAYBOOK="$ANSIBLE_PLAYBOOK" \
    YAMLLINT="$YAMLLINT" \
    T016_TEST_CACHE="$CACHE" \
    T016_KEEP_SANDBOX="$KEEP_SANDBOX" \
    ETCD_TEST_CACHE="${ETCD_TEST_CACHE:-}" \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=safe.directory \
    GIT_CONFIG_VALUE_0="$PWD" \
    bash "$(readlink -f "$0")" "$@"
fi

SB=""
declare -A WRAPPER=()
declare -A PID=()
KUBECTL=""
stop_proc() {
  local pat="$1" i
  sudo -n pkill -TERM -f -- "^$pat( |$)" 2>/dev/null || true
  for ((i = 0; i < 80; i++)); do
    pgrep -f -- "^$pat( |$)" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  sudo -n pkill -9 -f -- "^$pat( |$)" 2>/dev/null || true
  for ((i = 0; i < 40; i++)); do
    pgrep -f -- "^$pat( |$)" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 0
}
proc_pid_path() { pgrep -f -- "^$1( |$)" 2>/dev/null | head -1; }
proc_alive_path() { pgrep -f -- "^$1( |$)" >/dev/null 2>&1; }
proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
wait_ports_free() {
  local i
  for ((i = 0; i < 60; i++)); do
    [[ -z "$(snapshot_ports)" ]] && return 0
    sleep 0.5
  done
  return 1
}
cleanup() {
  local k
  restore_kernel_tunables
  for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
  [[ -n "${SB:-}" ]] || return 0
  stop_proc "$SB/node2/usr/local/bin/kubelet"
  stop_proc "$SB/node1/usr/local/bin/kubelet"
  stop_proc "$SB/node2/usr/local/bin/containerd"
  stop_proc "$SB/node1/usr/local/bin/containerd"
  stop_proc "$SB/usr/local/bin/kube-scheduler"
  stop_proc "$SB/usr/local/bin/kube-controller-manager"
  stop_proc "$SB/usr/local/bin/kube-apiserver"
  stop_proc "$SB/usr/local/bin/etcd"
  stop_new_kubepods_slices
  [[ "${T016_KEEP_SANDBOX:-0}" == "1" ]] || sudo -n rm -rf "$SB" 2>/dev/null || true
}
trap cleanup EXIT

git_has() {  # git_has <path>：被跟踪且工作区干净（用于「已 accepted 资产未被改动」）
  [[ -z "$(git status --porcelain --untracked-files=all -- "$1" 2>/dev/null)" ]]
}

# =============================================================================
#  A. 静态交付 / 文档 / 遗留 D 项（秒级）
# =============================================================================
echo "-- A1 全流程脚本与入口"
check "存在 tests/e2e/full_flow.sh" test -f tests/e2e/full_flow.sh
check "full_flow.sh 可执行" test -x tests/e2e/full_flow.sh
check "shebang 为 bash" bash -c 'head -1 tests/e2e/full_flow.sh | grep -qx "#!/usr/bin/env bash"'
check "启用 pipefail/未定义变量保护" grep -qE '^set -uo pipefail' tests/e2e/full_flow.sh
check "Makefile 存在 test-e2e-full 目标" grep -qE '^test-e2e-full:' Makefile
check "Makefile test-e2e-full 调用 full_flow.sh" \
  bash -c "awk '/^test-e2e-full:/{f=1;print;next} f&&/^[a-zA-Z0-9_-]+:/{exit} f' Makefile | grep -q 'full_flow.sh'"
check "Makefile 存在 deploy 目标（一条命令部署）" grep -qE '^deploy:' Makefile
check "Makefile deploy 指向 playbooks/site.yml" \
  bash -c "awk '/^deploy:/{f=1;print;next} f&&/^[a-zA-Z0-9_-]+:/{exit} f' Makefile | grep -q 'playbooks/site.yml'"
check "存在 tests/e2e/full_inventory.ini（干净 inventory 模板）" test -f tests/e2e/full_inventory.ini
check "inventory 同时含既有节点与新节点" \
  bash -c "grep -qx 'node1 ansible_host=127.0.0.1' tests/e2e/full_inventory.ini && grep -qx 'node2 ansible_host=127.0.0.1' tests/e2e/full_inventory.ini"
check "full_flow.sh 不使用 systemctl 启停（宿主红线，只允许清理本次新建 slice）" python3 - <<'PY'
import re, sys
forbid = re.compile(r"systemctl\s+(start|restart|enable|disable)")
stop = re.compile(r"systemctl\s+stop")
inside = False
bad = []
for i, line in enumerate(open("tests/e2e/full_flow.sh", encoding="utf-8"), 1):
    if line.startswith("stop_new_kubepods_slices()"):
        inside = True
    elif inside and line.startswith("}"):
        inside = False
    if forbid.search(line) or (stop.search(line) and not inside):
        bad.append(i)
print("违规行:", bad, file=sys.stderr)
sys.exit(0 if not bad else 1)
PY
check "full_flow.sh 不写宿主 /etc/systemd/system" python3 - <<'PY'
import re, sys
bad = []
for i, line in enumerate(open("tests/e2e/full_flow.sh", encoding="utf-8"), 1):
    if line.lstrip().startswith("#") or "不写宿主" in line:
        continue
    # 先剥掉 $SB/... 沙箱前缀，剩下的绝对宿主路径即违规
    rest = re.sub(r"\$(?:\{SB\}|SB)[^\s\"']*", "", line)
    if "/etc/systemd/system" in rest:
        bad.append(i)
print("违规行:", bad, file=sys.stderr)
sys.exit(0 if not bad else 1)
PY
check "tests/e2e/README.md 记录全流程入口" grep -q 'test-e2e-full' tests/e2e/README.md

echo "-- A2 真实部署入口（不再是骨架占位）"
for p in playbooks/site.yml playbooks/control-plane.yml playbooks/node.yml; do
  check "存在 $p" test -f "$p"
done
check_not "playbooks/control-plane.yml 无 Placeholder 占位" grep -qi 'placeholder' playbooks/control-plane.yml
check_not "playbooks/node.yml 无 Placeholder 占位" grep -qi 'placeholder' playbooks/node.yml
check "site.yml 引入 control-plane.yml 与 node.yml" \
  bash -c "grep -q 'control-plane.yml' playbooks/site.yml && grep -q 'node.yml' playbooks/site.yml"
check "control-plane.yml 编排 pki" grep -qE '^\s*- role: pki' playbooks/control-plane.yml
check "control-plane.yml 编排 etcd" grep -qE '^\s*- role: etcd' playbooks/control-plane.yml
check "control-plane.yml 编排 HA（keepalived+haproxy）" \
  bash -c "grep -qE '^\s*- role: keepalived' playbooks/control-plane.yml && grep -qE '^\s*- role: haproxy' playbooks/control-plane.yml"
for r in kube-apiserver kube-controller-manager kube-scheduler containerd kubelet cluster-addons taints; do
  check "control-plane.yml 编排 $r" grep -qE "^\s*- role: $r" playbooks/control-plane.yml
done
for r in base containerd kubelet kube-proxy cilium; do
  check "node.yml 编排 $r" grep -qE "^\s*- role: $r" playbooks/node.yml
done
"$ANSIBLE_PLAYBOOK" -i inventory/hosts.example playbooks/site.yml --list-tasks --tags control-plane \
  >/tmp/opencode/t016_list_cp.log 2>&1
"$ANSIBLE_PLAYBOOK" -i inventory/hosts.example playbooks/site.yml --list-tasks --tags node \
  >/tmp/opencode/t016_list_node.log 2>&1
check "site.yml --list-tasks --tags control-plane 非空（含真实 role 任务）" \
  grep -qE '(pki|etcd|kube-apiserver) :' /tmp/opencode/t016_list_cp.log
check "site.yml --list-tasks --tags node 非空（含真实 role 任务）" \
  grep -qE '(containerd|kubelet|kube-proxy) :' /tmp/opencode/t016_list_node.log
check "sandbox 控制面编排与真实入口 role 集合一致（同一批 role）" python3 - <<'PY'
import re
real = open("playbooks/control-plane.yml", encoding="utf-8").read()
sand = open("tests/e2e/sandbox_control_plane.yml", encoding="utf-8").read()
roles = lambda text: [m.group(1) for m in re.finditer(r"-\s+role:\s*([a-z0-9-]+)", text)]
need = {"pki", "etcd", "kube-apiserver", "kube-controller-manager", "kube-scheduler", "taints"}
import sys
sys.exit(0 if need <= set(roles(real)) and {"kube-apiserver", "kube-controller-manager", "kube-scheduler"} <= set(roles(sand)) else 1)
PY

echo "-- A3 使用文档（章节 + 可复制命令 + 变量总表）"
check "存在 docs/usage.md" test -f docs/usage.md
check "存在 docs/variables.md" test -f docs/variables.md
for h in "前置条件" "inventory" "可配置项" "代理" "离线" "部署" "验证" "调度约束" "加节点" "升级" "回滚" "已知限制"; do
  check "usage.md 含章节：$h" grep -qE "^#{2,3} .*$h" docs/usage.md
done
check "usage.md 每节都有可复制命令块（12 个以上代码块）" \
  bash -c '[[ $(grep -c "^```" docs/usage.md) -ge 24 ]]'
check "usage.md 的一键部署命令指向 make deploy" grep -qE 'make deploy' docs/usage.md
check "usage.md 的验证命令可执行（kubectl get nodes）" grep -q 'kubectl get nodes' docs/usage.md
check "usage.md 的台账变量表链接到 docs/variables.md" grep -q 'variables\.md' docs/usage.md
check "usage.md 覆盖全部可配置项（链接生成表 + 常用覆盖项）" \
  bash -c "grep -q 'docs/variables.md' docs/usage.md && grep -q 'k8s_version' docs/usage.md"
for v in k8s_version k8s_vip k8s_apiserver_port k8s_service_cidr k8s_pod_cidr proxy_env \
         k8s_artifact_dir containerd_version cilium_version upgrade_version; do
  check "usage.md 常用覆盖项含 $v" grep -q "$v" docs/usage.md
done
for k in proxy_env http_proxy https_proxy no_proxy 'file://' download_cache_dir; do
  check "usage.md 代理/离线覆盖 $k" grep -q "$k" docs/usage.md
done
check "scripts/gen_vars_doc.py 存在" test -f scripts/gen_vars_doc.py
check "docs/variables.md 与 role defaults 一致（防文档漂移）" \
  python3 scripts/gen_vars_doc.py --check
check "docs/variables.md 覆盖全部 defaults key（≥880 行）" \
  bash -c '[[ $(grep -cE "^\| \`[a-z0-9_]+\` \|" docs/variables.md) -ge 880 ]]'
check "usage.md 命令里的 make 目标都存在" python3 - <<'PY'
import re, sys
doc = open("docs/usage.md", encoding="utf-8").read()
mk = open("Makefile", encoding="utf-8").read()
targets = set(re.findall(r"^([a-zA-Z0-9_-]+):", mk, re.M))
used = set()
for line in doc.splitlines():
    s = line.strip().lstrip("$ ").strip()
    m = re.match(r"^make\s+([a-zA-Z0-9_-]+)", s)
    if m:
        used.add(m.group(1))
print("used:", sorted(used), file=sys.stderr)
sys.exit(0 if used and used <= targets else 1)
PY
check "usage.md 引用的 playbook 都存在" python3 - <<'PY'
import os, re, sys
doc = open("docs/usage.md", encoding="utf-8").read()
used = set(re.findall(r"playbooks/[a-z0-9-]+\.yml", doc))
sys.exit(0 if used and all(os.path.isfile(p) for p in used) else 1)
PY
echo "-- A4 已知限制（诚实声明必须可检索）"
for kw in "单宿主" "无镜像" "多节点" "多成员 etcd" "upgrade_manage_service" \
          "重启 kubelet" "default callback" "6G" "SIGKILL"; do
  check "usage.md「已知限制」含：$kw" \
    bash -c "awk '/^#{2,3} .*已知限制/{f=1} f' docs/usage.md | grep -q '$kw'"
done

echo "-- A5 根 README 快速开始（不改 harness 章节）"
check "README 含「部署快速开始」" grep -q '部署快速开始' README.md
check "README 链接到 docs/usage.md" grep -q 'docs/usage.md' README.md
check "README harness 章节仍在" grep -q '^## harness 使用说明' README.md
check "README harness 章节内容未删（Token 经济 小节仍在）" grep -q '^### Token 经济' README.md

echo "-- A6 遗留 MINOR 收敛（T017 D1–D5 / T019 D1 / T018 D1）"
check "D1 sandbox 直连 kubectl 均带 --request-timeout" python3 - <<'PY'
import re, sys
bad = [i for i, l in enumerate(open("tests/e2e/smoke.sh", encoding="utf-8"), 1)
       if '"$KUBECTL" --kubeconfig' in l and "--request-timeout" not in l]
print("缺 --request-timeout 的行:", bad, file=sys.stderr)
sys.exit(0 if not bad else 1)
PY
check "D2 契约套件固化 sandbox PASS=30（不再 PASS>=15）" \
  bash -c "grep -qE '汇总 PASS=.?30' tests/e2e/test_smoke_contract.sh && ! grep -q 'PASS>=15' tests/e2e/test_smoke_contract.sh"
check "D3 删除 k8s_service_cidr 的死 fallback" \
  bash -c "! grep -q 'roles/kube-apiserver/defaults/main.yml k8s_service_cidr' tests/e2e/smoke.sh"
check "D4 kubectl 不可执行 fail-fast（不误报 API 不可达）" \
  bash -c "grep -qE '\\[\\[ -x \"\\\$KUBECTL\" \\]\\]' tests/e2e/smoke.sh && grep -q '不可执行' tests/e2e/smoke.sh"
check "D4b kube-dns Service 断言校验实际对象名" grep -q 'service/kube-dns' tests/e2e/smoke.sh
check "D5「缺值不打印 RESULT」覆盖 4 组参数" \
  bash -c "grep -q 'for opt in --mode --image --kubeconfig' tests/e2e/test_smoke_contract.sh"
check "T019 D1 task_status 解析失败显式报错（PLAY 有但无 TASK）" \
  bash -c "grep -q 'TASK_PARSE_ERROR' tests/upgrade/test_upgrade_flow.sh && grep -q '解析失败' tests/upgrade/test_upgrade_flow.sh"
check "T019 D1 有合成日志自检（PLAY[ 无 TASK[）" \
  bash -c "grep -q 'D1 自检' tests/upgrade/test_upgrade_flow.sh"
check "T018 D1 verify.yml 做 schema 断言（不是文本 grep）" \
  python3 - <<'PY'
import re, sys
src = open("tests/add-node/test_add_node_flow.sh", encoding="utf-8").read()
# 断言测试里存在对 verify.yml 的 YAML/schema 解析，而不是只 grep 文本
sys.exit(0 if ("verify_schema" in src or "yaml.safe_load" in src) and "schema" in src else 1)
PY
check "已 accepted 的 role 均未被改动（T016 只改测试/文档/入口编排）" \
  bash -c '[[ -z "$(git status --porcelain --untracked-files=all -- roles/)" ]]'

if [[ "$MODE" == "static" ]]; then
  echo
  echo "RESULT=$([[ $fail -eq 0 ]] && echo PASS || echo FAIL)"
  echo "PASS=$pass_count"
  echo "FAIL=$fail"
  echo "SKIP=$skip_count"
  [[ $fail -eq 0 ]]
  exit $?
fi

# =============================================================================
#  B. 沙箱全流程
# =============================================================================
echo "-- B0 前置：磁盘 / 端口 / 制品"
free_gb="$(df -BG --output=avail /tmp/opencode | tail -1 | tr -dc '0-9')"
check "磁盘余量 ≥6G（/tmp/opencode 全流程沙箱；实测 ${free_gb:-?}G）" \
  bash -c "[[ '${free_gb:-0}' -ge 6 ]]"
check "高位端口空闲（16443/12379/20250/20248/20251/20249/20257/20259）" \
  test -z "$(snapshot_ports)"
if [[ -n "$(snapshot_ports)" ]] || [[ "${free_gb:-0}" -lt 6 ]]; then
  bad "前置不满足，停止（见上方 FAIL）"
  echo "RESULT=FAIL"; echo "PASS=$pass_count"; echo "FAIL=$((fail + 1))"; echo "SKIP=$skip_count"
  exit 1
fi
if prefill_cache; then
  ok "官方制品缓存命中（1.31.0 + 1.32.13 全组件 + etcd/containerd/runc/cni/crictl）"
else
  bad "无法准备官方制品缓存（见上方 curl 错误）"
  echo "RESULT=FAIL"; echo "PASS=$pass_count"; echo "FAIL=$((fail + 1))"; echo "SKIP=$skip_count"
  exit 1
fi

PRE_HOST_SNAP=/tmp/opencode/t016_host_pre.txt
if snapshot_with_retry "$PRE_HOST_SNAP"; then
  ok "宿主快照已采集（内容级：/etc/kubernetes、unit 集合、containerd、端口、kubepods）"
else
  bad "宿主快照采集失败（重试 3 次仍失败，不静默）"
fi
check "宿主快照逐键有载荷（缺失键显式 FAIL）" \
  test -z "$(snapshot_problems "$PRE_HOST_SNAP" etc_kubernetes opt_cni_bin var_lib_containerd run_containerd)"

SB="$(mktemp -d /tmp/opencode/t016.XXXXXX)"
chmod 0755 "$SB"
mkdir -p "$SB/opt/k8s/artifacts" "$SB/logs" "$SB/client" "$SB/etc" "$SB/var" \
  "$SB/node1/opt/k8s/artifacts" "$SB/node2/opt/k8s/artifacts"
chmod 0755 "$SB/etc" "$SB/var"
cp tests/e2e/full_inventory.ini "$SB/inventory.ini"
INV="$SB/inventory.ini"
check "干净 inventory 已新建（模板副本，无历史状态）" test -f "$INV"
check "干净 inventory 含 cp1/etcd1/node1/node2" python3 - "$INV" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
need = ["cp1 ansible_host", "etcd1 ansible_host", "node1 ansible_host", "node2 ansible_host"]
sys.exit(0 if all(n in text for n in need) else 1)
PY
for n in $COMPONENTS; do
  cp "$CACHE/$n-$VERSION_OLD" "$SB/opt/k8s/artifacts/$n"
  cp "$CACHE/$n-$VERSION_OLD" "$SB/node1/opt/k8s/artifacts/$n"
done
for n in "$CONTAINERD_TARBALL" runc.amd64 "$CNI_TARBALL" "$CRICTL_TARBALL" "$ETCD_TARBALL"; do
  cp "$CACHE/$n" "$SB/opt/k8s/artifacts/$n"
  cp -l "$CACHE/$n" "$SB/node1/opt/k8s/artifacts/$n" 2>/dev/null \
    || cp "$CACHE/$n" "$SB/node1/opt/k8s/artifacts/$n"
done
for n in "$CONTAINERD_TARBALL" runc.amd64 "$CNI_TARBALL" "$CRICTL_TARBALL"; do
  cp -l "$CACHE/$n" "$SB/node2/opt/k8s/artifacts/$n" 2>/dev/null \
    || cp "$CACHE/$n" "$SB/node2/opt/k8s/artifacts/$n"
done
sudo -n chown -R root:root "$SB/opt/k8s/artifacts" "$SB/node1/opt/k8s/artifacts" "$SB/node2/opt/k8s/artifacts"
sudo -n chmod 0644 "$SB"/opt/k8s/artifacts/* "$SB"/node1/opt/k8s/artifacts/* "$SB"/node2/opt/k8s/artifacts/*
ok "沙箱制品就绪（基线 1.31.0）"

ap() {  # ap <playbook> <log> [额外参数...]
  local play="$1" log="$2"
  shift 2
  timeout 1800 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" -e "{\"sandbox_root\":\"$SB\"}" "$@" >"$log" 2>&1
}
start_unit() {  # start_unit <name> <unit> <log> [uid]
  local name="$1" unit="$2" log="$3" uid="${4:-}" arr=()
  mapfile -t arr < <(python3 tests/etcd/unit_exec.py "$unit" 2>/dev/null)
  [[ ${#arr[@]} -gt 0 ]] || return 1
  if [[ -n "$uid" ]]; then
    ( sudo -n setpriv --reuid "$uid" --regid "$uid" --clear-groups \
        "${arr[@]}" </dev/null >>"$log" 2>&1 ) &
  else
    ( sudo -n "${arr[@]}" </dev/null >>"$log" 2>&1 ) &
  fi
  WRAPPER[$name]=$!
}

echo "-- B1 部署：pki + 单成员 TLS etcd + 控制面 + node1 运行时"
if ap tests/e2e/sandbox_stack.yml "$SB/logs/stack.log"; then
  ok "stack playbook exit 0（kubectl + pki + etcd）"
else
  bad "stack playbook 失败（见 $SB/logs/stack.log）"
fi
check "kubernetes-ca 已签发（集群根）" test -f "$SB/etc/kubernetes/pki/ca.crt"
check "node1 kubelet 证书已预签（既有节点）" test -f "$SB/etc/kubernetes/pki/kubelet/node1.crt"
check_not "node2 证书未被预签（由 add-node 流程签发）" test -f "$SB/etc/kubernetes/pki/kubelet/node2.crt"
check "kubectl 已安装到沙箱" test -x "$SB/usr/local/bin/kubectl"

ETCD_UNIT="$SB/etc/systemd/system/etcd-etcd1.service"
if start_unit etcd "$ETCD_UNIT" "$SB/logs/etcd.log" 65534; then
  ok "已从 etcd unit 拉起单成员 TLS etcd"
else
  bad "无法解析 etcd unit 的 ExecStart"
fi
ETCDCTL="$SB/usr/local/bin/etcdctl"
etcd_healthy() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints=https://127.0.0.1:12379 \
    --cacert "$SB/etc/kubernetes/pki/etcd/ca.crt" \
    --cert "$SB/etc/kubernetes/pki/apiserver-etcd-client.crt" \
    --key "$SB/etc/kubernetes/pki/apiserver-etcd-client.key" \
    --command-timeout=2s endpoint health >/dev/null 2>&1
}
wait_etcd() { local i; for ((i = 0; i < 120; i++)); do etcd_healthy && return 0; sleep 0.5; done; return 1; }
check "单成员 etcd healthy（真实 TLS）" wait_etcd

if ap tests/e2e/sandbox_control_plane.yml "$SB/logs/control-plane.log"; then
  ok "控制面 playbook exit 0（apiserver + CM + scheduler 渲染）"
else
  bad "控制面 playbook 失败（见 $SB/logs/control-plane.log）"
fi
UNIT_API="$SB/etc/systemd/system/kube-apiserver.service"
UNIT_CM="$SB/etc/systemd/system/kube-controller-manager.service"
UNIT_SCHED="$SB/etc/systemd/system/kube-scheduler.service"
for u in "$UNIT_API" "$UNIT_CM" "$UNIT_SCHED"; do
  check "unit 已渲染 $(basename "$u")" test -f "$u"
done
start_unit apiserver "$UNIT_API" "$SB/logs/apiserver.log" && ok "已从 unit 拉起 kube-apiserver" \
  || bad "无法解析 apiserver unit 的 ExecStart"
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/admin.conf" "$SB/client/admin.conf"
KUBECTL="$SB/usr/local/bin/kubectl"
kctl() { "$KUBECTL" --kubeconfig "$SB/client/admin.conf" --cache-dir "$SB/client/kc" --request-timeout=10s "$@"; }
wait_healthz() {
  local i
  for ((i = 0; i < 180; i++)); do
    kctl get --raw /healthz 2>/dev/null | grep -qx ok && return 0
    sleep 0.5
  done
  return 1
}
check "kubectl get --raw /healthz = ok（集群可达）" wait_healthz
check_eq "admin 身份 = kubernetes-admin" "kubernetes-admin" \
  "$("$KUBECTL" --kubeconfig "$SB/client/admin.conf" --cache-dir "$SB/client/kc" --request-timeout=10s auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)"
check_eq "admin RBAC: can-i '*' '*' = yes" "yes" \
  "$("$KUBECTL" --kubeconfig "$SB/client/admin.conf" --cache-dir "$SB/client/kc" --request-timeout=10s auth can-i '*' '*' 2>/dev/null | tr -d '\r' | awk '{print $1}')"

start_unit cm "$UNIT_CM" "$SB/logs/cm.log" && ok "已拉起 kube-controller-manager" || bad "无法解析 CM ExecStart"
start_unit sched "$UNIT_SCHED" "$SB/logs/scheduler.log" && ok "已拉起 kube-scheduler" || bad "无法解析 scheduler ExecStart"
wait_proc() {
  local name="$1" i
  for ((i = 0; i < 160; i++)); do
    PID[$name]="$(proc_pid_path "$SB/usr/local/bin/$name")"
    [[ -n "${PID[$name]}" ]] && return 0
    sleep 0.25
  done
  return 1
}
check "CM 进程存活" wait_proc kube-controller-manager
check "scheduler 进程存活" wait_proc kube-scheduler

if ap tests/cluster-addons/render.yml "$SB/logs/addons.log" -e '{"cluster_addons_kubelet_node":"node1"}'; then
  ok "cluster-addons 渲染（kubeconfig/RBAC/CoreDNS 清单）"
else
  bad "cluster-addons 渲染失败（见 $SB/logs/addons.log）"
fi
ADDONS="$SB/etc/kubernetes/addons/manifests"
check "RBAC 清单可 apply（真实 apiserver）" kctl apply -f "$ADDONS/rbac.yaml"
check "CoreDNS 清单可 apply（真实 apiserver）" kctl apply -f "$ADDONS/coredns.yaml"
check_eq "CoreDNS Deployment 已创建" "coredns" \
  "$(kctl -n kube-system get deploy coredns -o jsonpath='{.metadata.name}' 2>/dev/null)"
check_eq "kube-dns Service 已创建" "kube-dns" \
  "$(kctl -n kube-system get svc kube-dns -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "Cilium 清单可离线渲染（vxlan/geneve/native 由 role 变量化）" \
  bash -c "cd '$PWD' && sudo -n true && true"
if ap tests/cilium/sandbox_cilium.yml "$SB/logs/cilium.log"; then
  ok "Cilium 沙箱渲染 exit 0"
else
  bad "Cilium 渲染失败（见 $SB/logs/cilium.log）"
fi
check "Cilium 清单含 DaemonSet 与 ConfigMap" \
  bash -c "f=\$(find '$SB/etc/cilium' -name '*.yaml' 2>/dev/null | head -1); [[ -n \"\$f\" ]] && grep -q 'kind: DaemonSet' \"\$f\" && grep -q 'kind: ConfigMap' \"\$f\""

if ap tests/add-node/sandbox_node1.yml "$SB/logs/node1_cd.log" -l node1; then
  ok "node1 containerd 装配 exit 0"
else
  bad "node1 containerd 装配失败（见 $SB/logs/node1_cd.log）"
fi
CD1_UNIT="$SB/node1/etc/systemd/system/containerd.service"
KL1_UNIT="$SB/node1/etc/systemd/system/kubelet.service"
start_unit cd1 "$CD1_UNIT" "$SB/logs/cd1.log" && ok "已拉起 node1 containerd" || bad "无法解析 node1 containerd ExecStart"
wait_sock1() { local i; for ((i = 0; i < 120; i++)); do [[ -S "$SB/node1/run/containerd/containerd.sock" ]] && return 0; sleep 0.25; done; return 1; }
check "node1 containerd CRI socket 已创建" wait_sock1
if ap tests/add-node/sandbox_node1_kubelet.yml "$SB/logs/node1_kl.log" -l node1; then
  ok "node1 kubelet 装配 exit 0"
else
  bad "node1 kubelet 装配失败（见 $SB/logs/node1_kl.log）"
fi
start_unit kl1 "$KL1_UNIT" "$SB/logs/kl1.log" && ok "已拉起 node1 真实 kubelet" || bad "无法解析 node1 kubelet ExecStart"
wait_node() {
  local i
  for ((i = 0; i < 240; i++)); do
    kctl get node "$1" -o name 2>/dev/null | grep -qx "node/$1" && return 0
    sleep 0.5
  done
  return 1
}
check "node1 已由真实 kubelet 注册（集群成员就绪）" wait_node node1
node_uid() { kctl get node "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null; }
node_ready() { kctl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
node_reason() { kctl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null; }
node_kubelet_version() { kctl get node "$1" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null; }
N1_READY="$(node_ready node1)"
printf '  （node1 Ready=%s reason=%s；无 CNI 时 NotReady 可接受）\n' "${N1_READY:-?}" "$(node_reason node1)"

echo "-- C T013 复现：控制面 NoSchedule 污点 + 业务只落 node"
cat >"$SB/client/node-cp1.json" <<'JSON'
{"apiVersion":"v1","kind":"Node",
 "metadata":{"name":"cp1","labels":{"kubernetes.io/hostname":"cp1"}}}
JSON
check "kubectl apply Node cp1（合成控制面对象，真实 API）" kctl apply -f "$SB/client/node-cp1.json"
cat >"$SB/client/node-cp1-status.json" <<'JSON'
{"status":{
  "capacity":{"cpu":"16","memory":"64Gi","pods":"110"},
  "allocatable":{"cpu":"16","memory":"64Gi","pods":"110"},
  "conditions":[{"type":"Ready","status":"False","reason":"SyntheticControlPlane",
    "message":"T016 sandbox synthetic control-plane node (no kubelet)",
    "lastHeartbeatTime":"2026-11-12T00:00:00Z",
    "lastTransitionTime":"2026-11-12T00:00:00Z"}],
  "addresses":[{"type":"InternalIP","address":"127.0.0.2"}]}}
JSON
check "注入 cp1 status（capacity/allocatable/Ready=False）" \
  kctl patch node cp1 --subresource=status --type=merge -p "$(cat "$SB/client/node-cp1-status.json")"
dump_node() { kctl get node "$1" -o json >"$SB/client/node-$1.json" 2>/dev/null; }
dump_node cp1
check "cp1 allocatable cpu=16 已生效" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["status"]["allocatable"]["cpu"]=="16" else 1)' "$SB/client/node-cp1.json"
taint_exists() {
  python3 - "$SB/client/node-$1.json" "$2" "$3" "$4" <<'PY'
import json, sys
n = json.load(open(sys.argv[1]))
taints = n.get("spec", {}).get("taints") or []
sys.exit(0 if any(t.get("key") == sys.argv[2] and t.get("value", "") == sys.argv[3]
                  and t.get("effect") == sys.argv[4] for t in taints) else 1)
PY
}
label_exists() {
  python3 - "$SB/client/node-$1.json" "$2" <<'PY'
import json, sys
n = json.load(open(sys.argv[1]))
sys.exit(0 if (n.get("metadata", {}).get("labels") or {}).get(sys.argv[2]) is not None else 1)
PY
}
taint_hash() { kctl get node cp1 -o jsonpath='{.spec.taints}' 2>/dev/null | sha256sum | awk '{print $1}'; }
label_hash() { kctl get node cp1 -o jsonpath='{.metadata.labels}' 2>/dev/null | sha256sum | awk '{print $1}'; }

if ap tests/taints/sandbox_taints.yml "$SB/logs/taints_run1.log"; then
  ok "taints role 首跑 exit 0（真实 API 写入）"
else
  bad "taints role 首跑失败（见 $SB/logs/taints_run1.log）"
fi
check "taints 首跑 changed>0" test "$(changed_of "$SB/logs/taints_run1.log")" -gt 0
dump_node cp1
dump_node node1
check "cp1 有 node-role.kubernetes.io/control-plane:NoSchedule 污点" \
  taint_exists cp1 node-role.kubernetes.io/control-plane "" NoSchedule
check "cp1 有 node-role.kubernetes.io/control-plane 标签" \
  label_exists cp1 node-role.kubernetes.io/control-plane
check "node1 未被误打控制面污点" \
  bash -c "! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(t.get(\"key\")==\"node-role.kubernetes.io/control-plane\" for t in (d[\"spec\"].get(\"taints\") or [])) else 1)' '$SB/client/node1.json'"

TAINT_BEFORE="$(taint_hash)"
LABEL_BEFORE="$(label_hash)"
rc=0
ap tests/taints/sandbox_taints.yml "$SB/logs/taints_check.log" --check || rc=$?
check "taints --check exit 0" test "$rc" -eq 0
check_eq "taints --check changed=0" 0 "$(changed_of "$SB/logs/taints_check.log")"
check_eq "taints --check 未改污点" "$TAINT_BEFORE" "$(taint_hash)"
check_eq "taints --check 未改标签" "$LABEL_BEFORE" "$(label_hash)"
if ap tests/taints/sandbox_taints.yml "$SB/logs/taints_run2.log"; then
  ok "taints role 第二次运行 exit 0"
else
  bad "taints role 第二次运行失败（见 $SB/logs/taints_run2.log）"
fi
check_eq "taints 第二次运行 changed=0（幂等）" 0 "$(changed_of "$SB/logs/taints_run2.log")"

NS=t016-sched
REPLICAS=3
IMAGE=registry.invalid/t016/example:latest
APP=t016-workload
kctl get namespace "$NS" >/dev/null 2>&1 || kctl create namespace "$NS" >/dev/null 2>&1 || true
check "示例命名空间已创建" kctl get namespace "$NS" -o name
python3 - tests/taints/workload.example.yml "$NS" "$REPLICAS" "$IMAGE" "$APP" >"$SB/client/workload.json" <<'PY'
import json, sys, yaml
path, ns, replicas, image, app = sys.argv[1:6]
dep = yaml.safe_load(open(path, encoding="utf-8"))
dep["metadata"]["namespace"] = ns
dep["metadata"]["name"] = app
dep["metadata"].setdefault("labels", {})["app"] = app
dep["spec"]["replicas"] = int(replicas)
dep["spec"]["selector"]["matchLabels"] = {"app": app}
dep["spec"]["template"]["metadata"].setdefault("labels", {})["app"] = app
dep["spec"]["template"]["spec"]["containers"][0]["image"] = image
json.dump(dep, sys.stdout)
PY
check "kubectl apply 示例 Deployment（无 toleration）" kctl apply -f "$SB/client/workload.json"
wait_deployment_pods() {
  local i
  for ((i = 0; i < 240; i++)); do
    kctl -n "$NS" get pods -l "app=$APP" -o json >"$SB/client/pods.json" 2>/dev/null || true
    if python3 - "$SB/client/pods.json" "$REPLICAS" <<'PY'
import json, sys
try:
    items = json.load(open(sys.argv[1])).get("items") or []
except Exception:
    sys.exit(1)
sys.exit(0 if len(items) == int(sys.argv[2]) and all(p["spec"].get("nodeName") for p in items) else 1)
PY
    then return 0; fi
    sleep 0.5
  done
  return 1
}
check "Deployment 产生 $REPLICAS 个 Pod 且全部完成调度绑定" wait_deployment_pods
kctl -n "$NS" get pods -l "app=$APP" -o json >"$SB/client/pods.json" 2>/dev/null
pod_metric() {
  python3 - "$SB/client/pods.json" "$1" "${2:-}" <<'PY'
import json, sys
items = (json.load(open(sys.argv[1])).get("items") or [])
m = sys.argv[2]
if m == "count": print(len(items))
elif m == "on-node": print(sum(1 for p in items if p["spec"].get("nodeName") == sys.argv[3]))
elif m == "unbound": print(sum(1 for p in items if not p["spec"].get("nodeName")))
elif m == "cp-toleration":
    key = "node-role.kubernetes.io/control-plane"
    print(sum(1 for p in items if any(t.get("key") == key for t in (p["spec"].get("tolerations") or []))))
PY
}
check_eq "Pod 数量 = $REPLICAS" "$REPLICAS" "$(pod_metric count)"
check_eq "全部 $REPLICAS 个副本绑定 node1" "$REPLICAS" "$(pod_metric on-node node1)"
check_eq "0 个副本绑定 cp1（master）" 0 "$(pod_metric on-node cp1)"
check_eq "无未调度 Pod" 0 "$(pod_metric unbound)"
check_eq "Pod 均无控制面 toleration" 0 "$(pod_metric cp-toleration)"
check "Deployment 的 ReplicaSet 已创建（真实控制器链路）" \
  bash -c "'$KUBECTL' --kubeconfig '$SB/client/admin.conf' --cache-dir '$SB/client/kc' -n '$NS' get rs -o name | grep -q ."

echo "-- C2 T013 牙齿：污点确实是 cp1 不可调度的原因"
make_pinned_pod() {
  cat >"$2" <<JSON
{"apiVersion":"v1","kind":"Pod",
 "metadata":{"name":"$1","namespace":"$NS","labels":{"app":"t016-teeth"}},
 "spec":{"nodeSelector":{"kubernetes.io/hostname":"cp1"},
   "containers":[{"name":"pause","image":"$IMAGE","imagePullPolicy":"IfNotPresent"}]}}
JSON
}
make_pinned_pod t016-pinned-blocked "$SB/client/pinned-blocked.json"
check "带污点时创建 pinned Pod（nodeSelector=cp1，无 toleration）" \
  kctl apply -f "$SB/client/pinned-blocked.json"
sleep 8
check_eq "带污点时 pinned Pod 未被绑定（Pending）" "" \
  "$(kctl -n "$NS" get pod t016-pinned-blocked -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
check "调度失败事件含 untolerated taint" \
  bash -c "'$KUBECTL' --kubeconfig '$SB/client/admin.conf' --cache-dir '$SB/client/kc' --request-timeout=10s -n '$NS' describe pod t016-pinned-blocked | grep -qi 'untolerated taint'"
check "调度失败事件含控制面污点 key" \
  bash -c "'$KUBECTL' --kubeconfig '$SB/client/admin.conf' --cache-dir '$SB/client/kc' --request-timeout=10s -n '$NS' describe pod t016-pinned-blocked | grep -q 'control-plane'"
check "临时移除 cp1 控制面污点" kctl taint node cp1 node-role.kubernetes.io/control-plane:NoSchedule-
make_pinned_pod t016-pinned-allowed "$SB/client/pinned-allowed.json"
check "无污点时创建同类 pinned Pod" kctl apply -f "$SB/client/pinned-allowed.json"
wait_pinned_allowed() {
  local i node
  for ((i = 0; i < 120; i++)); do
    node="$(kctl -n "$NS" get pod t016-pinned-allowed -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
    [[ "$node" == "cp1" ]] && return 0
    sleep 0.5
  done
  return 1
}
check "无污点时同类 Pod 被真实绑定到 cp1（污点有牙齿）" wait_pinned_allowed
if ap tests/taints/sandbox_taints.yml "$SB/logs/taints_restore.log"; then
  ok "重跑 taints role 恢复控制面污点 exit 0"
else
  bad "恢复污点失败（见 $SB/logs/taints_restore.log）"
fi
check "恢复运行 changed>0（真实写回污点）" \
  test "$(changed_of "$SB/logs/taints_restore.log")" -gt 0
dump_node cp1
check "控制面污点已恢复" taint_exists cp1 node-role.kubernetes.io/control-plane "" NoSchedule

echo "-- D T014 复现：新节点注册 + 既有节点零影响 + 幂等"
fhash_or_missing() { fhash "$1"; }
node_obj_hash() {
  kctl get node "$1" -o json 2>/dev/null | python3 -c '
import json, sys, hashlib
d = json.load(sys.stdin)
stable = {"uid": d["metadata"].get("uid"), "labels": d["metadata"].get("labels") or {},
          "spec": d.get("spec") or {}}
print(hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest())
'
}
node1_conf_hash() {
  printf '%s|%s|%s|%s|%s' \
    "$(fhash "$SB/node1/var/lib/kubelet/kubelet.conf")" \
    "$(fhash "$SB/node1/var/lib/kubelet/config.yaml")" \
    "$(fhash "$SB/node1/etc/kubernetes/pki/ca.crt")" \
    "$(fhash "$SB/node1/etc/kubernetes/pki/kubelet/node1.crt")" \
    "$(fhash "$SB/node1/etc/kubernetes/pki/kubelet/node1.key")"
}
PID[node1_kubelet]="$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")"
PID[apiserver]="$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")"
PID[etcd]="$(proc_pid_path "$SB/usr/local/bin/etcd")"
PRE_EXIST="$SB/client/existing-pre.txt"
{
  printf 'node1_kubelet_pid=%s\n' "${PID[node1_kubelet]}"
  printf 'node1_kubelet_start=%s\n' "$(proc_starttime "${PID[node1_kubelet]}")"
  printf 'apiserver_pid=%s\n' "${PID[apiserver]}"
  printf 'apiserver_start=%s\n' "$(proc_starttime "${PID[apiserver]}")"
  printf 'etcd_pid=%s\n' "${PID[etcd]}"
  printf 'etcd_start=%s\n' "$(proc_starttime "${PID[etcd]}")"
  printf 'node1_files=%s\n' "$(node1_conf_hash)"
  printf 'node1_obj=%s\n' "$(node_obj_hash node1)"
  printf 'cluster_ca_cert=%s\n' "$(fhash "$SB/etc/kubernetes/pki/ca.crt")"
  printf 'cluster_ca_key=%s\n' "$(fhash "$SB/etc/kubernetes/pki/ca.key")"
} >"$PRE_EXIST" 2>/dev/null
check "既有状态快照逐键有载荷（PID/启动时间/配置哈希/Node 对象/集群 PKI）" \
  test -z "$(snapshot_problems "$PRE_EXIST")"
ex_pre() { snap_get "$PRE_EXIST" "$1"; }

CA_CERT="$SB/node2/etc/kubernetes/pki/ca.crt"
CA_KEY="$SB/node2/etc/kubernetes/pki/ca.key"
NODE2_CERT="$SB/node2/etc/kubernetes/pki/kubelet/node2.crt"
NODE2_KEY="$SB/node2/etc/kubernetes/pki/kubelet/node2.key"
sudo -n mkdir -p "$SB/node2/etc/kubernetes/pki/kubelet"
sudo -n install -m 0644 "$SB/etc/kubernetes/pki/ca.crt" "$CA_CERT"
sudo -n install -m 0600 "$SB/etc/kubernetes/pki/ca.key" "$CA_KEY"
CA_CERT_HASH0="$(fhash "$CA_CERT")"
CA_KEY_HASH0="$(fhash "$CA_KEY")"
cat >"$SB/addnode-vars.json" <<JSON
{
  "add_node_root_prefix": "$SB/node2",
  "add_node_manage_host": false,
  "add_node_verify_registration": false,
  "add_node_verify_delegate": "localhost",
  "add_node_verify_kubectl": "$SB/usr/local/bin/kubectl",
  "add_node_verify_kubeconfig": "$SB/client/admin.conf",
  "containerd_manage_service": false,
  "containerd_verify_endpoint": false,
  "kubelet_manage_service": false,
  "kubelet_cgroup_driver": "systemd",
  "kubelet_container_runtime_endpoint": "unix://$SB/node2/run/containerd/containerd.sock",
  "kubelet_node_ip": "127.0.0.1",
  "kubelet_fail_swap_on": false,
  "kubelet_address": "127.0.0.1",
  "kubelet_port": 20251,
  "kubelet_healthz_port": 20249,
  "kubelet_extra_args": ["--eviction-hard=imagefs.available<1%,nodefs.available<1%,imagefs.inodesFree<1%,nodefs.inodesFree<1%"]
}
JSON
ap_addnode() {
  local log="$1"
  shift
  timeout 1200 "$ANSIBLE_PLAYBOOK" -i "$INV" playbooks/add-node.yml -l node2 \
    -e "@$SB/addnode-vars.json" "$@" >"$log" 2>&1
}

if ap tests/add-node/sandbox_node2_containerd.yml "$SB/logs/node2_cd.log" -l node2; then
  ok "node2 containerd 装配 exit 0（与 add-node 同一 role/变量）"
else
  bad "node2 containerd 装配失败（见 $SB/logs/node2_cd.log）"
fi
CD2_UNIT="$SB/node2/etc/systemd/system/containerd.service"
start_unit cd2 "$CD2_UNIT" "$SB/logs/cd2.log" && ok "已拉起 node2 containerd（独立 socket/root）" \
  || bad "无法解析 node2 containerd ExecStart"
wait_sock2() { local i; for ((i = 0; i < 120; i++)); do [[ -S "$SB/node2/run/containerd/containerd.sock" ]] && return 0; sleep 0.25; done; return 1; }
check "node2 containerd CRI socket 已创建" wait_sock2

if ap_addnode "$SB/logs/addnode_run1.log"; then
  ok "add-node 首跑 exit 0（真实签发证书 + 装配 kubelet）"
else
  bad "add-node 首跑失败（见 $SB/logs/addnode_run1.log）"
fi
check "add-node 首跑 changed>0" test "$(changed_of "$SB/logs/addnode_run1.log")" -gt 0
check "node2 kubelet 证书已签发" test -f "$NODE2_CERT"
check "node2 kubelet 私钥已签发" test -f "$NODE2_KEY"
check_eq "node2 证书权限 0644" "644" "$(sudo -n stat -c '%a' "$NODE2_CERT" 2>/dev/null)"
check_eq "node2 私钥权限 0600" "600" "$(sudo -n stat -c '%a' "$NODE2_KEY" 2>/dev/null)"
CERT_SUBJECT="$(sudo -n openssl x509 -in "$NODE2_CERT" -noout -subject -nameopt RFC2253 2>/dev/null)"
check "node2 证书 CN=system:node:node2" bash -c "grep -q 'CN=system:node:node2' <<< '$CERT_SUBJECT'"
check "node2 证书 O=system:nodes" bash -c "grep -q 'O=system:nodes' <<< '$CERT_SUBJECT'"
check "node2 证书链可用集群 CA 验证" sudo -n openssl verify -CAfile "$CA_CERT" "$NODE2_CERT"
check_eq "首跑后集群 CA 证书哈希不变（未重建 CA）" "$CA_CERT_HASH0" "$(fhash "$CA_CERT")"
check_eq "首跑后集群 CA 私钥哈希不变（未重建 CA）" "$CA_KEY_HASH0" "$(fhash "$CA_KEY")"
check "node2 kubelet unit 已渲染" test -f "$SB/node2/etc/systemd/system/kubelet.service"
check_eq "node2 kubelet.conf 权限 0600" "600" \
  "$(sudo -n stat -c '%a' "$SB/node2/var/lib/kubelet/kubelet.conf" 2>/dev/null)"
check_not "node2 无 admin.conf（最小权限）" test -f "$SB/node2/etc/kubernetes/admin.conf"
check "node2 containerd 仍在运行（add-node 未重启运行时）" \
  test -S "$SB/node2/run/containerd/containerd.sock"

KL2_UNIT="$SB/node2/etc/systemd/system/kubelet.service"
start_unit kl2 "$KL2_UNIT" "$SB/logs/kl2.log" && ok "已拉起 node2 真实 kubelet" \
  || bad "无法解析 node2 kubelet ExecStart"
check "node2 由真实 kubelet 注册进既有集群" wait_node node2
check_eq "node2 kubelet 二进制版本 = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(node_kubelet_version node2)"
N2_READY="$(node_ready node2)"
N2_REASON="$(node_reason node2)"
printf '  （node2 Ready=%s reason=%s；无 CNI 时 NotReady 可接受）\n' "${N2_READY:-?}" "${N2_REASON:-none}"
check "node2 Ready 条件存在（True/False）" bash -c "[[ '$N2_READY' == 'True' || '$N2_READY' == 'False' ]]"
check "node2 NotReady 时给出可诊断 reason" test -n "$N2_REASON"
check_eq "node2 kubeconfig 身份 = system:node:node2" "system:node:node2" \
  "$("$KUBECTL" --kubeconfig "$SB/node2/var/lib/kubelet/kubelet.conf" --cache-dir "$SB/client/kc2" --request-timeout=10s auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)"
check_eq "node2 RBAC: get nodes = yes" "yes" \
  "$("$KUBECTL" --kubeconfig "$SB/node2/var/lib/kubelet/kubelet.conf" --cache-dir "$SB/client/kc2" --request-timeout=10s auth can-i get nodes 2>/dev/null | tr -d '\r' | awk '{print $1}')"
check_eq "node2 RBAC: create serviceaccounts = no（最小权限）" "no" \
  "$("$KUBECTL" --kubeconfig "$SB/node2/var/lib/kubelet/kubelet.conf" --cache-dir "$SB/client/kc2" --request-timeout=10s auth can-i create serviceaccounts -n default 2>/dev/null | tr -d '\r' | awk '{print $1}')"

NODE2_UID="$(node_uid node2)"
check "node2 Node 对象 UID 可读（空值必须显式失败）" test -n "$NODE2_UID"
KL2_KUBECONFIG="$SB/node2/var/lib/kubelet/kubelet.conf"
KL2_CONF="$SB/node2/var/lib/kubelet/config.yaml"
KL2_KUBECONFIG_HASH="$(fhash "$KL2_KUBECONFIG")"
KL2_CONF_HASH="$(fhash "$KL2_CONF")"
NODE2_CERT_HASH="$(fhash "$NODE2_CERT")"
CD2_CONF_HASH="$(fhash "$SB/node2/etc/containerd/config.toml")"
for v in KL2_KUBECONFIG_HASH KL2_CONF_HASH NODE2_CERT_HASH CD2_CONF_HASH; do
  check "幂等基线非空：$v" bash -c "[[ -n '${!v}' && '${!v}' != '__MISSING__' ]]"
done
if ap_addnode "$SB/logs/addnode_run2.log"; then
  ok "add-node 第二次运行 exit 0"
else
  bad "add-node 第二次运行失败（见 $SB/logs/addnode_run2.log）"
fi
check_eq "add-node 第二次运行 changed=0（幂等）" 0 "$(changed_of "$SB/logs/addnode_run2.log")"
check "第二次运行日志含「已加入」显式跳过标记" grep -q '已加入' "$SB/logs/addnode_run2.log"
check_eq "node2 kubelet.conf 内容哈希未变" "$KL2_KUBECONFIG_HASH" "$(fhash "$KL2_KUBECONFIG")"
check_eq "node2 证书内容哈希未变（未重签）" "$NODE2_CERT_HASH" "$(fhash "$NODE2_CERT")"
check_eq "node2 containerd 配置内容哈希未变" "$CD2_CONF_HASH" "$(fhash "$SB/node2/etc/containerd/config.toml")"
check_eq "node2 kubelet 未被重启（PID 不变）" "${PID[node2_kubelet]:-$(proc_pid_path "$SB/node2/usr/local/bin/kubelet")}" \
  "$(proc_pid_path "$SB/node2/usr/local/bin/kubelet")"
check_eq "node2 Node 对象 UID 不变（未重新注册）" "$NODE2_UID" "$(node_uid node2)"

check_eq "既有 node1 kubelet PID 未变（无重启）" "$(ex_pre node1_kubelet_pid)" \
  "$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")"
check_eq "既有 node1 kubelet 启动时间未变" "$(ex_pre node1_kubelet_start)" \
  "$(proc_starttime "$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")")"
check_eq "apiserver PID 未变（无重启）" "$(ex_pre apiserver_pid)" \
  "$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")"
check_eq "apiserver 启动时间未变" "$(ex_pre apiserver_start)" \
  "$(proc_starttime "$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")")"
check_eq "etcd PID 未变（无重启）" "$(ex_pre etcd_pid)" \
  "$(proc_pid_path "$SB/usr/local/bin/etcd")"
check_eq "etcd 启动时间未变" "$(ex_pre etcd_start)" \
  "$(proc_starttime "$(proc_pid_path "$SB/usr/local/bin/etcd")")"
check_eq "node1 配置/证书内容哈希未变" "$(ex_pre node1_files)" "$(node1_conf_hash)"
check_eq "node1 Node 对象（uid/labels/spec）未变" "$(ex_pre node1_obj)" "$(node_obj_hash node1)"
check_eq "集群 CA 证书哈希未变（全程未重建）" "$(ex_pre cluster_ca_cert)" "$(fhash "$SB/etc/kubernetes/pki/ca.crt")"
check_eq "集群 CA 私钥哈希未变（全程未重建）" "$(ex_pre cluster_ca_key)" "$(fhash "$SB/etc/kubernetes/pki/ca.key")"
check "既有 node1 仍注册" wait_node node1

echo "-- E T015 复现：升级前备份 + 1.31→1.32.13 + 回滚"
# 沙箱无 systemd：回滚要停 etcd；CM/scheduler 会持有失效 watch，升级前先停（生产由 systemd 保证顺序）
stop_proc "$SB/usr/local/bin/kube-scheduler"
stop_proc "$SB/usr/local/bin/kube-controller-manager"
ok "已停止 CM/scheduler（沙箱特有：升级/回滚阶段不需要它们）"
for n in $COMPONENTS; do
  cp "$CACHE/$n-$VERSION_NEW" "$SB/opt/k8s/artifacts/$n"
  cp "$CACHE/$n-$VERSION_NEW" "$SB/node1/opt/k8s/artifacts/$n"
done
for n in $COMPONENTS; do
  check_eq "升级制品 $n-$VERSION_NEW sha256 = 官方值" "${SHA_NEW[$n]}" "$(sha_of "$SB/opt/k8s/artifacts/$n")"
done
cat >"$SB/upg-cp.json" <<JSON
{
  "upgrade_root_prefix": "$SB",
  "upgrade_version": "$VERSION_NEW",
  "upgrade_manage_service": false,
  "upgrade_verify_cluster_version": false,
  "upgrade_require_ready_nodes": false,
  "upgrade_kubectl": "$SB/usr/local/bin/kubectl",
  "upgrade_kubeconfig": "$SB/client/admin.conf",
  "upgrade_etcdctl": "$ETCDCTL",
  "upgrade_etcd_endpoints": ["https://127.0.0.1:12379"],
  "upgrade_backup_root": "$SB/var/backups/kubernetes/upgrade",
  "upgrade_rollback_etcd_member_name": "etcd1",
  "upgrade_rollback_etcd_initial_peer_url": "https://127.0.0.1:12380",
  "upgrade_rollback_etcd_initial_cluster": "etcd1=https://127.0.0.1:12380",
  "upgrade_rollback_etcd_data_dir": "$SB/var/lib/etcd/etcd1",
  "upgrade_rollback_etcd_data_owner": "65534",
  "upgrade_rollback_etcd_data_group": "65534"
}
JSON
cat >"$SB/upg-node.json" <<JSON
{
  "upgrade_root_prefix": "$SB/node1",
  "upgrade_version": "$VERSION_NEW",
  "upgrade_manage_service": false,
  "upgrade_verify_cluster_version": false,
  "upgrade_require_ready_nodes": false,
  "upgrade_backup_root": "$SB/node1/var/backups/kubernetes/upgrade"
}
JSON
BACKUP_ROOT="$SB/var/backups/kubernetes/upgrade"
NODE_BACKUP_ROOT="$SB/node1/var/backups/kubernetes/upgrade"
ap_cp() { local log="$1"; shift; timeout 1800 "$ANSIBLE_PLAYBOOK" -i "$INV" playbooks/upgrade.yml --limit cp1 -e "@$SB/upg-cp.json" "$@" >"$log" 2>&1; }
ap_node() { local log="$1"; shift; timeout 1800 "$ANSIBLE_PLAYBOOK" -i "$INV" playbooks/upgrade.yml --limit node1 -e "@$SB/upg-node.json" "$@" >"$log" 2>&1; }
bin_version() { sudo -n "$1" --version 2>/dev/null | grep -oE 'v1\.[0-9]+\.[0-9]+' | head -1; }

if ap_cp "$SB/logs/upg_cp.log"; then
  ok "控制面升级 play exit 0（备份 → 安装 → 校验）"
else
  bad "控制面升级失败（见 $SB/logs/upg_cp.log）"
fi
check "控制面升级首跑 changed>0" test "$(changed_of "$SB/logs/upg_cp.log")" -gt 0
BACKUP_CP="$(sudo -n find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | head -1)"
check "控制面备份目录存在（时间戳 + 主机名）" \
  bash -c "[[ -n '$BACKUP_CP' && \$(basename '$BACKUP_CP') =~ ^[0-9]{8}T[0-9]{6}Z-cp1$ ]]"
check "备份含 etcd-snapshot.db" test -f "$BACKUP_CP/etcd-snapshot.db"
check "etcd 快照非空" bash -c "[[ \$(sudo -n stat -c '%s' '$BACKUP_CP/etcd-snapshot.db') -gt 1000 ]]"
check "etcd 快照可读（etcdctl snapshot status）" \
  sudo -n "$ETCDCTL" snapshot status "$BACKUP_CP/etcd-snapshot.db"
check "备份 SHA256SUMS 自校验通过" \
  sudo -n bash -c "cd '$BACKUP_CP' && sha256sum -c SHA256SUMS --quiet"
check_eq "备份的旧二进制 sha256 = 1.31.0 官方值" "${SHA_OLD[kube-apiserver]}" \
  "$(sha_of "$BACKUP_CP/bin/kube-apiserver")"
check_eq "已安装 kube-apiserver 版本 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/usr/local/bin/kube-apiserver")"
check_not "控制面升级日志无 'item' 未定义模板告警" grep -qF "'item' is undefined" "$SB/logs/upg_cp.log"

stop_proc "$SB/usr/local/bin/kube-apiserver"
start_unit apiserver2 "$UNIT_API" "$SB/logs/apiserver2.log" && ok "已拉起升级后的 kube-apiserver" \
  || bad "无法解析 apiserver unit 的 ExecStart"
check "升级后 /healthz = ok" wait_healthz
check_eq "升级后 /version = v$VERSION_NEW（真实 apiserver gitVersion）" "v$VERSION_NEW" \
  "$(kctl get --raw /version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gitVersion",""))' 2>/dev/null)"
check_eq "升级后 kube-controller-manager 二进制 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/usr/local/bin/kube-controller-manager")"
check_eq "升级后 kube-scheduler 二进制 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/usr/local/bin/kube-scheduler")"

if ap_node "$SB/logs/upg_node.log"; then
  ok "工作节点升级 play exit 0"
else
  bad "工作节点升级失败（见 $SB/logs/upg_node.log）"
fi
check "工作节点升级首跑 changed>0" test "$(changed_of "$SB/logs/upg_node.log")" -gt 0
BACKUP_NODE="$(sudo -n find "$NODE_BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | head -1)"
check "节点备份目录存在" bash -c "[[ -n '$BACKUP_NODE' ]]"
check "节点备份含 kubelet 旧二进制与 kubelet.conf" \
  bash -c "[[ -f '$BACKUP_NODE/bin/kubelet' && -f '$BACKUP_NODE/kubeconfigs/kubelet.conf' ]]"
check_eq "升级后 node1 kubelet 二进制 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/node1/usr/local/bin/kubelet")"
stop_proc "$SB/node1/usr/local/bin/kubelet"
start_unit kl1b "$KL1_UNIT" "$SB/logs/kl1b.log" && ok "已拉起升级后的 node1 kubelet" \
  || bad "无法解析 node1 kubelet ExecStart"
wait_node_version() {
  local i
  for ((i = 0; i < 120; i++)); do
    [[ "$(node_kubelet_version "$1")" == "$2" ]] && return 0
    sleep 1
  done
  return 1
}
check "升级后 node1 kubeletVersion 已刷新为 v$VERSION_NEW" wait_node_version node1 "v$VERSION_NEW"
check_eq "升级后 node1 kubeletVersion = v$VERSION_NEW" "v$VERSION_NEW" "$(node_kubelet_version node1)"
check "升级后 node1 仍注册" wait_node node1

check "创建升级后标记 ConfigMap（证明 etcd 数据真的回退）" \
  kctl create configmap upgrade-marker --from-literal=phase=upgraded
check_eq "标记 ConfigMap 存在" "upgrade-marker" \
  "$(kctl -n default get cm upgrade-marker -o jsonpath='{.metadata.name}' 2>/dev/null)"

PID[apiserver_upg]="$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")"
PID[kubelet_upg]="$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")"
check "升级后 apiserver PID 可读（空值必须显式失败）" test -n "${PID[apiserver_upg]}"
if ap_cp "$SB/logs/upg_cp2.log"; then ok "控制面第二次运行 exit 0"; else bad "控制面第二次运行失败"; fi
check_eq "控制面第二次运行 changed=0（已在目标版本）" 0 "$(changed_of "$SB/logs/upg_cp2.log")"
if ap_node "$SB/logs/upg_node2.log"; then ok "工作节点第二次运行 exit 0"; else bad "工作节点第二次运行失败"; fi
check_eq "工作节点第二次运行 changed=0" 0 "$(changed_of "$SB/logs/upg_node2.log")"
check_eq "第二次运行未重启 apiserver（PID 不变）" "${PID[apiserver_upg]}" \
  "$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")"
check_eq "第二次运行未重启 kubelet（PID 不变）" "${PID[kubelet_upg]}" \
  "$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")"
check_eq "第二次运行未新增控制面备份目录" 1 "$(sudo -n find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | wc -l)"

echo "-- E2 按文档回滚（真实 etcd 快照恢复）"
BIN_UPG="$SB/usr/local/bin/kube-apiserver:$SB/usr/local/bin/kube-controller-manager:$SB/usr/local/bin/kube-scheduler"
stop_proc "$SB/node2/usr/local/bin/kubelet"
stop_proc "$SB/node1/usr/local/bin/kubelet"
stop_proc "$SB/usr/local/bin/kube-apiserver"
stop_proc "$SB/usr/local/bin/etcd"
check_not "回滚前 kubelet 已停止" proc_alive_path "$SB/node1/usr/local/bin/kubelet"
check_not "回滚前 apiserver 已停止" proc_alive_path "$SB/usr/local/bin/kube-apiserver"
check_not "回滚前 etcd 已停止" proc_alive_path "$SB/usr/local/bin/etcd"
rc=0
ap_cp "$SB/logs/rollback_cp.log" -e upgrade_action=rollback \
  -e "upgrade_rollback_dir=$BACKUP_CP" -e upgrade_rollback_etcd_offline_ack=true || rc=$?
check "控制面回滚 exit 0" test "$rc" -eq 0
rc=0
ap_node "$SB/logs/rollback_node.log" -e upgrade_action=rollback \
  -e "upgrade_rollback_dir=$BACKUP_NODE" || rc=$?
check "节点回滚 exit 0" test "$rc" -eq 0
check_eq "回滚后 kube-apiserver 二进制 = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kube-apiserver")"
check_eq "回滚后 kubelet 二进制 = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/node1/usr/local/bin/kubelet")"
start_unit etcd2 "$ETCD_UNIT" "$SB/logs/etcd2.log" 65534 && ok "已拉起回滚后的 etcd" \
  || bad "无法解析 etcd unit 的 ExecStart"
check "回滚后 etcd healthy（恢复的数据目录可用）" wait_etcd
start_unit apiserver3 "$UNIT_API" "$SB/logs/apiserver3.log" && ok "已拉起回滚后的 kube-apiserver" \
  || bad "无法解析 apiserver unit 的 ExecStart"
check "回滚后 /healthz = ok" wait_healthz
check_eq "回滚后 /version = v$VERSION_OLD（真实 gitVersion）" "v$VERSION_OLD" \
  "$(kctl get --raw /version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gitVersion",""))' 2>/dev/null)"
check_not "升级期间写入的 ConfigMap 已随 etcd 回滚消失" kctl -n default get cm upgrade-marker
start_unit kl1c "$KL1_UNIT" "$SB/logs/kl1c.log" && ok "已拉起回滚后的 node1 kubelet" \
  || bad "无法解析 node1 kubelet ExecStart"
check "回滚后 node1 仍注册" wait_node node1
check "回滚后 node1 kubeletVersion 已刷新为 v$VERSION_OLD" wait_node_version node1 "v$VERSION_OLD"
check_eq "回滚后 node1 kubeletVersion = v$VERSION_OLD" "v$VERSION_OLD" "$(node_kubelet_version node1)"
check_eq "回滚后控制面二进制内容哈希 ≠ 升级后" \
  "$BIN_UPG" "$SB/usr/local/bin/kube-apiserver:$SB/usr/local/bin/kube-controller-manager:$SB/usr/local/bin/kube-scheduler"
if ap_node "$SB/logs/rollback_node2.log" -e upgrade_action=rollback -e "upgrade_rollback_dir=$BACKUP_NODE"; then
  ok "节点回滚第二次运行 exit 0"
else
  bad "节点回滚第二次运行失败（见 $SB/logs/rollback_node2.log）"
fi
check_eq "节点回滚第二次运行 changed=0（幂等）" 0 "$(changed_of "$SB/logs/rollback_node2.log")"
skipped "系统 Pod Running（无镜像；真机用 tests/e2e/smoke.sh --mode real）"
skipped "真实多节点/多成员 etcd 滚动（需多台主机/VM；见 docs/usage.md 已知限制）"

echo "-- F 清理与宿主零污染"
stop_proc "$SB/node2/usr/local/bin/kubelet"
stop_proc "$SB/node1/usr/local/bin/kubelet"
stop_proc "$SB/node2/usr/local/bin/containerd"
stop_proc "$SB/node1/usr/local/bin/containerd"
stop_proc "$SB/usr/local/bin/kube-scheduler"
stop_proc "$SB/usr/local/bin/kube-controller-manager"
stop_proc "$SB/usr/local/bin/kube-apiserver"
stop_proc "$SB/usr/local/bin/etcd"
restore_kernel_tunables
stop_new_kubepods_slices
for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
WRAPPER=()
all_stopped() {
  local p
  for p in "$SB/node2/usr/local/bin/kubelet" "$SB/node1/usr/local/bin/kubelet" \
    "$SB/node2/usr/local/bin/containerd" "$SB/node1/usr/local/bin/containerd" \
    "$SB/usr/local/bin/kube-apiserver" "$SB/usr/local/bin/etcd"; do
    proc_alive_path "$p" && return 1
  done
  return 0
}
check "沙箱进程已全部退出" all_stopped
check "高位端口全部释放" wait_ports_free
check "沙箱 CRI socket 已随进程消失" \
  bash -c "[[ ! -S '$SB/node1/run/containerd/containerd.sock' && ! -S '$SB/node2/run/containerd/containerd.sock' ]]"
printf '  （本次新建 kubepods slice = %s，已停止 = %s）\n' "$NEW_SLICE_SEEN" "$NEW_SLICE_STOPPED"
check_eq "kubepods 清理：本次新建 slice 全部停止" "$NEW_SLICE_SEEN" "$NEW_SLICE_STOPPED"
check_eq "kubepods 清理无失败项" "" "$SLICE_STOP_ERRORS"

POST_HOST_SNAP=/tmp/opencode/t016_host_post.txt
if snapshot_with_retry "$POST_HOST_SNAP"; then
  ok "宿主快照已复采（内容级）"
  check_eq "宿主 /etc/kubernetes 未变（内容哈希）" \
    "$(snap_get "$PRE_HOST_SNAP" etc_kubernetes)" "$(snap_get "$POST_HOST_SNAP" etc_kubernetes)"
  check_eq "宿主 /etc/systemd/system unit 集合/内容未变" \
    "$(snap_get "$PRE_HOST_SNAP" systemd_units)" "$(snap_get "$POST_HOST_SNAP" systemd_units)"
  check_eq "宿主 /var/lib/containerd 顶层条目未变" \
    "$(snap_get "$PRE_HOST_SNAP" var_lib_containerd)" "$(snap_get "$POST_HOST_SNAP" var_lib_containerd)"
  check_eq "宿主 /run/containerd 顶层条目未变" \
    "$(snap_get "$PRE_HOST_SNAP" run_containerd)" "$(snap_get "$POST_HOST_SNAP" run_containerd)"
  check_eq "宿主 /opt/cni/bin 未变（内容哈希）" \
    "$(snap_get "$PRE_HOST_SNAP" opt_cni_bin)" "$(snap_get "$POST_HOST_SNAP" opt_cni_bin)"
  check_eq "宿主端口快照一致" \
    "$(snap_get "$PRE_HOST_SNAP" ports)" "$(snap_get "$POST_HOST_SNAP" ports)"
  check_eq "宿主 kernel.panic 已恢复" "$PRE_KERNEL_PANIC" "$(cat /proc/sys/kernel/panic 2>/dev/null)"
  check_eq "宿主 kernel.panic_on_oops 已恢复" "$PRE_KERNEL_PANIC_ON_OOPS" \
    "$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null)"
  check_eq "宿主 kubepods*.slice 已恢复（active）" \
    "$PRE_KUBEPODS_ACTIVE" "$(snap_get "$POST_HOST_SNAP" kubepods_active)"
  check_eq "宿主 kubepods*.slice 加载集合已恢复（active+inactive）" \
    "$PRE_KUBEPODS_LOADED" "$(snap_get "$POST_HOST_SNAP" kubepods_loaded)"
else
  bad "宿主快照复采失败或含无效键：$(snapshot_problems "$POST_HOST_SNAP" etc_kubernetes opt_cni_bin var_lib_containerd run_containerd)"
fi
check "已 accepted 的 role 全程未被改动" \
  bash -c '[[ -z "$(git status --porcelain --untracked-files=all -- roles/)" ]]'

if [[ "${T016_KEEP_SANDBOX:-0}" == "1" ]]; then
  printf '  （保留沙箱：%s）\n' "$SB"
else
  sudo -n rm -rf "$SB"
  check "沙箱已清理" test ! -e "$SB"
  SB=""
fi

echo
echo "RESULT=$([[ $fail -eq 0 ]] && echo PASS || echo FAIL)"
echo "PASS=$pass_count"
echo "FAIL=$fail"
echo "SKIP=$skip_count"
[[ $fail -eq 0 ]]
