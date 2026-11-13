#!/usr/bin/env bash
# =============================================================================
# T013 调度约束（业务仅落 node）验收测试（TDD：先红后绿）
#
#   静态：roles/taints 结构 / 变量化 / fail-fast 接线 / 示例工作负载无 toleration /
#         syntax-check + yamllint / 已 PASS role 未被修改。
#   动态：沙箱真实 etcd → kube-apiserver → kube-controller-manager（仅
#         deployment/replicaset/serviceaccount）→ kube-scheduler → containerd →
#         kubelet（node1 真实注册）；用真实 API 创建合成控制面节点 cp1。
#         由 role 经真实 kubectl 写入 NoSchedule 污点 + 角色标签并读回；
#         创建不带 toleration 的 3 副本 Deployment，断言全部绑定 node1、0 个 cp1。
#   牙齿：带污点时 pinned Pod 停在 Pending（untolerated taint 事件）；移除污点后
#         同类 Pod 被真实绑定到 cp1；重跑 role 恢复污点。
#   fail-fast：非法 effect / 非 [k8s_master] 主机 / 缺 kubeconfig。
#   受限：Pod 无镜像不会 Running；cp1 为合成 Node 对象（无 kubelet）。
#   宿主零污染：不写 /etc/kubernetes、/etc/systemd/system，不 systemctl；退出恢复
#         kernel.panic* 与 kubepods*.slice。
#   用法: tests/taints/test_taints_role.sh
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
mkdir -p /tmp/opencode

pass_count=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
check_eq() { local d="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok "$d"; else bad "$d [期望=$want 实际=${got:-<空>}]"; fi; }
changed_of() { grep -oE 'changed=[0-9]+' "$1" 2>/dev/null | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# --- Ansible 探测 -----------------------------------------------------------
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

ROLE=roles/taints
role_tree_hash() {
  find "$1" -type f -print0 2>/dev/null | sort -z \
    | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
}
ROLE_TREE_PRE="$(role_tree_hash "$ROLE")"
INV=tests/taints/inventory.ini
PLAY_STACK=tests/taints/sandbox_stack.yml
PLAY_CP=tests/taints/sandbox_control_plane.yml
PLAY_CD=tests/taints/sandbox_containerd.yml
PLAY_KL=tests/taints/sandbox_kubelet.yml
PLAY_TAINT=tests/taints/sandbox_taints.yml
PLAY_TAINT_NODE=tests/taints/sandbox_taints_nonmaster.yml
PLAY_TAINT_REAL=playbooks/taints.yml
WORKLOAD=tests/taints/workload.example.yml
UNIT_EXEC=tests/etcd/unit_exec.py

VERSION=1.31.0
CONTAINERD_VERSION=2.0.0
RUNC_VERSION=1.2.1
CNI_VERSION=1.5.1
CRICTL_VERSION=1.31.1
CACHE="${T013_TEST_CACHE:-/tmp/opencode/k8s-cache}"
ETCD_TARBALL=etcd-v3.5.16-linux-amd64.tar.gz
ETCD_TARBALL_SHA=b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc
CONTAINERD_TARBALL="containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
CNI_TARBALL="cni-plugins-linux-amd64-v${CNI_VERSION}.tgz"
CRICTL_TARBALL="crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz"

NS="${T013_NAMESPACE:-t013-sched}"
REPLICAS="${T013_REPLICAS:-3}"
IMAGE="${T013_IMAGE:-registry.invalid/t013/example:latest}"
APP="${T013_APP:-t013-workload}"

declare -A ART_URL=(
  [kube-apiserver]="https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kube-apiserver"
  [kube-controller-manager]="https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kube-controller-manager"
  [kube-scheduler]="https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kube-scheduler"
  [kubectl]="https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kubectl"
  [kubelet]="https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kubelet"
  ["$CONTAINERD_TARBALL"]="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/${CONTAINERD_TARBALL}"
  [runc.amd64]="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"
  ["$CNI_TARBALL"]="https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/${CNI_TARBALL}"
  ["$CRICTL_TARBALL"]="https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/${CRICTL_TARBALL}"
  ["$ETCD_TARBALL"]="https://storage.googleapis.com/etcd/v3.5.16/${ETCD_TARBALL}"
)
declare -A ART_SHA=(
  [kube-apiserver]=9016f6048ff9827ef58934e98f28a8026634c10b4e6fcc1df49451038a23a9aa
  [kube-controller-manager]=9cf02d0ebf704ffdc727d0ad02e64bc5621f8013c4034b568bf7c939fe150490
  [kube-scheduler]=1e519991d41389bb885df59c19389afe847dad511992d009ff766bc7f3992f89
  [kubectl]=7c27adc64a84d1c0cc3dcf7bf4b6e916cc00f3f576a2dbac51b318d926032437
  [kubelet]=39e7f1c61c8389ea7680690f8bd5dd733672fa16875ae598df0fd8c205df57a9
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
  curl -fL --retry 3 --connect-timeout 20 --max-time 600 -o "$p.tmp" "$url" || { rm -f "$p.tmp"; return 1; }
  mv "$p.tmp" "$p"
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
prefill_cache() {
  mkdir -p "$CACHE" || return 1
  local n
  for n in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet \
    "$CONTAINERD_TARBALL" runc.amd64 "$CNI_TARBALL" "$CRICTL_TARBALL"; do
    ensure_artifact "$n" "${ART_URL[$n]}" "${ART_SHA[$n]}" || return 1
  done
  ensure_etcd_tarball
}

# --- 以 root 重入：PKI 目录 0700 / 进程以 root 拉起；不改变宿主配置 -----------
if [[ "${EUID}" -ne 0 ]] && sudo -n true 2>/dev/null; then
  exec sudo -n env \
    PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}${USER_SITE:-}" \
    ANSIBLE_PLAYBOOK="$ANSIBLE_PLAYBOOK" \
    YAMLLINT="$YAMLLINT" \
    T013_TEST_CACHE="$CACHE" \
    ETCD_TEST_CACHE="${ETCD_TEST_CACHE:-}" \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=safe.directory \
    GIT_CONFIG_VALUE_0="$PWD" \
    bash "$(readlink -f "$0")"
fi

# --- 宿主快照（内容级；采集失败重试 + 显式 FAIL，不静默） ------------------
tree_hash() {  # 目录内容哈希：__MISSING__ / __ERROR__ / sha256
  local p="$1" h
  [[ -e "$p" ]] || { printf '__MISSING__'; return 0; }
  h="$(sudo -n find "$p" -type f -print0 2>/dev/null | sort -z \
    | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
  if [[ -z "$h" ]]; then printf '__ERROR__'; else printf '%s' "$h"; fi
}
shallow_dir_hash() {  # 顶层条目名/类型/大小哈希（避免跟随易变的大目录内容）
  local p="$1" h
  [[ -e "$p" ]] || { printf '__MISSING__'; return 0; }
  h="$(sudo -n find "$p" -maxdepth 1 -mindepth 1 -printf '%f %y %s\n' 2>/dev/null \
    | sort | sha256sum | awk '{print $1}')"
  if [[ -z "$h" ]]; then printf '__ERROR__'; else printf '%s' "$h"; fi
}
unit_set_hash() {  # /etc/systemd/system 的 unit 集合 + 内容哈希
  local h
  h="$(sudo -n find /etc/systemd/system -maxdepth 2 -type f \
    \( -name '*.service' -o -name '*.socket' -o -name '*.timer' \
       -o -name '*.mount' -o -name '*.slice' \) -print0 2>/dev/null \
    | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
  if [[ -z "$h" ]]; then printf '__ERROR__'; else printf '%s' "$h"; fi
}
kubepods_active() {
  systemctl list-units 'kubepods*' --no-legend 2>/dev/null \
    | awk '{print $1}' | sort | tr '\n' ' '
}
kubepods_loaded() {
  systemctl list-units --all 'kubepods*' --no-legend 2>/dev/null \
    | awk '{print $1}' | sort | tr '\n' ' '
}
snapshot_ports() {
  ss -ltn 2>/dev/null | grep -E ':(16443|20250|20248|12379|20257|20259)[[:space:]]' \
    | awk '{print $4}' | sort | tr '\n' ' '
}
snapshot_host_state() {  # snapshot_host_state <outfile>；任一采集失败 → rc=1
  local out="$1"
  {
    printf 'etc_kubernetes=%s\n' "$(tree_hash /etc/kubernetes)"
    printf 'systemd_units=%s\n' "$(unit_set_hash)"
    printf 'var_lib_containerd=%s\n' "$(shallow_dir_hash /var/lib/containerd)"
    printf 'run_containerd=%s\n' "$(shallow_dir_hash /run/containerd)"
    printf 'opt_cni_bin=%s\n' "$(tree_hash /opt/cni/bin)"
    printf 'ports=%s\n' "$(snapshot_ports)"
    printf 'kernel_panic=%s\n' "$(cat /proc/sys/kernel/panic 2>/dev/null || echo __ERROR__)"
    printf 'kernel_panic_on_oops=%s\n' "$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null || echo __ERROR__)"
    printf 'kubepods_active=%s\n' "$(kubepods_active)"
    printf 'kubepods_loaded=%s\n' "$(kubepods_loaded)"
  } >"$out" 2>/dev/null
  grep -q '__ERROR__' "$out" && return 1
  return 0
}
snapshot_with_retry() {
  local out="$1" i
  for ((i = 0; i < 3; i++)); do
    snapshot_host_state "$out" && return 0
    sleep 1
  done
  return 1
}
snap_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }

PRE_HOST_SNAP=/tmp/opencode/t013_host_pre.txt
if ! snapshot_with_retry "$PRE_HOST_SNAP"; then
  bad "宿主快照采集失败（重试 3 次仍失败）"
  echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) =="
  exit 1
