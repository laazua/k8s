#!/usr/bin/env bash
# =============================================================================
# T014 加节点流程验收测试（TDD：先红后绿）
#
#   静态：roles/add-node 结构/变量化/fail-fast 接线/不重建 CA 的接线/入口顺序/
#         syntax-check + yamllint/已 PASS 资产未被修改。
#   动态：同一宿主上搭「既有集群」（真实 etcd + apiserver + 既有 worker node1），
#         再用 playbooks/add-node.yml -l node2 真实装配一台新 worker
#         （独立 root/socket/端口/节点名），由**真实 kubelet** 注册进集群。
#   断言：注册 + Ready 条件 reason + kubelet.conf 身份 + RBAC 最小权限 +
#         系统组件清单/对象可判定面；**同一命令**连跑两次第二次 changed=0；
#         既有 node1/apiserver/etcd PID、配置/证书哈希、集群 etc_kubernetes 全树哈希不变。
#   牙齿：篡改 node2 kubelet.conf 后重跑必须 changed>0 并复原；快照比较器自检；
#         fail-fast 矩阵（非 k8s_node 主机/缺 CA/缺 CA 私钥/preissued 缺证书/版本不兼容/缺 kubeconfig）。
#   宿主：不写 /etc/kubernetes、/etc/systemd/system，不 systemctl start/stop；
#         退出恢复 kernel.panic*，只停本次运行新建的 kubepods* slice。
#   受限：无镜像 → 系统 Pod 不 Running（SKIP 计数，不计入 PASS）；
#         「新节点」是同宿主的第二套运行时，不覆盖真实跨主机 join（契约 §5）。
#
#   用法: tests/add-node/test_add_node_flow.sh
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
mkdir -p /tmp/opencode