fi
ok "宿主快照已采集（内容级：/etc/kubernetes、unit 集合、containerd、端口、sysctl、kubepods）"
PRE_KERNEL_PANIC="$(snap_get "$PRE_HOST_SNAP" kernel_panic)"
PRE_KERNEL_PANIC_ON_OOPS="$(snap_get "$PRE_HOST_SNAP" kernel_panic_on_oops)"
PRE_KUBEPODS_SLICES="$(snap_get "$PRE_HOST_SNAP" kubepods_active)"
PRE_KUBEPODS_LOADED="$(snap_get "$PRE_HOST_SNAP" kubepods_loaded)"
SLICE_STOP_ERRORS=""
SLICES_STOPPED=0
stop_new_kubepods_slices() {  # 只停「本次运行新建」的 slice（前后差集 + 精确 unit 名）
  [[ "$SLICES_STOPPED" -eq 1 ]] && return 0
  SLICES_STOPPED=1
  local now u
  now="$(kubepods_loaded)"
  while read -r u; do
    [[ -z "$u" ]] && continue
    if ! sudo -n systemctl stop "$u" >/dev/null 2>&1; then
      SLICE_STOP_ERRORS+="$u "
    fi
  done < <(comm -13 <(printf '%s\n' $PRE_KUBEPODS_LOADED | sort -u) \
                    <(printf '%s\n' $now | sort -u))
  return 0
}

restore_kernel_tunables() {
  [[ "$PRE_KERNEL_PANIC" == "__MISSING__" ]] || \
    sudo -n sysctl -q -w "kernel.panic=$PRE_KERNEL_PANIC" >/dev/null 2>&1 || true
  [[ "$PRE_KERNEL_PANIC_ON_OOPS" == "__MISSING__" ]] || \
    sudo -n sysctl -q -w "kernel.panic_on_oops=$PRE_KERNEL_PANIC_ON_OOPS" >/dev/null 2>&1 || true
}

SB=""
declare -A PID=()
declare -A WRAPPER=()
KUBECTL=""
stop_proc() {
  local pat="$1" i
  # 锚定 cmdline 开头，避免 pkill -f 匹配到调用方自身（T008 M6 教训）。
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
cleanup() {
  local k
  restore_kernel_tunables
  for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
  [[ -n "${SB:-}" ]] || return 0
  stop_proc "$SB/usr/local/bin/kubelet"
  stop_proc "$SB/usr/local/bin/containerd"
  stop_proc "$SB/usr/local/bin/kube-scheduler"
  stop_proc "$SB/usr/local/bin/kube-controller-manager"
  stop_proc "$SB/usr/local/bin/kube-apiserver"
  stop_proc "$SB/usr/local/bin/etcd"
  stop_new_kubepods_slices
  sudo -n rm -rf "$SB" 2>/dev/null || true
}
trap cleanup EXIT

proc_alive() {
  local exe p
  exe="$(readlink -f "$1" 2>/dev/null)" || return 1
  [[ -n "$exe" ]] || return 1
  for p in /proc/[0-9]*; do
    [[ "$(readlink "$p/exe" 2>/dev/null)" == "$exe" ]] && return 0
  done
  return 1
}
proc_pid() { pgrep -f -- "^$SB/usr/local/bin/$1( |$)" 2>/dev/null | head -1; }
unit_path() { printf '%s/etc/systemd/system/%s.service' "$SB" "$1"; }
wait_ports_free() {
  local i
  for ((i = 0; i < 60; i++)); do
    [[ -z "$(snapshot_ports)" ]] && return 0
    sleep 0.5
  done
  return 1
}

echo "== T013 调度约束（业务仅落 node）验收 =="

echo "-- A1 role / 测试资产结构"
for f in defaults/main.yml tasks/main.yml tasks/validate.yml tasks/nodes.yml \
  meta/main.yml README.md; do
  check "存在 $ROLE/$f" test -f "$ROLE/$f"
done
check "存在 $WORKLOAD" test -f "$WORKLOAD"
check "存在 $INV" test -f "$INV"
check "存在 tests/taints/README.md" test -f tests/taints/README.md
for p in "$PLAY_STACK" "$PLAY_CP" "$PLAY_CD" "$PLAY_KL" "$PLAY_TAINT" "$PLAY_TAINT_NODE"; do
  check "存在 $p" test -f "$p"
done
check "存在 Makefile 目标 test-taints" grep -qE '^test-taints:' Makefile
check "存在部署入口 $PLAY_TAINT_REAL" test -f "$PLAY_TAINT_REAL"
check "make test 挂载 test_taints_role.sh" \
  bash -c "awk '/^test:/{f=1} f&&/^[a-zA-Z0-9_-]+:/{if(\$0!~/^test:/)exit} f' Makefile | grep -q 'tests/taints/test_taints_role.sh'"
for p in "$PLAY_STACK" "$PLAY_CP" "$PLAY_CD" "$PLAY_KL" "$PLAY_TAINT" "$PLAY_TAINT_NODE" \
  tests/taints/inventory.ini "$WORKLOAD"; do
  check "sandbox 资产不写入宿主 /etc/systemd/system：$p" \
    bash -c "! grep -q '/etc/systemd/system' '$p'"
done

echo "-- A2 role 变量化 / 安全接线（静态）"
check "defaults 定义污点 key" grep -qE '^taints_control_plane_taint_key:' "$ROLE/defaults/main.yml"
check "defaults 定义污点 value" grep -qE '^taints_control_plane_taint_value:' "$ROLE/defaults/main.yml"
check "defaults 定义污点 effect" grep -qE '^taints_control_plane_taint_effect:' "$ROLE/defaults/main.yml"
check "defaults 默认 effect=NoSchedule" \
  grep -qE '^taints_control_plane_taint_effect:[[:space:]]*"?NoSchedule"?' "$ROLE/defaults/main.yml"
check "defaults 定义角色标签" grep -qE '^taints_control_plane_label_key:' "$ROLE/defaults/main.yml"
check "defaults 标签默认 control-plane" \
  grep -q 'node-role.kubernetes.io/control-plane' "$ROLE/defaults/main.yml"
check "defaults 允许 NoSchedule/NoExecute/PreferNoSchedule" \
  bash -c "grep -q 'NoSchedule' '$ROLE/defaults/main.yml' && grep -q 'NoExecute' '$ROLE/defaults/main.yml' && grep -q 'PreferNoSchedule' '$ROLE/defaults/main.yml'"
check "defaults 从 groups['k8s_master'] 派生目标节点" \
  grep -q "groups\['k8s_master'\]" "$ROLE/defaults/main.yml"
check "defaults kubeconfig 可配置" grep -qE '^taints_kubeconfig:' "$ROLE/defaults/main.yml"
check "defaults kubectl 可配置" grep -qE '^taints_kubectl:' "$ROLE/defaults/main.yml"
check "validate 断言控制面成员身份" grep -q 'inventory_hostname' "$ROLE/tasks/validate.yml"
check "validate 断言 effect 白名单" grep -q 'taints_allowed_effects' "$ROLE/tasks/validate.yml"
check "validate 断言 kubeconfig 存在" grep -q 'stat' "$ROLE/tasks/validate.yml"
check "nodes 使用 ansible.builtin.command（非 shell）" \
  grep -q 'ansible.builtin.command' "$ROLE/tasks/nodes.yml"
check_not "role 不使用 ansible.builtin.shell" \
  grep -rqE 'ansible\.builtin\.shell' "$ROLE/tasks"
check_not "role 不调用 systemctl" grep -rqE 'systemctl' "$ROLE/tasks" "$ROLE/defaults"
check_not "role 不硬编码默认端口 6443/10250" \
  grep -rqE '(6443|10250)' "$ROLE/tasks" "$ROLE/defaults"
check "role 任务带 taints tag" grep -q 'tags:.*taints' "$ROLE/tasks/main.yml"
check "schema 幂等：nodes 先读后写（get node -o json）" \
  grep -q "get.*node.*-o.*json" "$ROLE/tasks/nodes.yml"
check "nodes 只读 command 显式 check_mode: false（≥3 处）" \
  bash -c "[[ \$(grep -c 'check_mode: false' '$ROLE/tasks/nodes.yml') -ge 3 ]]"
check "nodes 写任务在 check 模式被跳过（not ansible_check_mode）" \
  grep -q 'not ansible_check_mode' "$ROLE/tasks/nodes.yml"
check "nodes 使用 argv 列表（不做字符串 join）" grep -q 'argv:' "$ROLE/tasks/nodes.yml"
check_not "nodes 不再用 join(' ') 构造 cmd" grep -q "join(' ')" "$ROLE/tasks/nodes.yml"
check "validate 断言 kubectl 可执行" grep -q 'executable' "$ROLE/tasks/validate.yml"
check "validate 校验目标节点为列表（非字符串）" \
  grep -qE 'is sequence|is not string' "$ROLE/tasks/validate.yml"
check "validate 校验 taint key/value 字符集" \
  grep -qE 'taint_key|taints_control_plane_taint_value' "$ROLE/tasks/validate.yml"

echo "-- A3 示例工作负载（无 toleration）"
check "workload 是 Deployment" grep -qE '^kind: Deployment' "$WORKLOAD"
check "workload 默认 namespace=$NS" grep -qE "^  namespace: $NS$" "$WORKLOAD"
check "workload 默认 replicas=$REPLICAS" grep -qE "^  replicas: $REPLICAS$" "$WORKLOAD"
check "workload 默认镜像可覆盖（registry.invalid 占位）" grep -q 'registry.invalid' "$WORKLOAD"
check_not "workload 不含 tolerations" grep -qE '^\s*tolerations:' "$WORKLOAD"
check "workload 文档说明环境变量可覆盖" \
  grep -qE 'T013_NAMESPACE|T013_REPLICAS|T013_IMAGE|T013_APP' "$WORKLOAD"

echo "-- A4 语法 / 风格 / 冻结资产"
for p in "$PLAY_TAINT" "$PLAY_TAINT_NODE" "$PLAY_TAINT_REAL"; do
  check "syntax-check $p" "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$p"
done
check "syntax-check $PLAY_CP" "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_CP"
check "yamllint role + tests/taints + playbooks/taints.yml" \
  "$YAMLLINT" -c .yamllint "$ROLE" tests/taints "$PLAY_TAINT_REAL"
check "已 PASS 的 role 未被修改（工作区含未跟踪文件）" \
  bash -c "[[ -z \"\$(git status --porcelain --untracked-files=all -- \
    roles/base roles/download roles/pki roles/etcd roles/haproxy roles/keepalived \
    roles/kube-apiserver roles/kube-controller-manager roles/kube-scheduler \
    roles/containerd roles/kubelet roles/kube-proxy roles/cilium roles/cluster-addons)\" ]]"
check "roles/taints 全量文件内容哈希在测试前可计算" test -n "$ROLE_TREE_PRE"
"$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_TAINT_REAL" --list-tasks --tags taints \
  >/tmp/opencode/t013_list_tasks.log 2>&1
check "playbooks/taints.yml --list-tasks --tags taints 非空" \
  bash -c "grep -qE 'taints:(validate|nodes)' /tmp/opencode/t013_list_tasks.log"
check "真机入口文档 tests/taints/README.md 指向 playbooks/taints.yml" \
  grep -q 'playbooks/taints.yml' tests/taints/README.md
check "真机入口文档 roles/taints/README.md 指向 playbooks/taints.yml" \
  grep -q 'playbooks/taints.yml' "$ROLE/README.md"
check "契约 §5 真机命令指向 playbooks/taints.yml" \
  grep -q 'playbooks/taints.yml' docs/harness/state/contracts/T013.md

echo "-- B0 制品缓存 / 沙箱自举"
PRE_PORTS="$(snap_get "$PRE_HOST_SNAP" ports)"
if [[ -n "$PRE_PORTS" ]]; then
  bad "高位端口已被占用（$PRE_PORTS），请先停止残留进程"
  echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) =="
  exit 1