pass_count=0
fail=0
skip_count=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
skipped() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip_count=$((skip_count + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
check_eq() { local d="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok "$d"; else bad "$d [期望=$want 实际=${got:-<空>}]"; fi; }
changed_of() { grep -oE 'changed=[0-9]+' "$1" 2>/dev/null | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# --- Ansible / yamllint 探测 -------------------------------------------------
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

ROLE=roles/add-node
PLAY_ADD=playbooks/add-node.yml
INV=tests/add-node/inventory.ini
PLAY_STACK=tests/add-node/sandbox_stack.yml
PLAY_NODE1=tests/add-node/sandbox_node1.yml
PLAY_NODE1_KL=tests/add-node/sandbox_node1_kubelet.yml
PLAY_NONMEMBER=tests/add-node/sandbox_add_node_nonmember.yml
PLAY_NODE2_CD=tests/add-node/sandbox_node2_containerd.yml
ADDONS_RENDER=tests/cluster-addons/render.yml
UNIT_EXEC=tests/etcd/unit_exec.py

role_tree_hash() {
  find "$1" -type f -print0 2>/dev/null | sort -z \
    | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
}
ROLE_TREE_PRE="$(role_tree_hash "$ROLE")"

VERSION=1.31.0
CONTAINERD_VERSION=2.0.0
RUNC_VERSION=1.2.1
CNI_VERSION=1.5.1
CRICTL_VERSION=1.31.1
CACHE="${T014_TEST_CACHE:-/tmp/opencode/k8s-cache}"
ETCD_TARBALL=etcd-v3.5.16-linux-amd64.tar.gz
ETCD_TARBALL_SHA=b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc
CONTAINERD_TARBALL="containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
CNI_TARBALL="cni-plugins-linux-amd64-v${CNI_VERSION}.tgz"
CRICTL_TARBALL="crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz"

declare -A ART_URL=(
  [kube-apiserver]="https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kube-apiserver"
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
  for n in kube-apiserver kubectl kubelet "$CONTAINERD_TARBALL" runc.amd64 \
    "$CNI_TARBALL" "$CRICTL_TARBALL"; do
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
    T014_TEST_CACHE="$CACHE" \
    ETCD_TEST_CACHE="${ETCD_TEST_CACHE:-}" \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=safe.directory \
    GIT_CONFIG_VALUE_0="$PWD" \
    bash "$(readlink -f "$0")"
fi

# --- 宿主快照（内容级；采集失败重试 + 显式 FAIL，不静默） --------------------
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
  # 内容级：普通文件内容 + 符号链接目标都要覆盖（本机 unit 多为符号链接）；
  # 0 条目不是合法基线，用 __EMPTY__ 显式标记（T018/D5）。
  local list h
  list="$(sudo -n find /etc/systemd/system -maxdepth 2 \( -type f -o -type l \) \
    \( -name '*.service' -o -name '*.socket' -o -name '*.timer' \
       -o -name '*.mount' -o -name '*.slice' \) \
    -printf '%p|%y|%l\n' 2>/dev/null | sort)"
  if [[ -z "$list" ]]; then printf '__EMPTY__'; return 0; fi
  h="$( { printf '%s\n' "$list"
          sudo -n find /etc/systemd/system -maxdepth 2 -type f \
            \( -name '*.service' -o -name '*.socket' -o -name '*.timer' \
               -o -name '*.mount' -o -name '*.slice' \) -print0 2>/dev/null \
            | sort -z | xargs -0 -r sha256sum 2>/dev/null
        } | sha256sum | awk '{print $1}' )"
  if [[ -n "$h" ]]; then printf '%s' "$h"; else printf '__ERROR__'; fi
}
kubepods_active() {
  systemctl list-units 'kubepods*' --no-legend 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' '
}
kubepods_loaded() {
  systemctl list-units --all 'kubepods*' --no-legend 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' '
}
# --- 快照载荷守卫（T018/D1：空值/哨兵/缺键必须显式 FAIL，不静默比较） --------
# 合法例外：路径键在本机可以不存在（__MISSING__）；ports 允许为空（=无占用）。
SNAP_ALLOW_MISSING=" etc_kubernetes var_lib_containerd run_containerd opt_cni_bin "
SNAP_ALLOW_EMPTY=" ports "
SNAP_HOST_KEYS="etc_kubernetes systemd_units var_lib_containerd run_containerd \
opt_cni_bin ports kernel_panic kernel_panic_on_oops kubepods_active kubepods_loaded"
SNAP_EXIST_KEYS="node1_kubelet_pid node1_kubelet_start apiserver_pid apiserver_start \
etcd_pid etcd_start node1_files node1_obj cluster_etc_kubernetes cluster_ca_cert cluster_ca_key"
snapshot_invalid_keys() {  # 逐键：空值 / __ERROR__ / __EMPTY__ / 非白名单 __MISSING__
  local f="$1" k v
  while IFS= read -r line; do
    k="${line%%=*}"
    v="${line#*=}"
    [[ -z "$k" ]] && continue
    if [[ -z "$v" ]]; then
      [[ "$SNAP_ALLOW_EMPTY" == *" $k "* ]] || printf '%s ' "$k"
    elif [[ "$v" == "__ERROR__" || "$v" == "__EMPTY__" ]]; then
      printf '%s ' "$k"
    elif [[ "$v" == "__MISSING__" && "$SNAP_ALLOW_MISSING" != *" $k "* ]]; then
      printf '%s ' "$k"
    fi
  done <"$f"
}
snapshot_missing_keys() {  # 必需键缺失（比较器不能对「键不存在」静默）
  local f="$1" k
  shift
  for k in "$@"; do
    grep -q "^$k=" "$f" 2>/dev/null || printf '%s(缺失) ' "$k"
  done
}
snapshot_problems() {  # <file> <必需键...>；输出无效/缺失键，空输出=有载荷
  local f="$1"
  shift
  printf '%s%s' "$(snapshot_invalid_keys "$f")" "$(snapshot_missing_keys "$f" "$@")"
}

PORTS_RE=':(16443|12379|20250|20248|20251|20249)[[:space:]]'
snapshot_ports() {
  ss -ltn 2>/dev/null | grep -E "$PORTS_RE" | awk '{print $4}' | sort | tr '\n' ' '
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
    printf 'kernel_panic=%s\n' "$(cat /proc/sys/kernel/panic 2>/dev/null || echo __ERROR__)"
    printf 'kernel_panic_on_oops=%s\n' "$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null || echo __ERROR__)"
    printf 'kubepods_active=%s\n' "$(kubepods_active)"
    printf 'kubepods_loaded=%s\n' "$(kubepods_loaded)"
  } >"$out" 2>/dev/null
  # 逐键载荷守卫：空值/__ERROR__/__EMPTY__/缺键 → 采集失败（调用方重试后显式 FAIL）
  [[ -z "$(snapshot_problems "$out" $SNAP_HOST_KEYS)" ]]
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

echo "-- A0 快照守卫负例（空值/哨兵/缺失键必须显式判无效，不是只靠人工复现）"
NEG_SNAP_DIR="$(mktemp -d /tmp/opencode/t018-snapneg.XXXXXX)"
printf 'node1_obj=\napiserver_start=__ERROR__\nkubepods_loaded=__EMPTY__\nports=\n' \
  >"$NEG_SNAP_DIR/neg.txt"
NEG_BAD="$(snapshot_invalid_keys "$NEG_SNAP_DIR/neg.txt")"
NEG_MISSING="$(snapshot_missing_keys "$NEG_SNAP_DIR/neg.txt" etcd_start)"
for k in node1_obj apiserver_start kubepods_loaded; do
  check "负例：$k 的空值/哨兵被显式判无效并打印键名" \
    bash -c "[[ \"$NEG_BAD\" == *'$k'* ]]"
done
check_not "负例：合法的空 ports 不被误判" bash -c "[[ \"$NEG_BAD\" == *'ports'* ]]"
check "负例：缺失键 etcd_start 被显式判无效" bash -c "[[ \"$NEG_MISSING\" == *'etcd_start'* ]]"
printf 'node1_obj=abc\nports=\n' >"$NEG_SNAP_DIR/ok.txt"
check "正例：有载荷的快照通过守卫（证明负例不是恒真）" \
  bash -c "[[ -z \"$(snapshot_problems "$NEG_SNAP_DIR/ok.txt" node1_obj)\" ]]"
sudo -n rm -rf "$NEG_SNAP_DIR"

PRE_HOST_SNAP=/tmp/opencode/t014_host_pre.txt
if ! snapshot_with_retry "$PRE_HOST_SNAP"; then
  bad "宿主快照采集失败或含无效键（重试 3 次）：$(snapshot_problems "$PRE_HOST_SNAP" $SNAP_HOST_KEYS)"
  echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) SKIP=$skip_count =="
  exit 1
fi
ok "宿主快照已采集（内容级：/etc/kubernetes、unit 集合、containerd、端口、sysctl、kubepods）"
check "宿主快照逐键有载荷（路径键可为 __MISSING__，其余非空非哨兵）" \
  test -z "$(snapshot_problems "$PRE_HOST_SNAP" $SNAP_HOST_KEYS)"
EMPTY_STREAM_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
check_not "宿主 unit 集合基线不是空流哈希（符号链接目标已纳入，D5）" \
  bash -c "[[ '$(snap_get "$PRE_HOST_SNAP" systemd_units)' == '$EMPTY_STREAM_SHA' ]]"
PRE_KERNEL_PANIC="$(snap_get "$PRE_HOST_SNAP" kernel_panic)"
PRE_KERNEL_PANIC_ON_OOPS="$(snap_get "$PRE_HOST_SNAP" kernel_panic_on_oops)"
PRE_KUBEPODS_ACTIVE="$(snap_get "$PRE_HOST_SNAP" kubepods_active)"
PRE_KUBEPODS_LOADED="$(snap_get "$PRE_HOST_SNAP" kubepods_loaded)"
SLICE_STOP_ERRORS=""
SLICES_STOPPED=0
stop_new_kubepods_slices() {
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
cleanup() {
  local k
  restore_kernel_tunables
  for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
  [[ -n "${SB:-}" ]] || return 0
  stop_proc "$SB/node2/usr/local/bin/kubelet"
  stop_proc "$SB/node1/usr/local/bin/kubelet"
  stop_proc "$SB/node2/usr/local/bin/containerd"
  stop_proc "$SB/node1/usr/local/bin/containerd"
  stop_proc "$SB/usr/local/bin/kube-apiserver"
  stop_proc "$SB/usr/local/bin/etcd"
  stop_new_kubepods_slices
  sudo -n rm -rf "$SB" 2>/dev/null || true
}
trap cleanup EXIT

proc_pid_path() { pgrep -f -- "^$1( |$)" 2>/dev/null | head -1; }
proc_alive_path() {
  local exe p
  exe="$(readlink -f "$1" 2>/dev/null)" || return 1
  [[ -n "$exe" ]] || return 1
  for p in /proc/[0-9]*; do
    [[ "$(readlink "$p/exe" 2>/dev/null)" == "$exe" ]] && return 0
  done
  return 1
}
proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
unit_path() { printf '%s/%s' "$1" "$2"; }
wait_ports_free() {
  local i
  for ((i = 0; i < 60; i++)); do
    [[ -z "$(snapshot_ports)" ]] && return 0
    sleep 0.5
  done
  return 1
}

echo "== T014 加节点流程验收 =="

echo "-- A1 role / 测试资产结构"
for f in defaults/main.yml tasks/main.yml tasks/validate.yml tasks/cert.yml \
  tasks/verify.yml meta/main.yml README.md; do
  check "存在 $ROLE/$f" test -f "$ROLE/$f"
done
for f in "$INV" tests/add-node/README.md "$PLAY_STACK" "$PLAY_NODE1" "$PLAY_NODE1_KL" \
  "$PLAY_NONMEMBER" "$PLAY_NODE2_CD"; do
  check "存在 $f" test -f "$f"
done
check "存在入口 $PLAY_ADD" test -f "$PLAY_ADD"
check "存在 Makefile 目标 test-add-node" grep -qE '^test-add-node:' Makefile
check "make test 挂载 test_add_node_flow.sh" \
  bash -c "awk '/^test:/{f=1} f&&/^[a-zA-Z0-9_-]+:/{if(\$0!~/^test:/)exit} f' Makefile | grep -q 'tests/add-node/test_add_node_flow.sh'"
for p in "$PLAY_STACK" "$PLAY_NODE1" "$PLAY_NODE1_KL" "$PLAY_NONMEMBER" "$PLAY_NODE2_CD" "$INV"; do
  check "sandbox 资产不写宿主 /etc/systemd/system：$p" bash -c "! grep -q '/etc/systemd/system' '$p'"
done

echo "-- A2 变量化 / 安全接线（静态）"
check "defaults 定义节点根前缀" grep -qE '^add_node_root_prefix:' "$ROLE/defaults/main.yml"
check "defaults 定义目标分组" grep -qE '^add_node_target_group:' "$ROLE/defaults/main.yml"
check "defaults 目标分组默认 k8s_node" grep -qE '^add_node_target_group:[[:space:]]*"?k8s_node"?' "$ROLE/defaults/main.yml"
check "defaults 定义禁止分组（控制面/etcd）" grep -qE '^add_node_forbidden_groups:' "$ROLE/defaults/main.yml"
check "defaults 证书模式可配（sign/preissued）" \
  bash -c "grep -qE '^add_node_cert_mode:' '$ROLE/defaults/main.yml' && grep -q 'preissued' '$ROLE/defaults/main.yml'"
check "defaults 定义集群 CA 证书/私钥路径" \
  bash -c "grep -qE '^add_node_ca_cert:' '$ROLE/defaults/main.yml' && grep -qE '^add_node_ca_key:' '$ROLE/defaults/main.yml'"
check "defaults 定义 kubelet 证书/私钥路径" \
  bash -c "grep -qE '^add_node_kubelet_cert:' '$ROLE/defaults/main.yml' && grep -qE '^add_node_kubelet_key:' '$ROLE/defaults/main.yml'"
check "defaults 定义版本兼容开关" grep -qE '^add_node_allow_minor_skew:' "$ROLE/defaults/main.yml"
check "defaults 定义集群/ kubelet 版本来源" \
  bash -c "grep -qE '^add_node_cluster_version:' '$ROLE/defaults/main.yml' && grep -qE '^add_node_kubelet_version:' '$ROLE/defaults/main.yml'"
check "defaults 定义 verify kubeconfig/kubectl/重试" \
  bash -c "grep -qE '^add_node_verify_kubeconfig:' '$ROLE/defaults/main.yml' && grep -qE '^add_node_verify_kubectl:' '$ROLE/defaults/main.yml' && grep -qE '^add_node_verify_retries:' '$ROLE/defaults/main.yml'"
check "defaults 定义 verify 开关与 delegate" \
  bash -c "grep -qE '^add_node_verify_registration:' '$ROLE/defaults/main.yml' && grep -qE '^add_node_verify_delegate:' '$ROLE/defaults/main.yml'"
check "defaults 定义主机级任务开关（沙箱可关）" grep -qE '^add_node_manage_host:' "$ROLE/defaults/main.yml"
check "validate 断言目标分组成员身份" grep -q 'add_node_target_group' "$ROLE/tasks/validate.yml"
check "validate 断言禁止分组冲突" grep -q 'add_node_forbidden_groups' "$ROLE/tasks/validate.yml"
check "validate 断言 CA 证书存在（stat）" grep -q 'add_node_ca_cert' "$ROLE/tasks/validate.yml"
check "validate 断言 sign 模式需要 CA 私钥" grep -q 'add_node_ca_key' "$ROLE/tasks/validate.yml"
check "validate 断言 preissued 模式需要既有证书" grep -q 'add_node_cert_mode' "$ROLE/tasks/validate.yml"
check "validate 断言 kubelet 版本兼容" grep -q 'add_node_kubelet_version' "$ROLE/tasks/validate.yml"
check "validate 断言 verify 的 kubeconfig/kubectl 可用" grep -q 'add_node_verify_kubeconfig' "$ROLE/tasks/validate.yml"
check "validate 检测已加入并显式跳过（幂等）" grep -q 'add_node_already_joined' "$ROLE/tasks/validate.yml"
check "cert 使用 pki tasks_from: cert（只签发，不建 CA）" grep -q 'tasks_from: cert' "$ROLE/tasks/cert.yml"
check "cert 显式传 pki_ca_rebuilt（否则每次重签）" grep -q 'pki_ca_rebuilt' "$ROLE/tasks/cert.yml"
check_not "cert 不 include pki 的 ca/main（绝不重建 CA）" \
  bash -c "grep -qE 'tasks_from: (ca|main)$' '$ROLE/tasks/cert.yml'"
check "cert 断言 CA 证书哈希未变" grep -q 'add_node_ca_cert_sha' "$ROLE/tasks/cert.yml"
check "cert 断言 CA 私钥哈希未变" grep -q 'add_node_ca_key_sha' "$ROLE/tasks/cert.yml"
check "defaults 定义证书幂等状态记录路径（内容哈希基线）" \
  grep -qE '^add_node_cert_state_file:' "$ROLE/defaults/main.yml"
check "validate 逐键读取状态记录并拒绝被替换的 CA" \
  bash -c "grep -q 'add_node_cert_state_file' '$ROLE/tasks/validate.yml' && grep -q 'add_node_ca_tampered' '$ROLE/tasks/validate.yml'"
check "cert 仅在自愈时强制重签（pki_force_regen 接线）" \
  grep -q 'pki_force_regen' "$ROLE/tasks/cert.yml"
check "cert 写任务在 check 模式跳过（签发/状态/清理）" \
  bash -c "[[ \$(grep -c 'not ansible_check_mode' '$ROLE/tasks/cert.yml') -ge 3 ]]"
check "verify 断言 NotReady 必须给出 reason（载荷，D6）" \
  grep -q 'add_node_verify_reason.stdout' "$ROLE/tasks/verify.yml"
check "verify 断言 kubelet.conf 权限 0600" grep -q '0600' "$ROLE/tasks/verify.yml"
check "verify 断言新节点无 admin 凭据" grep -q 'admin' "$ROLE/tasks/verify.yml"
check "verify 用 kubectl argv 读回 node（非字符串命令）" grep -q 'argv:' "$ROLE/tasks/verify.yml"
check_not "role 不使用 ansible.builtin.shell" grep -rqE 'ansible\.builtin\.shell' "$ROLE/tasks"
check_not "role 不调用 systemctl" grep -rqE 'systemctl' "$ROLE/tasks" "$ROLE/defaults"
check_not "role 不硬编码默认端口 6443/10250" grep -rqE '(6443|10250)' "$ROLE/tasks" "$ROLE/defaults"
check "只读 command 显式 check_mode: false" grep -q 'check_mode: false' "$ROLE/tasks/cert.yml"
check "写任务在 check 模式被跳过（not ansible_check_mode）" \
  bash -c "grep -rq 'not ansible_check_mode' '$ROLE/tasks'"

echo "-- A3 入口是真实实现（不是占位）"
check_not "入口无 Placeholder" grep -qi 'placeholder' "$PLAY_ADD"
check_not "入口无 pending 占位" grep -qi 'pending' "$PLAY_ADD"
check "入口 hosts: k8s_node" grep -qE '^[[:space:]]*hosts:[[:space:]]*k8s_node[[:space:]]*$' "$PLAY_ADD"
check "入口 serial: 1" grep -qE '^[[:space:]]*serial:[[:space:]]*1[[:space:]]*$' "$PLAY_ADD"
check "入口带 add-node tag" grep -qE 'tags:.*add-node' "$PLAY_ADD"
check "入口复用 base role" grep -qE '^[[:space:]]*- role: base' "$PLAY_ADD"
check "入口复用 containerd role" grep -qE '^[[:space:]]*- role: containerd' "$PLAY_ADD"
check "入口复用 kubelet role" grep -qE '^[[:space:]]*- role: kubelet' "$PLAY_ADD"
check "入口复用 add-node role" grep -qE '^[[:space:]]*- role: add-node' "$PLAY_ADD"
check "base role 由 add_node_manage_host 门控（沙箱可关）" \
  bash -c "grep -A3 -E '^[[:space:]]*- role: base' '$PLAY_ADD' | grep -q 'add_node_manage_host'"

echo "-- A4 语法 / 风格 / 冻结资产"
for p in "$PLAY_ADD" "$PLAY_STACK" "$PLAY_NODE1" "$PLAY_NODE1_KL" "$PLAY_NONMEMBER" "$PLAY_NODE2_CD"; do
  check "syntax-check $p" "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$p"
done
check "yamllint role + tests/add-node + 入口" \
  "$YAMLLINT" -c .yamllint "$ROLE" tests/add-node "$PLAY_ADD"
check "已 PASS 的 role 未被修改（工作区含未跟踪文件）" \
  bash -c "[[ -z \"\$(git status --porcelain --untracked-files=all -- \
    roles/base roles/download roles/pki roles/etcd roles/haproxy roles/keepalived \
    roles/kube-apiserver roles/kube-controller-manager roles/kube-scheduler \
    roles/containerd roles/kubelet roles/kube-proxy roles/cilium roles/cluster-addons \
    roles/taints)\" ]]"
ROLE_FILE_COUNT="$(find "$ROLE" -type f 2>/dev/null | wc -l)"
check "roles/add-node 文件数 > 0 且全量内容哈希已计算（D8：非恒真）" \
  bash -c "[[ $ROLE_FILE_COUNT -gt 0 && -n '$ROLE_TREE_PRE' ]]"
"$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_ADD" --list-tasks --tags add-node \
  >/tmp/opencode/t014_list_tasks.log 2>&1
check "入口 --list-tasks --tags add-node 非空" \
  bash -c "[[ \$(grep -cE 'TASK|add-node:' /tmp/opencode/t014_list_tasks.log) -gt 5 ]]"
check "入口任务顺序：validate → cert → containerd → kubelet → verify" \
  python3 - /tmp/opencode/t014_list_tasks.log <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
order = ["add-node:validate", "add-node:cert", "containerd:", "kubelet:", "add-node:verify"]
pos = []
for key in order:
    i = text.find(key)
    if i < 0:
        sys.exit(1)
    pos.append(i)
sys.exit(0 if pos == sorted(pos) else 1)
PY
check "契约 §5 真机命令指向 playbooks/add-node.yml" \
  grep -q 'playbooks/add-node.yml' docs/harness/state/contracts/T014.md
check "tests/add-node/README.md 指向 playbooks/add-node.yml" \
  grep -q 'playbooks/add-node.yml' tests/add-node/README.md
check "roles/add-node/README.md 指向 playbooks/add-node.yml" \
  grep -q 'playbooks/add-node.yml' "$ROLE/README.md"

echo "-- B0 制品缓存 / 沙箱自举"
PRE_PORTS="$(snap_get "$PRE_HOST_SNAP" ports)"
if [[ -n "$PRE_PORTS" ]]; then
  bad "高位端口已被占用（$PRE_PORTS），请先停止残留进程"
  echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) SKIP=$skip_count =="
  exit 1
fi
if ! prefill_cache; then
  bad "无法准备官方制品缓存（见上方 curl 错误）"
  echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) SKIP=$skip_count =="
  exit 1