fi
if ! prefill_cache; then
  bad "无法准备官方制品缓存（见上方 curl 错误）"
  echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) =="
  exit 1
fi
ok "官方制品缓存命中（含 apiserver/CM/scheduler/kubelet/etcd/containerd）"

SB="$(mktemp -d /tmp/opencode/t013.XXXXXX)"
chmod 0755 "$SB"
mkdir -p "$SB/opt/k8s/artifacts" "$SB/logs" "$SB/client" "$SB/etc" "$SB/var"
chmod 0755 "$SB/etc" "$SB/var"
for n in "${!ART_SHA[@]}"; do cp "$CACHE/$n" "$SB/opt/k8s/artifacts/$n"; done
sudo -n chown -R root:root "$SB/opt/k8s/artifacts"
sudo -n chmod 0644 "$SB"/opt/k8s/artifacts/*
ok "沙箱制品已就绪（$SB）"

ap() {  # ap <playbook> <log> [额外的 -e ...]
  local play="$1" log="$2"
  shift 2
  timeout 900 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" -e "{\"sandbox_root\":\"$SB\"}" "$@" >"$log" 2>&1
}

echo "-- B1 pki + 单成员 TLS etcd"
if ap "$PLAY_STACK" /tmp/opencode/t013_stack.log; then
  ok "stack playbook exit 0（kubectl + pki + etcd 渲染）"
else
  bad "stack playbook 失败（见 /tmp/opencode/t013_stack.log）"
fi
check "pki 产出 node1 kubelet 证书" test -f "$SB/etc/kubernetes/pki/kubelet/node1.crt"
check "kubectl 已安装到沙箱" test -x "$SB/usr/local/bin/kubectl"

ETCD_UNIT="$(unit_path etcd-etcd1)"
mapfile -t ETCD_ARGS < <(python3 "$UNIT_EXEC" "$ETCD_UNIT")
if [[ ${#ETCD_ARGS[@]} -gt 0 ]]; then
  ( sudo -n setpriv --reuid 65534 --regid 65534 --clear-groups \
      "${ETCD_ARGS[@]}" </dev/null >>"$SB/logs/etcd.log" 2>&1 ) &
  WRAPPER[etcd]=$!
  ok "已从 etcd unit 拉起单成员 TLS etcd"
else
  bad "无法解析 etcd unit 的 ExecStart"
fi
ETCD_PKI="$SB/etc/kubernetes/pki/etcd"
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$ETCD_PKI/ca.crt" "$SB/client/etcd-ca.crt"
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" \
  "$SB/etc/kubernetes/pki/apiserver-etcd-client.crt" "$SB/client/etcd-client.crt"
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" \
  "$SB/etc/kubernetes/pki/apiserver-etcd-client.key" "$SB/client/etcd-client.key"
ETCDCTL="$SB/usr/local/bin/etcdctl"
etcd_healthy() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints=https://127.0.0.1:12379 \
    --cacert "$SB/client/etcd-ca.crt" --cert "$SB/client/etcd-client.crt" \
    --key "$SB/client/etcd-client.key" --command-timeout=2s endpoint health >/dev/null 2>&1
}
wait_etcd() { local i; for ((i = 0; i < 120; i++)); do etcd_healthy && return 0; sleep 0.5; done; return 1; }
check "单成员 etcd healthy（真实 TLS）" wait_etcd

echo "-- B2 真实控制面（apiserver + CM + scheduler）"
if ap "$PLAY_CP" /tmp/opencode/t013_cp.log; then
  ok "控制面 playbook exit 0（三组件沙箱渲染）"
else
  bad "控制面 playbook 失败（见 /tmp/opencode/t013_cp.log）"
fi
UNIT_API="$(unit_path kube-apiserver)"
UNIT_CM="$(unit_path kube-controller-manager)"
UNIT_SCHED="$(unit_path kube-scheduler)"
for u in "$UNIT_API" "$UNIT_CM" "$UNIT_SCHED"; do
  check "unit 已渲染 $(basename "$u")" test -f "$u"
done

mapfile -t API_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_API")
if [[ ${#API_ARGS[@]} -gt 0 ]]; then
  ( sudo -n "${API_ARGS[@]}" </dev/null >>"$SB/logs/apiserver.log" 2>&1 ) &
  WRAPPER[apiserver]=$!
  ok "已从 unit 拉起 kube-apiserver"
else
  bad "无法解析 apiserver unit 的 ExecStart"
fi
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/admin.conf" "$SB/client/admin.conf"
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/pki/ca.crt" "$SB/client/ca.crt"
KUBECTL="$SB/usr/local/bin/kubectl"
kctl() { "$KUBECTL" --kubeconfig "$SB/client/admin.conf" --cache-dir "$SB/client/kubectl-cache" --request-timeout=10s "$@"; }
wait_healthz() {
  local i
  for ((i = 0; i < 180; i++)); do
    kctl get --raw /healthz 2>/dev/null | grep -qx ok && return 0
    sleep 0.5
  done
  return 1
}
check "kubectl get --raw /healthz = ok" wait_healthz

mapfile -t CM_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_CM")
if [[ ${#CM_ARGS[@]} -gt 0 ]]; then
  ( sudo -n "${CM_ARGS[@]}" </dev/null >>"$SB/logs/cm.log" 2>&1 ) &
  WRAPPER[cm]=$!
  ok "已从 unit 拉起 kube-controller-manager（deployment/replicaset/serviceaccount）"
else
  bad "无法解析 CM unit 的 ExecStart"
fi
mapfile -t SCHED_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_SCHED")
if [[ ${#SCHED_ARGS[@]} -gt 0 ]]; then
  ( sudo -n "${SCHED_ARGS[@]}" </dev/null >>"$SB/logs/scheduler.log" 2>&1 ) &
  WRAPPER[sched]=$!
  ok "已从 unit 拉起 kube-scheduler"
else
  bad "无法解析 scheduler unit 的 ExecStart"
fi
wait_proc() {
  local name="$1" i
  for ((i = 0; i < 160; i++)); do
    PID[$name]="$(proc_pid "$name")"
    [[ -n "${PID[$name]}" ]] && return 0
    sleep 0.25
  done
  return 1
}
check "CM 进程存活" wait_proc kube-controller-manager
check "scheduler 进程存活" wait_proc kube-scheduler

echo "-- B3 真实 containerd + kubelet（node1 注册）"
if ap "$PLAY_CD" /tmp/opencode/t013_containerd.log; then
  ok "containerd playbook exit 0"
else
  bad "containerd playbook 失败（见 /tmp/opencode/t013_containerd.log）"
fi
UNIT_CD="$(unit_path containerd)"
SOCK="$SB/run/containerd/containerd.sock"
mapfile -t CD_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_CD")
if [[ ${#CD_ARGS[@]} -gt 0 ]]; then
  ( sudo -n "${CD_ARGS[@]}" </dev/null >>"$SB/logs/containerd.log" 2>&1 ) &
  WRAPPER[containerd]=$!
  ok "已从 unit 拉起 containerd"
else
  bad "无法解析 containerd unit 的 ExecStart"
fi
wait_socket() { local i; for ((i = 0; i < 120; i++)); do [[ -S "$SOCK" ]] && return 0; sleep 0.25; done; return 1; }
check "containerd CRI socket 已创建" wait_socket

if ap "$PLAY_KL" /tmp/opencode/t013_kubelet.log; then
  ok "kubelet playbook exit 0"
else
  bad "kubelet playbook 失败（见 /tmp/opencode/t013_kubelet.log）"
fi
UNIT_KL="$(unit_path kubelet)"
mapfile -t KL_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_KL")
if [[ ${#KL_ARGS[@]} -gt 0 ]]; then
  ( sudo -n "${KL_ARGS[@]}" </dev/null >>"$SB/logs/kubelet.log" 2>&1 ) &
  WRAPPER[kubelet]=$!
  ok "已从 unit 拉起真实 kubelet"
else
  bad "无法解析 kubelet unit 的 ExecStart"
fi
node_registered() {
  local i
  for ((i = 0; i < 240; i++)); do
    kctl get node node1 -o name 2>/dev/null | grep -qx 'node/node1' && return 0
    sleep 0.5
  done
  return 1
}
check "node1 真实注册" node_registered
NODE_READY="$(kctl get node node1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
printf '  （node1 Ready=%s；无 CNI 时 NotReady 可接受）\n' "${NODE_READY:-?}"
check "node1 Ready 条件存在（True/False）" \
  bash -c "[[ '$NODE_READY' == 'True' || '$NODE_READY' == 'False' ]]"

echo "-- B4 合成控制面节点对象 cp1（真实 API，声明为受限近似）"
cat >"$SB/client/node-cp1.json" <<'JSON'
{"apiVersion":"v1","kind":"Node",
 "metadata":{"name":"cp1","labels":{"kubernetes.io/hostname":"cp1"}}}
JSON
check "kubectl apply Node cp1" kctl apply -f "$SB/client/node-cp1.json"
cat >"$SB/client/node-cp1-status.json" <<'JSON'
{"status":{
  "capacity":{"cpu":"16","memory":"64Gi","pods":"110"},
  "allocatable":{"cpu":"16","memory":"64Gi","pods":"110"},
  "conditions":[{"type":"Ready","status":"False","reason":"SyntheticControlPlane",
    "message":"T013 sandbox synthetic control-plane node (no kubelet)",
    "lastHeartbeatTime":"2026-11-12T00:00:00Z",
    "lastTransitionTime":"2026-11-12T00:00:00Z"}],
  "addresses":[{"type":"InternalIP","address":"127.0.0.2"}]}}
JSON
check "注入 cp1 status（capacity/allocatable/Ready=False）" \
  kctl patch node cp1 --subresource=status --type=merge -p "$(cat "$SB/client/node-cp1-status.json")"
dump_node() { kctl get node "$1" -o json >"$SB/client/node-$1.json" 2>/dev/null; }
check "cp1 节点对象可读回" bash -c "'$KUBECTL' --kubeconfig '$SB/client/admin.conf' --cache-dir '$SB/client/kubectl-cache' get node cp1 -o name | grep -qx node/cp1"
dump_node cp1
check "cp1 allocatable cpu=16 已生效" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["status"]["allocatable"]["cpu"]=="16" else 1)' "$SB/client/node-cp1.json"
printf '  （cp1 初始 spec.taints=%s）\n' "$(kctl get node cp1 -o jsonpath='{.spec.taints}' 2>/dev/null)"
check "cp1 初始无控制面污点（role 尚未执行）" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if not (d.get("spec",{}).get("taints") or []) else 1)' "$SB/client/node-cp1.json"

taint_exists() {  # taint_exists <node> <key> <value> <effect>
  python3 - "$SB/client/node-$1.json" "$2" "$3" "$4" <<'PY'
import json
import sys
n = json.load(open(sys.argv[1]))
taints = n.get("spec", {}).get("taints") or []
sys.exit(0 if any(t.get("key") == sys.argv[2] and t.get("value", "") == sys.argv[3]
                  and t.get("effect") == sys.argv[4] for t in taints) else 1)
PY
}
label_exists() {  # label_exists <node> <key> [value]
  python3 - "$SB/client/node-$1.json" "$2" "${3:-}" <<'PY'
import json
import sys
n = json.load(open(sys.argv[1]))
labels = n.get("metadata", {}).get("labels") or {}
sys.exit(0 if sys.argv[2] in labels and labels[sys.argv[2]] == sys.argv[3] else 1)
PY
}
taint_hash() { kctl get node cp1 -o jsonpath='{.spec.taints}' 2>/dev/null | sha256sum | awk '{print $1}'; }
label_hash() { kctl get node cp1 -o jsonpath='{.metadata.labels}' 2>/dev/null | sha256sum | awk '{print $1}'; }

echo "-- B5 role 首跑：控制面污点 + 角色标签（真实 API 读回）"
if ap "$PLAY_TAINT" /tmp/opencode/t013_taints_run1.log; then
  ok "taints playbook 首跑 exit 0"
else
  bad "taints playbook 首跑失败（见 /tmp/opencode/t013_taints_run1.log）"
fi
check "首跑 changed>0" test "$(changed_of /tmp/opencode/t013_taints_run1.log)" -gt 0
dump_node cp1
dump_node node1
check "cp1 有 node-role.kubernetes.io/control-plane:NoSchedule 污点" \
  taint_exists cp1 node-role.kubernetes.io/control-plane "" NoSchedule
check "cp1 污点 key 唯一（未重复写入）" \
  bash -c "[ \"\$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for t in (d[\"spec\"].get(\"taints\") or []) if t.get(\"key\")==\"node-role.kubernetes.io/control-plane\"))' '$SB/client/node-cp1.json')\" = 1 ]"
check "cp1 有角色标签 node-role.kubernetes.io/control-plane" \
  label_exists cp1 node-role.kubernetes.io/control-plane ""
check "node1 未被 role 打控制面污点" \
  bash -c "! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(t.get(\"key\")==\"node-role.kubernetes.io/control-plane\" for t in (d[\"spec\"].get(\"taints\") or [])) else 1)' '$SB/client/node1.json'"
check "node1 未被 role 打控制面标签" \
  bash -c "! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if \"node-role.kubernetes.io/control-plane\" in (d[\"metadata\"].get(\"labels\") or {}) else 1)' '$SB/client/node1.json'"

echo "-- B6 变量化：自定义污点 key/effect 真实生效"
if ap "$PLAY_TAINT" /tmp/opencode/t013_taints_custom.log \
  -e '{"taints_control_plane_taint_key":"example.com/t013-control-plane","taints_control_plane_taint_effect":"NoExecute"}'; then
  ok "自定义 key=example.com/t013-control-plane effect=NoExecute 运行 exit 0"
else
  bad "自定义污点运行失败（见 /tmp/opencode/t013_taints_custom.log）"
fi
dump_node cp1
check "自定义污点 NoExecute 已写入真实 API" \
  taint_exists cp1 example.com/t013-control-plane "" NoExecute
check "默认控制面污点仍在（role 只增不误删）" \
  taint_exists cp1 node-role.kubernetes.io/control-plane "" NoSchedule
check "测试用 kubectl 移除自定义污点" \
  kctl taint node cp1 example.com/t013-control-plane:NoExecute-
dump_node cp1
check "自定义污点已移除" \
  bash -c "! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(t.get(\"key\")==\"example.com/t013-control-plane\" for t in (d[\"spec\"].get(\"taints\") or [])) else 1)' '$SB/client/node-cp1.json'"

echo "-- B7 示例工作负载：3 副本全部落 node1（0 个 cp1）"
kctl get namespace "$NS" >/dev/null 2>&1 || kctl create namespace "$NS" >/dev/null 2>&1 || true
check "示例命名空间 $NS 已创建" kctl get namespace "$NS" -o name
python3 - "$WORKLOAD" "$NS" "$REPLICAS" "$IMAGE" "$APP" >"$SB/client/workload.json" <<'PY'
import json
import sys
import yaml

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
import json
import sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
items = d.get("items") or []
want = int(sys.argv[2])
sys.exit(0 if len(items) == want and all(p["spec"].get("nodeName") for p in items) else 1)
PY
    then return 0; fi
    sleep 0.5
  done
  return 1
}
check "Deployment 产生 $REPLICAS 个 Pod 且全部完成调度绑定" wait_deployment_pods
kctl -n "$NS" get pods -l "app=$APP" -o json >"$SB/client/pods.json" 2>/dev/null
pod_metric() {  # pod_metric <count|on-node|unbound|no-cp-toleration> <node>
  python3 - "$SB/client/pods.json" "${1}" "${2:-}" <<'PY'
import json
import sys
items = (json.load(open(sys.argv[1])).get("items") or [])
metric = sys.argv[2]
if metric == "count":
    print(len(items))
elif metric == "on-node":
    print(sum(1 for p in items if p["spec"].get("nodeName") == sys.argv[3]))
elif metric == "unbound":
    print(sum(1 for p in items if not p["spec"].get("nodeName")))
elif metric == "no-cp-toleration":
    key = "node-role.kubernetes.io/control-plane"
    bad = sum(1 for p in items
              if any(t.get("key") == key for t in (p["spec"].get("tolerations") or [])))
    print(bad)
PY
}
check_eq "Pod 数量 = $REPLICAS" "$REPLICAS" "$(pod_metric count)"
check_eq "全部 $REPLICAS 个副本绑定 node1" "$REPLICAS" "$(pod_metric on-node node1)"
check_eq "0 个副本绑定 cp1（master）" 0 "$(pod_metric on-node cp1)"
check_eq "无未调度 Pod" 0 "$(pod_metric unbound)"
check_eq "Pod 均无控制面 toleration" 0 "$(pod_metric no-cp-toleration)"
check "kubectl get pods -o wide 的 NODE 列不含 cp1" \
  bash -c "! '$KUBECTL' --kubeconfig '$SB/client/admin.conf' --cache-dir '$SB/client/kubectl-cache' -n '$NS' get pods -l 'app=$APP' -o wide | awk 'NR>1{print \$7}' | grep -qx cp1"
check "Deployment 的 ReplicaSet 已创建（真实控制器链路）" \
  bash -c "'$KUBECTL' --kubeconfig '$SB/client/admin.conf' --cache-dir '$SB/client/kubectl-cache' -n '$NS' get rs -o name | grep -q ."

echo "-- B8 幂等：role 第二次运行 changed=0"
T_HASH="$(taint_hash)"
L_HASH="$(label_hash)"
if ap "$PLAY_TAINT" /tmp/opencode/t013_taints_run2.log; then
  ok "taints playbook 第二次运行 exit 0"
else
  bad "taints playbook 第二次运行失败（见 /tmp/opencode/t013_taints_run2.log）"
fi
check_eq "第二次运行 changed=0" 0 "$(changed_of /tmp/opencode/t013_taints_run2.log)"
check_eq "污点哈希未变" "$T_HASH" "$(taint_hash)"
check_eq "标签哈希未变" "$L_HASH" "$(label_hash)"
dump_node cp1
check "默认污点仍存在（幂等后）" \
  taint_exists cp1 node-role.kubernetes.io/control-plane "" NoSchedule

echo "-- B9 牙齿：污点确实是 master 不可调度的原因"
make_pinned_pod() {  # make_pinned_pod <name> <file>
  cat >"$2" <<JSON
{"apiVersion":"v1","kind":"Pod",
 "metadata":{"name":"$1","namespace":"$NS","labels":{"app":"t013-teeth"}},
 "spec":{"nodeSelector":{"kubernetes.io/hostname":"cp1"},
   "containers":[{"name":"pause","image":"$IMAGE","imagePullPolicy":"IfNotPresent"}]}}
JSON
}
make_pinned_pod t013-pinned-blocked "$SB/client/pinned-blocked.json"
check "带污点时创建 pinned Pod（nodeSelector=cp1，无 toleration）" \
  kctl apply -f "$SB/client/pinned-blocked.json"
sleep 8
PINNED_NODE="$(kctl -n "$NS" get pod t013-pinned-blocked -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
check_eq "带污点时 pinned Pod 未被绑定（Pending）" "" "$PINNED_NODE"
check "调度失败事件包含 untolerated taint" \
  bash -c "'$KUBECTL' --kubeconfig '$SB/client/admin.conf' --cache-dir '$SB/client/kubectl-cache' -n '$NS' describe pod t013-pinned-blocked | grep -qi 'untolerated taint'"
check "调度失败事件包含控制面污点 key" \
  bash -c "'$KUBECTL' --kubeconfig '$SB/client/admin.conf' --cache-dir '$SB/client/kubectl-cache' -n '$NS' describe pod t013-pinned-blocked | grep -q 'control-plane'"

check "临时移除 cp1 控制面污点" \
  kctl taint node cp1 node-role.kubernetes.io/control-plane:NoSchedule-
dump_node cp1
check "污点已移除（反证前提）" \
  bash -c "! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(t.get(\"key\")==\"node-role.kubernetes.io/control-plane\" for t in (d[\"spec\"].get(\"taints\") or [])) else 1)' '$SB/client/node-cp1.json'"
make_pinned_pod t013-pinned-allowed "$SB/client/pinned-allowed.json"
check "无污点时创建同类 pinned Pod" kctl apply -f "$SB/client/pinned-allowed.json"
wait_pinned_allowed() {
  local i node
  for ((i = 0; i < 120; i++)); do
    node="$(kctl -n "$NS" get pod t013-pinned-allowed -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
    [[ "$node" == "cp1" ]] && return 0
    sleep 0.5
  done
  return 1
}
check "无污点时同类 Pod 被真实绑定到 cp1（证明污点才有牙齿）" wait_pinned_allowed
if ap "$PLAY_TAINT" /tmp/opencode/t013_taints_restore.log; then
  ok "重跑 role 恢复控制面污点 exit 0"
else
  bad "role 恢复污点失败（见 /tmp/opencode/t013_taints_restore.log）"
fi
check "恢复运行 changed>0（真实写回污点）" \
  test "$(changed_of /tmp/opencode/t013_taints_restore.log)" -gt 0
dump_node cp1
check "控制面污点已恢复" \
  taint_exists cp1 node-role.kubernetes.io/control-plane "" NoSchedule

echo "-- B10 fail-fast（不得改动真实污点）"
T_HASH_FF="$(taint_hash)"
rc=0
ap "$PLAY_TAINT" /tmp/opencode/t013_ff_effect.log \
  -e '{"taints_control_plane_taint_effect":"Bogus"}' || rc=$?
check "非法 effect → exit≠0" test "$rc" -ne 0
check "非法 effect → 错误信息提及 effect/白名单" \
  grep -qiE 'effect|NoSchedule|NoExecute|PreferNoSchedule' /tmp/opencode/t013_ff_effect.log
check_eq "非法 effect → 污点未变" "$T_HASH_FF" "$(taint_hash)"

rc=0
ap "$PLAY_TAINT_NODE" /tmp/opencode/t013_ff_nonmaster.log || rc=$?
check "非 [k8s_master] 主机 → exit≠0" test "$rc" -ne 0
check "非 [k8s_master] 主机 → 错误信息提及控制面分组" \
  grep -qiE 'k8s_master|control-plane' /tmp/opencode/t013_ff_nonmaster.log
check_eq "非控制面主机失败 → 污点未变" "$T_HASH_FF" "$(taint_hash)"

rc=0
ap "$PLAY_TAINT" /tmp/opencode/t013_ff_kubeconfig.log \
  -e '{"taints_kubeconfig":"/tmp/opencode/t013-missing/admin.conf"}' || rc=$?
check "缺 kubeconfig → exit≠0" test "$rc" -ne 0
check "缺 kubeconfig → 错误信息提及 kubeconfig" \
  grep -qi 'kubeconfig' /tmp/opencode/t013_ff_kubeconfig.log
check_eq "缺 kubeconfig 失败 → 污点未变" "$T_HASH_FF" "$(taint_hash)"

rc=0
ap "$PLAY_TAINT" /tmp/opencode/t013_ff_kubectl.log \
  -e '{"taints_kubectl":"/tmp/opencode/t013-missing/kubectl"}' || rc=$?
check "kubectl 不可执行 → exit≠0" test "$rc" -ne 0
check "kubectl 不可执行 → 错误信息提及 kubectl" \
  grep -qi 'kubectl' /tmp/opencode/t013_ff_kubectl.log
check_eq "kubectl 不可执行 → 污点未变" "$T_HASH_FF" "$(taint_hash)"

rc=0
ap "$PLAY_TAINT" /tmp/opencode/t013_ff_nodes_type.log \
  -e '{"taints_control_plane_nodes":"cp1"}' || rc=$?
check "目标节点为字符串（非列表）→ exit≠0" test "$rc" -ne 0
check "目标节点类型错误 → 错误信息可判定" \
  grep -qiE 'list|sequence|列表|节点' /tmp/opencode/t013_ff_nodes_type.log
check_eq "目标节点类型错误 → 污点未变" "$T_HASH_FF" "$(taint_hash)"

echo "-- B11 --check 干跑：rc=0 / changed=0 / 不写真实 API"
T_HASH_CHK="$(taint_hash)"
L_HASH_CHK="$(label_hash)"
rc=0
ap "$PLAY_TAINT" /tmp/opencode/t013_checkmode.log --check || rc=$?
check "--check 模式 exit 0" test "$rc" -eq 0
check_eq "--check 模式 changed=0" 0 "$(changed_of /tmp/opencode/t013_checkmode.log)"
check_eq "--check 后污点哈希不变" "$T_HASH_CHK" "$(taint_hash)"
check_eq "--check 后标签哈希不变" "$L_HASH_CHK" "$(label_hash)"
check "--check 日志无 from_json/解析失败" \
  bash -c "! grep -qiE 'from_json|Expecting value' /tmp/opencode/t013_checkmode.log"
if ap "$PLAY_TAINT" /tmp/opencode/t013_taints_run3.log; then
  ok "check 后真实应用 exit 0"
else
  bad "check 后真实应用失败（见 /tmp/opencode/t013_taints_run3.log）"
fi
check_eq "check 后真实应用 changed=0（状态已收敛）" 0 \
  "$(changed_of /tmp/opencode/t013_taints_run3.log)"

echo "-- C1 清理与宿主零污染"
stop_proc "$SB/usr/local/bin/kubelet"
stop_proc "$SB/usr/local/bin/containerd"
stop_proc "$SB/usr/local/bin/kube-scheduler"
stop_proc "$SB/usr/local/bin/kube-controller-manager"
stop_proc "$SB/usr/local/bin/kube-apiserver"
stop_proc "$SB/usr/local/bin/etcd"
restore_kernel_tunables
stop_new_kubepods_slices
for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
WRAPPER=()
all_stopped() {
  local b
  for b in kubelet containerd kube-scheduler kube-controller-manager kube-apiserver etcd; do
    proc_alive "$SB/usr/local/bin/$b" && return 1
  done
  return 0
}
check "沙箱进程已全部退出" all_stopped
check "高位端口全部释放（16443/20250/20248/12379/20257/20259）" wait_ports_free
check "沙箱 CRI socket 已随进程消失" test ! -S "$SOCK"
check "kubepods 清理仅停本次新建 slice 且无失败" test -z "$SLICE_STOP_ERRORS"

POST_HOST_SNAP=/tmp/opencode/t013_host_post.txt
if snapshot_with_retry "$POST_HOST_SNAP"; then
  ok "宿主快照已复采（内容级，重试机制可用）"
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
    "$PRE_KUBEPODS_SLICES" "$(snap_get "$POST_HOST_SNAP" kubepods_active)"
else
  bad "宿主快照复采失败（重试 3 次仍失败，不静默）"
fi
check_eq "roles/taints 文件内容在测试期间未被改动" "$ROLE_TREE_PRE" "$(role_tree_hash "$ROLE")"

sudo -n rm -rf "$SB"
check "沙箱已清理" test ! -e "$SB"
SB=""

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