fi
ok "官方制品缓存命中（apiserver/kubelet/kubectl/etcd/containerd/runc/cni/crictl）"

SB="$(mktemp -d /tmp/opencode/t014.XXXXXX)"
chmod 0755 "$SB"
mkdir -p "$SB/opt/k8s/artifacts" "$SB/logs" "$SB/client" "$SB/etc" "$SB/var"
chmod 0755 "$SB/etc" "$SB/var"
for n in "${!ART_SHA[@]}"; do
  cp "$CACHE/$n" "$SB/opt/k8s/artifacts/$n"
  mkdir -p "$SB/node1/opt/k8s/artifacts" "$SB/node2/opt/k8s/artifacts"
  cp -l "$CACHE/$n" "$SB/node1/opt/k8s/artifacts/$n" 2>/dev/null \
    || cp "$CACHE/$n" "$SB/node1/opt/k8s/artifacts/$n"
  cp -l "$CACHE/$n" "$SB/node2/opt/k8s/artifacts/$n" 2>/dev/null \
    || cp "$CACHE/$n" "$SB/node2/opt/k8s/artifacts/$n"
done
sudo -n chown -R root:root "$SB/opt/k8s/artifacts" "$SB/node1/opt/k8s/artifacts" "$SB/node2/opt/k8s/artifacts"
sudo -n chmod 0644 "$SB"/opt/k8s/artifacts/* "$SB"/node1/opt/k8s/artifacts/* "$SB"/node2/opt/k8s/artifacts/*
ok "沙箱制品已就绪（$SB）"

ap() {  # ap <playbook> <log> [额外的 -e ...]
  local play="$1" log="$2"
  shift 2
  timeout 900 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" -e "{\"sandbox_root\":\"$SB\"}" "$@" >"$log" 2>&1
}

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
ap_addnode() {  # ap_addnode <log> [额外参数...]
  local log="$1"
  shift
  timeout 1200 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_ADD" -l node2 \
    -e "@$SB/addnode-vars.json" "$@" >"$log" 2>&1
}

echo "-- B1 既有集群自举（真实 etcd + apiserver + 既有 worker node1）"
if ap "$PLAY_STACK" "$SB/logs/stack.log"; then
  ok "stack playbook exit 0（kubectl + pki + etcd + apiserver 渲染）"
else
  bad "stack playbook 失败（见 $SB/logs/stack.log）"
fi
check "kubernetes-ca 已签发（集群根）" test -f "$SB/etc/kubernetes/pki/ca.crt"
check "node1 kubelet 证书已预签（既有节点）" test -f "$SB/etc/kubernetes/pki/kubelet/node1.crt"
check_not "node2 kubelet 证书未被预签（否则首跑 changed 不可判定）" \
  test -f "$SB/etc/kubernetes/pki/kubelet/node2.crt"
check "kubectl 已安装到沙箱" test -x "$SB/usr/local/bin/kubectl"

start_unit() {  # start_unit <name> <unit> <log> [uid]
  local name="$1" unit="$2" log="$3" uid="${4:-}" arr=()
  mapfile -t arr < <(python3 "$UNIT_EXEC" "$unit" 2>/dev/null)
  [[ ${#arr[@]} -gt 0 ]] || return 1
  if [[ -n "$uid" ]]; then
    ( sudo -n setpriv --reuid "$uid" --regid "$uid" --clear-groups \
        "${arr[@]}" </dev/null >>"$log" 2>&1 ) &
  else
    ( sudo -n "${arr[@]}" </dev/null >>"$log" 2>&1 ) &
  fi
  WRAPPER[$name]=$!
  return 0
}

ETCD_UNIT="$(unit_path "$SB/etc/systemd/system" etcd-etcd1.service)"
if start_unit etcd "$ETCD_UNIT" "$SB/logs/etcd.log" 65534; then
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

UNIT_API="$(unit_path "$SB/etc/systemd/system" kube-apiserver.service)"
if start_unit apiserver "$UNIT_API" "$SB/logs/apiserver.log"; then
  ok "已从 unit 拉起 kube-apiserver"
else
  bad "无法解析 apiserver unit 的 ExecStart"
fi
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
check "kubectl get --raw /healthz = ok" wait_healthz

if ap "$ADDONS_RENDER" "$SB/logs/addons.log" -e '{"cluster_addons_kubelet_node":"node1"}'; then
  ok "cluster-addons 渲染（admin.conf / kubelet.conf / RBAC / CoreDNS 清单）"
else
  bad "cluster-addons 渲染失败（见 $SB/logs/addons.log）"
fi
ADDONS_MANIFESTS="$SB/etc/kubernetes/addons/manifests"
check "RBAC 清单存在" test -f "$ADDONS_MANIFESTS/rbac.yaml"
check "CoreDNS 清单存在" test -f "$ADDONS_MANIFESTS/coredns.yaml"
check "RBAC 清单可 apply（真实 apiserver）" kctl apply -f "$ADDONS_MANIFESTS/rbac.yaml"
check "CoreDNS 清单可 apply（真实 apiserver）" kctl apply -f "$ADDONS_MANIFESTS/coredns.yaml"

# 既有 worker node1：containerd（先拉起）→ kubelet
if ap "$PLAY_NODE1" "$SB/logs/node1_cd.log" -l node1; then
  ok "既有 node1 containerd 沙箱装配 exit 0"
else
  bad "既有 node1 containerd 装配失败（见 $SB/logs/node1_cd.log）"
fi
CD1_UNIT="$(unit_path "$SB/node1/etc/systemd/system" containerd.service)"
KL1_UNIT="$(unit_path "$SB/node1/etc/systemd/system" kubelet.service)"
check "node1 containerd unit 已渲染" test -f "$CD1_UNIT"
if start_unit cd1 "$CD1_UNIT" "$SB/logs/cd1.log"; then
  ok "已拉起 node1 containerd"
else
  bad "无法解析 node1 containerd ExecStart"
fi
wait_sock1() { local i; for ((i = 0; i < 120; i++)); do [[ -S "$SB/node1/run/containerd/containerd.sock" ]] && return 0; sleep 0.25; done; return 1; }
check "node1 containerd CRI socket 已创建" wait_sock1
if ap "$PLAY_NODE1_KL" "$SB/logs/node1_kl.log" -l node1; then
  ok "既有 node1 kubelet 沙箱装配 exit 0"
else
  bad "既有 node1 kubelet 装配失败（见 $SB/logs/node1_kl.log）"
fi
check "node1 kubelet unit 已渲染" test -f "$KL1_UNIT"
if start_unit kl1 "$KL1_UNIT" "$SB/logs/kl1.log"; then
  ok "已拉起 node1 真实 kubelet"
else
  bad "无法解析 node1 kubelet ExecStart"
fi
wait_node() {  # wait_node <name>
  local i
  for ((i = 0; i < 240; i++)); do
    kctl get node "$1" -o name 2>/dev/null | grep -qx "node/$1" && return 0
    sleep 0.5
  done
  return 1
}
check "node1 已注册（既有节点基线）" wait_node node1
PID[node1_kubelet]="$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")"
PID[apiserver]="$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")"
PID[etcd]="$(proc_pid_path "$SB/usr/local/bin/etcd")"
check "node1 kubelet PID 可读（空值必须显式失败）" test -n "${PID[node1_kubelet]}"
check "apiserver PID 可读（空值必须显式失败）" test -n "${PID[apiserver]}"
check "etcd PID 可读（空值必须显式失败）" test -n "${PID[etcd]}"

fhash() {
  local h
  h="$(sudo -n sha256sum "$1" 2>/dev/null | awk '{print $1}')"
  [[ -n "$h" ]] && printf '%s' "$h" || printf '__MISSING__'
}
node1_conf_hash() {
  printf '%s|%s|%s|%s|%s' \
    "$(fhash "$SB/node1/var/lib/kubelet/kubelet.conf")" \
    "$(fhash "$SB/node1/var/lib/kubelet/config.yaml")" \
    "$(fhash "$SB/node1/etc/kubernetes/pki/ca.crt")" \
    "$(fhash "$SB/node1/etc/kubernetes/pki/kubelet/node1.crt")" \
    "$(fhash "$SB/node1/etc/kubernetes/pki/kubelet/node1.key")"
}
node_obj_hash() {  # node_obj_hash <name>：只取稳定字段（uid/labels/spec），status 会持续变化
  kctl get node "$1" -o json 2>/dev/null | python3 -c '
import json, sys, hashlib
d = json.load(sys.stdin)
stable = {"uid": d["metadata"].get("uid"),
          "labels": d["metadata"].get("labels") or {},
          "spec": d.get("spec") or {}}
print(hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest())
'
}
node_uid() { kctl get node "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null; }
node_ready() { kctl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
node_reason() { kctl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null; }

PRE_EXIST=/tmp/opencode/t014_existing_pre.txt
{
  printf 'node1_kubelet_pid=%s\n' "${PID[node1_kubelet]}"
  printf 'node1_kubelet_start=%s\n' "$(proc_starttime "${PID[node1_kubelet]}")"
  printf 'apiserver_pid=%s\n' "${PID[apiserver]}"
  printf 'apiserver_start=%s\n' "$(proc_starttime "${PID[apiserver]}")"
  printf 'etcd_pid=%s\n' "${PID[etcd]}"
  printf 'etcd_start=%s\n' "$(proc_starttime "${PID[etcd]}")"
  printf 'node1_files=%s\n' "$(node1_conf_hash)"
  printf 'node1_obj=%s\n' "$(node_obj_hash node1)"
  printf 'cluster_etc_kubernetes=%s\n' "$(tree_hash "$SB/etc/kubernetes")"
  printf 'cluster_ca_cert=%s\n' "$(fhash "$SB/etc/kubernetes/pki/ca.crt")"
  printf 'cluster_ca_key=%s\n' "$(fhash "$SB/etc/kubernetes/pki/ca.key")"
} >"$PRE_EXIST" 2>/dev/null
PRE_EXIST_PROBLEMS="$(snapshot_problems "$PRE_EXIST" $SNAP_EXIST_KEYS)"
if [[ -n "$PRE_EXIST_PROBLEMS" ]]; then
  bad "既有状态快照含空值/哨兵/缺键：$PRE_EXIST_PROBLEMS（禁止空==空 静默通过，T018/D1）"
else
  ok "既有状态快照逐键有载荷（PID/启动时间/配置哈希/Node 对象/集群 PKI）"
fi
ex_pre() { snap_get "$PRE_EXIST" "$1"; }

echo "-- B2 fail-fast（必须在任何落盘/签发之前拒绝）"
CA_CERT="$SB/node2/etc/kubernetes/pki/ca.crt"
CA_KEY="$SB/node2/etc/kubernetes/pki/ca.key"
NODE2_CERT="$SB/node2/etc/kubernetes/pki/kubelet/node2.crt"
NODE2_KEY="$SB/node2/etc/kubernetes/pki/kubelet/node2.key"
mkdir -p "$SB/node2/etc/kubernetes/pki/kubelet"
sudo -n install -m 0644 "$SB/etc/kubernetes/pki/ca.crt" "$CA_CERT"
sudo -n install -m 0600 "$SB/etc/kubernetes/pki/ca.key" "$CA_KEY"
CA_CERT_HASH0="$(fhash "$CA_CERT")"
CA_KEY_HASH0="$(fhash "$CA_KEY")"

rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_NONMEMBER" \
  -e "{\"sandbox_root\":\"$SB\"}" >"$SB/logs/ff_nonmember.log" 2>&1 || rc=$?
check "非 [k8s_node] 主机 → exit≠0" test "$rc" -ne 0
check "非 [k8s_node] 主机 → 信息含分组名" grep -qiE 'k8s_node|分组' "$SB/logs/ff_nonmember.log"
nonmember_artifacts() {
  sudo -n find "$SB/nonmember" \( -name '*.crt' -o -name '*.key' -o -name '*.state' \) \
    -print 2>/dev/null
}
check "非 [k8s_node] 主机 → 自身前缀内无证书/私钥/状态（D3：断言目标与 play 一致）" \
  test -z "$(nonmember_artifacts)"

sudo -n mv "$CA_CERT" "$SB/client/ca.crt.bak"
rc=0
ap_addnode "$SB/logs/ff_noca.log" || rc=$?
check "缺集群 CA 证书 → exit≠0" test "$rc" -ne 0
check "缺集群 CA 证书 → 信息含 CA" grep -qiE 'CA|ca\.crt' "$SB/logs/ff_noca.log"
check "缺集群 CA 证书 → 未生成新 CA（绝不重建）" test ! -f "$CA_CERT"
check_not "缺集群 CA 证书 → 未签发 kubelet 证书" test -f "$NODE2_CERT"
sudo -n mv "$SB/client/ca.crt.bak" "$CA_CERT"
check_eq "恢复后 CA 证书哈希不变" "$CA_CERT_HASH0" "$(fhash "$CA_CERT")"

sudo -n mv "$CA_KEY" "$SB/client/ca.key.bak"
rc=0
ap_addnode "$SB/logs/ff_nokey.log" || rc=$?
check "sign 模式缺 CA 私钥 → exit≠0" test "$rc" -ne 0
check "sign 模式缺 CA 私钥 → 信息含私钥/CA" grep -qiE 'CA|私钥|ca\.key' "$SB/logs/ff_nokey.log"
check "sign 模式缺 CA 私钥 → 未生成新 CA 私钥" test ! -f "$CA_KEY"
sudo -n mv "$SB/client/ca.key.bak" "$CA_KEY"
check_eq "恢复后 CA 私钥哈希不变" "$CA_KEY_HASH0" "$(fhash "$CA_KEY")"

rc=0
ap_addnode "$SB/logs/ff_preissued.log" \
  -e '{"add_node_cert_mode":"preissued","add_node_kubelet_cert":"/tmp/opencode/t014-missing/node2.crt"}' || rc=$?
check "preissued 模式缺证书 → exit≠0" test "$rc" -ne 0
check "preissued 模式缺证书 → 信息可判定" grep -qiE 'preissued|证书' "$SB/logs/ff_preissued.log"

rc=0
ap_addnode "$SB/logs/ff_version.log" -e '{"add_node_kubelet_version":"1.30.9"}' || rc=$?
check "kubelet 版本 minor 不兼容 → exit≠0" test "$rc" -ne 0
check "kubelet 版本不兼容 → 信息含版本/minor" \
  grep -qiE '版本|minor|1\.30' "$SB/logs/ff_version.log"

rc=0
ap_addnode "$SB/logs/ff_verify_kubeconfig.log" \
  -e '{"add_node_verify_registration":true,"add_node_verify_kubeconfig":"/tmp/opencode/t014-missing/admin.conf"}' || rc=$?
check "verify 缺 kubeconfig → exit≠0" test "$rc" -ne 0
check "verify 缺 kubeconfig → 信息含 kubeconfig" grep -qi 'kubeconfig' "$SB/logs/ff_verify_kubeconfig.log"
check_not "fail-fast 全程未签发 node2 证书" test -f "$NODE2_CERT"
check_eq "fail-fast 全程 CA 证书哈希不变" "$CA_CERT_HASH0" "$(fhash "$CA_CERT")"

echo "-- B2.5 沙箱预置 node2 运行时（共享机不启 systemd：kubelet validate 需要活的 CRI socket）"
if ap "$PLAY_NODE2_CD" "$SB/logs/node2_cd.log" -l node2; then
  ok "node2 containerd 沙箱装配 exit 0（与 add-node 同一 role/变量）"
else
  bad "node2 containerd 沙箱装配失败（见 $SB/logs/node2_cd.log）"
fi
CD2_UNIT="$SB/node2/etc/systemd/system/containerd.service"
check "node2 containerd unit 已渲染（预置运行时）" test -f "$CD2_UNIT"
if start_unit cd2 "$CD2_UNIT" "$SB/logs/cd2.log"; then
  ok "已拉起 node2 containerd（独立 socket/root）"
else
  bad "无法解析 node2 containerd ExecStart"
fi
wait_sock2() { local i; for ((i = 0; i < 120; i++)); do [[ -S "$SB/node2/run/containerd/containerd.sock" ]] && return 0; sleep 0.25; done; return 1; }
check "node2 containerd CRI socket 已创建（预置）" wait_sock2

echo "-- B3 首跑：真实签发 + 装配新节点（changed>0）"
if ap_addnode "$SB/logs/addnode_run1.log"; then
  ok "add-node 首跑 exit 0"
else
  bad "add-node 首跑失败（见 $SB/logs/addnode_run1.log）"
fi
check "首跑 changed>0" test "$(changed_of "$SB/logs/addnode_run1.log")" -gt 0
check "首跑未出现「已加入」跳过标记（新节点）" \
  bash -c "! grep -q '已加入' '$SB/logs/addnode_run1.log'"
check "node2 kubelet 证书已签发" test -f "$NODE2_CERT"
check "node2 kubelet 私钥已签发" test -f "$NODE2_KEY"
check_eq "node2 证书权限 0644" "644" "$(sudo -n stat -c '%a' "$NODE2_CERT" 2>/dev/null)"
check_eq "node2 私钥权限 0600" "600" "$(sudo -n stat -c '%a' "$NODE2_KEY" 2>/dev/null)"
CERT_SUBJECT="$(sudo -n openssl x509 -in "$NODE2_CERT" -noout -subject -nameopt RFC2253 2>/dev/null)"
check "node2 证书 CN=system:node:node2" \
  bash -c "grep -q 'CN=system:node:node2' <<< '$CERT_SUBJECT'"
check "node2 证书 O=system:nodes" bash -c "grep -q 'O=system:nodes' <<< '$CERT_SUBJECT'"
check "node2 证书链可验证（kubernetes-ca）" \
  sudo -n openssl verify -CAfile "$CA_CERT" "$NODE2_CERT"
check "node2 证书 SAN 含 node2" \
  bash -c "sudo -n openssl x509 -in '$NODE2_CERT' -noout -text | grep -q 'DNS:node2'"
check_eq "首跑后集群 CA 证书哈希不变（未重建 CA）" "$CA_CERT_HASH0" "$(fhash "$CA_CERT")"
check_eq "首跑后集群 CA 私钥哈希不变（未重建 CA）" "$CA_KEY_HASH0" "$(fhash "$CA_KEY")"

CD2_UNIT="$SB/node2/etc/systemd/system/containerd.service"
KL2_UNIT="$SB/node2/etc/systemd/system/kubelet.service"
KL2_CONF="$SB/node2/var/lib/kubelet/config.yaml"
KL2_KUBECONFIG="$SB/node2/var/lib/kubelet/kubelet.conf"
check "node2 containerd unit 已渲染（预置，add-node 未破坏）" test -f "$CD2_UNIT"
check "node2 kubelet unit 已渲染" test -f "$KL2_UNIT"
check "node2 KubeletConfiguration 已渲染" test -f "$KL2_CONF"
check "node2 kubelet.conf 已渲染" test -f "$KL2_KUBECONFIG"
check_eq "node2 kubelet.conf 权限 0600" "600" "$(sudo -n stat -c '%a' "$KL2_KUBECONFIG" 2>/dev/null)"
check_not "node2 无 admin.conf（最小权限）" test -f "$SB/node2/etc/kubernetes/admin.conf"
check_not "node2 无 admin 证书/私钥" \
  bash -c "sudo -n find '$SB/node2' -name 'admin.*' | grep -q ."

check "node2 containerd 仍在运行（add-node 未重启运行时）" \
  test -S "$SB/node2/run/containerd/containerd.sock"
if start_unit kl2 "$KL2_UNIT" "$SB/logs/kl2.log"; then
  ok "已拉起 node2 真实 kubelet"
else
  bad "无法解析 node2 kubelet ExecStart"
fi
check "node2 由真实 kubelet 注册进既有集群" wait_node node2
check "node2 kubelet 二进制版本 = v$VERSION（真实 --version）" \
  bash -c "sudo -n '$SB/node2/usr/local/bin/kubelet' --version 2>/dev/null | grep -q 'v$VERSION'"
NODE2_READY="$(node_ready node2)"
NODE2_REASON="$(node_reason node2)"
printf '  （node2 Ready=%s reason=%s；无 CNI 时 NotReady 可接受）\n' \
  "${NODE2_READY:-?}" "${NODE2_REASON:-none}"
check "node2 Ready 条件存在（True/False）" \
  bash -c "[[ '$NODE2_READY' == 'True' || '$NODE2_READY' == 'False' ]]"
check "node2 NotReady 时给出可诊断 reason（KubeletNotReady 等）" test -n "$NODE2_REASON"
check_eq "node2 的 kubelet.conf 身份 = system:node:node2" "system:node:node2" \
  "$("$KUBECTL" --kubeconfig "$KL2_KUBECONFIG" --cache-dir "$SB/client/kc2" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)"
check_eq "node2 RBAC: get nodes = yes" "yes" \
  "$("$KUBECTL" --kubeconfig "$KL2_KUBECONFIG" --cache-dir "$SB/client/kc2" auth can-i get nodes 2>/dev/null | tr -d '\r' | awk '{print $1}')"
check_eq "node2 RBAC: create serviceaccounts = no（最小权限）" "no" \
  "$("$KUBECTL" --kubeconfig "$KL2_KUBECONFIG" --cache-dir "$SB/client/kc2" auth can-i create serviceaccounts -n default 2>/dev/null | tr -d '\r' | awk '{print $1}')"
check_eq "系统组件：kube-system/coredns SA 存在" "coredns" \
  "$(kctl -n kube-system get sa coredns -o jsonpath='{.metadata.name}' 2>/dev/null)"
check_eq "系统组件：kube-system/coredns Deployment 存在" "coredns" \
  "$(kctl -n kube-system get deploy coredns -o jsonpath='{.metadata.name}' 2>/dev/null)"
check_eq "系统组件：kube-system/coredns ConfigMap 存在" "coredns" \
  "$(kctl -n kube-system get cm coredns -o jsonpath='{.metadata.name}' 2>/dev/null)"
check_eq "系统组件：kube-system/kube-dns Service 存在" "kube-dns" \
  "$(kctl -n kube-system get svc kube-dns -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "系统组件：CoreDNS 清单含 Deployment/Service/SA/ConfigMap（渲染就绪）" \
  bash -c "[[ \$(grep -cE '^kind: (Deployment|Service|ServiceAccount|ConfigMap)$' '$ADDONS_MANIFESTS/coredns.yaml') -eq 4 ]]"
skipped "系统 Pod Running（无镜像；真机用 --mode real）"
skipped "真实跨主机 join（需第二台主机/VM；沙箱为同宿主独立 root）"

echo "-- B4 幂等：同一命令第二次运行 changed=0 且产物不变"
PID[node2_kubelet]="$(proc_pid_path "$SB/node2/usr/local/bin/kubelet")"
PID[node2_containerd]="$(proc_pid_path "$SB/node2/usr/local/bin/containerd")"
check "node2 kubelet PID 可读（空值必须显式失败）" test -n "${PID[node2_kubelet]}"
NODE2_UID="$(node_uid node2)"
check "node2 Node 对象 UID 可读" test -n "$NODE2_UID"
KL2_KUBECONFIG_HASH="$(fhash "$KL2_KUBECONFIG")"
KL2_CONF_HASH="$(fhash "$KL2_CONF")"
NODE2_CERT_HASH="$(fhash "$NODE2_CERT")"
NODE2_KEY_HASH="$(fhash "$NODE2_KEY")"
CD2_CONF_HASH="$(fhash "$SB/node2/etc/containerd/config.toml")"
for v in KL2_KUBECONFIG_HASH KL2_CONF_HASH NODE2_CERT_HASH NODE2_KEY_HASH CD2_CONF_HASH; do
  check "幂等基线非空：$v" bash -c "[[ -n '${!v}' && '${!v}' != '__MISSING__' ]]"
done
if ap_addnode "$SB/logs/addnode_run2.log"; then
  ok "add-node 第二次运行（同一命令）exit 0"
else
  bad "add-node 第二次运行失败（见 $SB/logs/addnode_run2.log）"
fi
check_eq "第二次运行 changed=0" 0 "$(changed_of "$SB/logs/addnode_run2.log")"
check "第二次运行日志含「已加入」显式跳过标记" grep -q '已加入' "$SB/logs/addnode_run2.log"
check_eq "kubelet.conf 内容哈希未变" "$KL2_KUBECONFIG_HASH" "$(fhash "$KL2_KUBECONFIG")"
check_eq "KubeletConfiguration 内容哈希未变" "$KL2_CONF_HASH" "$(fhash "$KL2_CONF")"
check_eq "node2 证书内容哈希未变（未重签）" "$NODE2_CERT_HASH" "$(fhash "$NODE2_CERT")"
check_eq "node2 私钥内容哈希未变（未轮换）" "$NODE2_KEY_HASH" "$(fhash "$NODE2_KEY")"
check_eq "containerd 配置内容哈希未变" "$CD2_CONF_HASH" "$(fhash "$SB/node2/etc/containerd/config.toml")"
check_eq "node2 kubelet 未被重启（PID 不变）" "${PID[node2_kubelet]}" \
  "$(proc_pid_path "$SB/node2/usr/local/bin/kubelet")"
check_eq "node2 Node 对象 UID 不变（未重新注册）" "$NODE2_UID" "$(node_uid node2)"

echo "-- B5 verify tag：控制端读回注册结果"
if ap_addnode "$SB/logs/addnode_verify.log" --tags add-node:verify \
  -e '{"add_node_verify_registration":true}'; then
  ok "--tags add-node:verify exit 0"
else
  bad "--tags add-node:verify 失败（见 $SB/logs/addnode_verify.log）"
fi
check "verify 日志出现 node2 已注册/Ready 读回" \
  bash -c "grep -qE 'node/node2|node2' '$SB/logs/addnode_verify.log' && grep -qiE 'Ready|已注册' '$SB/logs/addnode_verify.log'"
check_eq "verify 后 node2 仍注册" "node/node2" "$(kctl get node node2 -o name 2>/dev/null)"
kctl get node node2 -o json >"$SB/logs/node2_obj.json" 2>/dev/null || true
check "node2 status.conditions 含真实 Ready 项（type/status/reason 载荷，D6）" \
  python3 - "$SB/logs/node2_obj.json" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
conds = [c for c in (d.get("status") or {}).get("conditions") or []
         if c.get("type") == "Ready"]
assert len(conds) == 1, "Ready 条件缺失"
c = conds[0]
assert c.get("status") in ("True", "False"), c.get("status")
assert "reason" in c, "reason 字段缺失"
if c["status"] == "False":
    assert c.get("reason"), "NotReady 必须给出 reason"
PY
rc=0
ap_addnode "$SB/logs/addnode_verify_absent.log" --tags add-node:verify \
  -e '{"add_node_verify_registration":true,"add_node_node_name":"node2-absent","add_node_verify_retries":1,"add_node_verify_delay":0}' || rc=$?
check "verify 对未注册节点 rc≠0（断言有载荷：删/写错断言即变红，D6）" test "$rc" -ne 0
check "verify 失败信息含未读回/Ready（可诊断）" \
  grep -qiE '未.*读回|Ready' "$SB/logs/addnode_verify_absent.log"

echo "-- B6 --check 干跑：rc=0 / changed=0 / 不写产物"
HASHES_BEFORE_CHECK="$(fhash "$KL2_KUBECONFIG")|$(fhash "$KL2_CONF")|$(fhash "$NODE2_CERT")|$(fhash "$SB/node2/etc/containerd/config.toml")"
rc=0
ap_addnode "$SB/logs/addnode_check.log" --check || rc=$?
check "--check 模式 exit 0" test "$rc" -eq 0
check_eq "--check 模式 changed=0" 0 "$(changed_of "$SB/logs/addnode_check.log")"
check_eq "--check 后产物哈希不变" "$HASHES_BEFORE_CHECK" \
  "$(fhash "$KL2_KUBECONFIG")|$(fhash "$KL2_CONF")|$(fhash "$NODE2_CERT")|$(fhash "$SB/node2/etc/containerd/config.toml")"
check "--check 日志无 from_json/解析失败" \
  bash -c "! grep -qiE 'from_json|Expecting value' '$SB/logs/addnode_check.log'"
if ap_addnode "$SB/logs/addnode_run3.log"; then
  ok "check 后真实应用 exit 0"
else
  bad "check 后真实应用失败（见 $SB/logs/addnode_run3.log）"
fi
check_eq "check 后真实应用 changed=0（状态已收敛）" 0 "$(changed_of "$SB/logs/addnode_run3.log")"

echo "-- B6.5 --check 覆盖 cert / verify 读路径（D4；写任务 not ansible_check_mode）"
CHK_PREFIX="$SB/node2check"
sudo -n mkdir -p "$CHK_PREFIX/etc/kubernetes/pki/kubelet"
sudo -n install -m 0644 "$SB/etc/kubernetes/pki/ca.crt" "$CHK_PREFIX/etc/kubernetes/pki/ca.crt"
sudo -n install -m 0600 "$SB/etc/kubernetes/pki/ca.key" "$CHK_PREFIX/etc/kubernetes/pki/ca.key"
rc=0
ap_addnode "$SB/logs/addnode_check_cert.log" --check \
  --tags add-node:validate,add-node:cert \
  -e "{\"add_node_root_prefix\":\"$CHK_PREFIX\"}" || rc=$?
check "--check（未收敛新 prefix，validate+cert 读路径）exit 0" test "$rc" -eq 0
check_eq "--check（cert 读路径）changed=0（签发/写状态被拦住）" 0 \
  "$(changed_of "$SB/logs/addnode_check_cert.log")"
check_not "--check 未写 kubelet 证书（写任务 when: not ansible_check_mode）" \
  test -f "$CHK_PREFIX/etc/kubernetes/pki/kubelet/node2.crt"
check_not "--check 未写幂等状态记录" test -f "$CHK_PREFIX/etc/kubernetes/pki/kubelet/node2.state"
check "--check 日志确实执行了 cert 的 CA 哈希读路径" \
  grep -q '签发前的 CA 证书哈希' "$SB/logs/addnode_check_cert.log"
check "--check 日志无 from_json/解析失败" \
  bash -c "! grep -qiE 'from_json|Expecting value' '$SB/logs/addnode_check_cert.log'"
rc=0
ap_addnode "$SB/logs/addnode_check_verify.log" --check \
  -e '{"add_node_verify_registration":true}' || rc=$?
check "--check（已收敛节点，verify 读路径）exit 0" test "$rc" -eq 0
check_eq "--check（verify 读路径）changed=0" 0 \
  "$(changed_of "$SB/logs/addnode_check_verify.log")"
check "--check 日志含 verify 的 Ready 读回（读路径真实执行）" \
  grep -q '已注册.*Ready\|Ready=' "$SB/logs/addnode_check_verify.log"

echo "-- B7 牙齿：篡改 kubelet.conf 后重跑必须真实收敛（不是恒真跳过）"
printf '\n# t014 teeth: tampered\n' | sudo -n tee -a "$KL2_KUBECONFIG" >/dev/null 2>&1
TAMPERED_HASH="$(fhash "$KL2_KUBECONFIG")"
check "篡改后 kubelet.conf 哈希已变化" test "$TAMPERED_HASH" != "$KL2_KUBECONFIG_HASH"
if ap_addnode "$SB/logs/addnode_teeth.log"; then
  ok "篡改后重跑 exit 0"
else
  bad "篡改后重跑失败（见 $SB/logs/addnode_teeth.log）"
fi
check "篡改后重跑 changed>0（真实重渲染）" test "$(changed_of "$SB/logs/addnode_teeth.log")" -gt 0
check_eq "篡改后重跑把 kubelet.conf 复原为原哈希" "$KL2_KUBECONFIG_HASH" "$(fhash "$KL2_KUBECONFIG")"
if ap_addnode "$SB/logs/addnode_teeth2.log"; then
  ok "复原后再次运行 exit 0"
else
  bad "复原后再次运行失败（见 $SB/logs/addnode_teeth2.log）"
fi
check_eq "复原后再次运行 changed=0（幂等恢复）" 0 "$(changed_of "$SB/logs/addnode_teeth2.log")"

echo "-- B7.5 证书幂等真实化：内容哈希基线 + leaf 篡改自愈 + CA 替换显式失败"
N2_CA="$SB/node2/etc/kubernetes/pki/ca.crt"
N2_STATE="$SB/node2/etc/kubernetes/pki/kubelet/node2.state"
check "首跑写入 CA/证书/私钥内容哈希基线（幂等判定有载荷，不是只看文件存在）" \
  test -s "$N2_STATE"
STATE_LINE="$(sudo -n cat "$N2_STATE" 2>/dev/null)"
check_eq "基线记录的证书哈希 = 当前证书内容哈希" "$(fhash "$NODE2_CERT")" \
  "$(awk '{print $2}' <<<"$STATE_LINE")"
check_eq "基线记录的 CA 哈希 = 当前节点 CA 内容哈希" "$(fhash "$N2_CA")" \
  "$(awk '{print $1}' <<<"$STATE_LINE")"

printf '\n# t018 leaf tamper\n' | sudo -n tee -a "$NODE2_CERT" >/dev/null 2>&1
TAMPERED_CERT_SHA="$(fhash "$NODE2_CERT")"
check "leaf 证书篡改后哈希已变化（前置）" test "$TAMPERED_CERT_SHA" != "$NODE2_CERT_HASH"
if ap_addnode "$SB/logs/addnode_cert_heal.log"; then
  ok "leaf 证书被篡改 → 重跑 exit 0（自愈：用既有 CA 重签）"
else
  bad "leaf 证书被篡改 → 重跑失败（见 $SB/logs/addnode_cert_heal.log）"
fi
check "篡改 leaf 后重跑 changed>0（真实重签，不是文件存在短路，T018/D2）" \
  test "$(changed_of "$SB/logs/addnode_cert_heal.log")" -gt 0
HEALED_CERT_SHA="$(fhash "$NODE2_CERT")"
check "自愈后证书内容哈希 ≠ 篡改值（被真实重签）" \
  test "$HEALED_CERT_SHA" != "$TAMPERED_CERT_SHA"
check "自愈后证书链可用既有集群 CA 验证" \
  sudo -n openssl verify -CAfile "$N2_CA" "$NODE2_CERT"
check "自愈后基线记录更新为新证书哈希" \
  bash -c "grep -q '$HEALED_CERT_SHA' '$N2_STATE'"
if ap_addnode "$SB/logs/addnode_cert_heal2.log"; then
  ok "自愈后复跑 exit 0"
else
  bad "自愈后复跑失败（见 $SB/logs/addnode_cert_heal2.log）"
fi
check_eq "自愈后复跑 changed=0（幂等恢复）" 0 "$(changed_of "$SB/logs/addnode_cert_heal2.log")"

sudo -n cp "$N2_CA" "$SB/client/node2-ca.bak"
printf '\n# t018 ca tamper\n' | sudo -n tee -a "$N2_CA" >/dev/null 2>&1
CA_TAMPERED_SHA="$(fhash "$N2_CA")"
check "节点 CA 被替换后哈希已变化（前置）" \
  test "$CA_TAMPERED_SHA" != "$(awk '{print $1}' <<<"$STATE_LINE")"
rc=0
ap_addnode "$SB/logs/addnode_ca_tamper.log" || rc=$?
check "节点 CA 被替换 → 重跑 rc≠0（显式失败，不静默 changed=0）" test "$rc" -ne 0
check "失败信息指出 CA 与记录不一致（可诊断）" \
  grep -qiE 'CA.*记录|记录.*CA|不一致' "$SB/logs/addnode_ca_tamper.log"
check_eq "显式失败未覆盖/未重建被替换的 CA（不做危险自愈）" \
  "$CA_TAMPERED_SHA" "$(fhash "$N2_CA")"
check_eq "显式失败路径未重签 kubelet 证书" "$HEALED_CERT_SHA" "$(fhash "$NODE2_CERT")"
sudo -n mv "$SB/client/node2-ca.bak" "$N2_CA"
if ap_addnode "$SB/logs/addnode_ca_restored.log"; then
  ok "CA 恢复后重跑 exit 0"
else
  bad "CA 恢复后重跑失败（见 $SB/logs/addnode_ca_restored.log）"
fi
check_eq "CA 恢复后重跑 changed=0（幂等基线恢复）" 0 \
  "$(changed_of "$SB/logs/addnode_ca_restored.log")"

echo "-- C1 既有节点 / 控制面零影响（显式比较，不静默）"
check_eq "node1 kubelet PID 未变（无重启）" "$(ex_pre node1_kubelet_pid)" \
  "$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")"
check_eq "node1 kubelet 启动时间未变" "$(ex_pre node1_kubelet_start)" \
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
check_eq "集群 etc_kubernetes 全树内容哈希未变（控制面无配置变更）" \
  "$(ex_pre cluster_etc_kubernetes)" "$(tree_hash "$SB/etc/kubernetes")"
check_eq "集群 CA 证书哈希未变（全程未重建）" "$(ex_pre cluster_ca_cert)" \
  "$(fhash "$SB/etc/kubernetes/pki/ca.crt")"
check_eq "集群 CA 私钥哈希未变（全程未重建）" "$(ex_pre cluster_ca_key)" \
  "$(fhash "$SB/etc/kubernetes/pki/ca.key")"
check "既有 node1 仍注册" wait_node node1

# 比较器自检：证明上面的「哈希/PID 比较」不是恒真断言
SELFTEST_DIR="$(mktemp -d /tmp/opencode/t014-selftest.XXXXXX)"
printf 'a\n' >"$SELFTEST_DIR/f"
ST1="$(tree_hash "$SELFTEST_DIR")"
printf 'b\n' >>"$SELFTEST_DIR/f"
ST2="$(tree_hash "$SELFTEST_DIR")"
check "比较器自检：内容变化必须导致哈希不同" test -n "$ST1" -a "$ST1" != "$ST2"
sudo -n rm -rf "$SELFTEST_DIR"
( exec -a /tmp/opencode/t014probe sleep 30 ) &
PROBE_PID=$!
sleep 0.2
check "比较器自检：进程探测能取到 PID" test -n "$(proc_pid_path /tmp/opencode/t014probe)"
kill "$PROBE_PID" 2>/dev/null || true
wait "$PROBE_PID" 2>/dev/null || true
check_not "比较器自检：进程退出后 PID 探测为空（空值不会误判相等）" \
  test -n "$(proc_pid_path /tmp/opencode/t014probe)"

echo "-- D1 清理与宿主零污染"
stop_proc "$SB/node2/usr/local/bin/kubelet"
stop_proc "$SB/node1/usr/local/bin/kubelet"
stop_proc "$SB/node2/usr/local/bin/containerd"
stop_proc "$SB/node1/usr/local/bin/containerd"
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
check "高位端口全部释放（16443/12379/20250/20248/20251/20249）" wait_ports_free
check "沙箱 CRI socket 已随进程消失" \
  bash -c "[[ ! -S '$SB/node1/run/containerd/containerd.sock' && ! -S '$SB/node2/run/containerd/containerd.sock' ]]"
check "kubepods 清理仅停本次新建 slice 且无失败" test -z "$SLICE_STOP_ERRORS"

POST_HOST_SNAP=/tmp/opencode/t014_host_post.txt
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
    "$PRE_KUBEPODS_ACTIVE" "$(snap_get "$POST_HOST_SNAP" kubepods_active)"
  check_eq "宿主 kubepods*.slice 加载集合已恢复（active+inactive，D7）" \
    "$PRE_KUBEPODS_LOADED" "$(snap_get "$POST_HOST_SNAP" kubepods_loaded)"
  check "宿主复采快照逐键有载荷（D1/D5：空基线显式 FAIL）" \
    test -z "$(snapshot_problems "$POST_HOST_SNAP" $SNAP_HOST_KEYS)"
else
  bad "宿主快照复采失败或含无效键（重试 3 次）：$(snapshot_problems "$POST_HOST_SNAP" $SNAP_HOST_KEYS)"
fi
check_eq "roles/add-node 文件内容在测试期间未被改动" "$ROLE_TREE_PRE" "$(role_tree_hash "$ROLE")"
check_eq "SKIP 单独计数且不计入 PASS（无镜像限制项）" 2 "$skip_count"

sudo -n rm -rf "$SB"
check "沙箱已清理" test ! -e "$SB"
SB=""

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail SKIP=$skip_count =="
[[ $fail -eq 0 ]]
