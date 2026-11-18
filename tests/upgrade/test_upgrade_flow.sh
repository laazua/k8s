#!/usr/bin/env bash
# =============================================================================
# T015 版本升级与回滚验收测试（TDD：先红后绿）
#
#   静态：roles/upgrade 结构/变量化/入口是真实实现/fail-fast 接线/check-mode 接线/
#         syntax-check + yamllint/已 PASS 资产未被修改。
#   动态：同一宿主上搭「升级前基线集群」（真实 etcd + apiserver + CM/scheduler 渲染 +
#         containerd + 真实 kubelet node1），然后用 playbooks/upgrade.yml 真实升级到
#         1.32.13：①升级前自动备份（真实 etcdctl snapshot save + PKI + kubeconfig + 旧二进制
#         + MANIFEST + SHA256SUMS）②版本变更（/version、kubelet --version、Node kubeletVersion）
#         ③按文档回滚（恢复旧二进制 + etcd 快照 + 证书 → /version 回原版本、/healthz ok、
#         节点仍注册、升级期间写入的 ConfigMap 消失）④幂等（重跑 changed=0、不重复备份、不重启）
#         ⑤fail-fast 矩阵（版本格式/跨 minor/降级/无备份/缺 sha256/备份被篡改/二进制 sha 不符/
#         二进制版本不符）⑥--check ⑦宿主零污染。
#   牙齿：把 kube-scheduler 换回旧版后重跑必须 changed>0 并自愈；篡改备份必须被 sha256 拦住；
#         沙箱无 CNI 时 require_ready=true 必须失败（证明 Ready 判定不是恒真）。
#   受限：无镜像 → 系统 Pod 不 Running；单节点（node1）；无 systemd（进程由测试从 unit 拉起）；
#         沙箱 role 内不断言 /version（由测试在重启后真实断言）——见契约 §5/§9。
#
#   用法: tests/upgrade/test_upgrade_flow.sh
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
mkdir -p /tmp/opencode
# 诊断开关：T015_KEEP_SANDBOX=1 时失败后保留沙箱目录（默认 0，行为不变）
KEEP_SANDBOX="${T015_KEEP_SANDBOX:-0}"

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

ROLE=roles/upgrade
PLAY_UPGRADE=playbooks/upgrade.yml
INV=tests/upgrade/inventory.ini
PLAY_STACK=tests/upgrade/sandbox_stack.yml
PLAY_CP=tests/upgrade/sandbox_control_plane.yml
PLAY_NODE1=tests/upgrade/sandbox_node1.yml
PLAY_NODE1_KL=tests/upgrade/sandbox_node1_kubelet.yml
UNIT_EXEC=tests/etcd/unit_exec.py

role_tree_hash() {
  find "$1" -type f -print0 2>/dev/null | sort -z \
    | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
}
ROLE_TREE_PRE="$(role_tree_hash "$ROLE")"

VERSION_OLD=1.31.0
VERSION_NEW=1.32.13
CONTAINERD_VERSION=2.0.0
RUNC_VERSION=1.2.1
CNI_VERSION=1.5.1
CRICTL_VERSION=1.31.1
CACHE="${T015_TEST_CACHE:-/tmp/opencode/k8s-cache}"
ETCD_TARBALL=etcd-v3.5.16-linux-amd64.tar.gz
ETCD_TARBALL_SHA=b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc
CONTAINERD_TARBALL="containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
CNI_TARBALL="cni-plugins-linux-amd64-v${CNI_VERSION}.tgz"
CRICTL_TARBALL="crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz"

COMPONENTS="kube-apiserver kube-controller-manager kube-scheduler kubelet kubectl kube-proxy"

# 官方 sha256（1.31.0 与 1.32.13 均由 dl.k8s.io 的 .sha256 侧车核对）
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
ensure_k8s_bin() {  # ensure_k8s_bin <component> <version> <sha>
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

# --- 以 root 重入：PKI 目录 0700 / 进程以 root 拉起；不改变宿主配置 -----------
if [[ "${EUID}" -ne 0 ]] && sudo -n true 2>/dev/null; then
  exec sudo -n env \
    PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}${USER_SITE:-}" \
    ANSIBLE_PLAYBOOK="$ANSIBLE_PLAYBOOK" \
    YAMLLINT="$YAMLLINT" \
    T015_TEST_CACHE="$CACHE" \
    T015_KEEP_SANDBOX="$KEEP_SANDBOX" \
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
  local h
  h="$(sudo -n find /etc/systemd/system -maxdepth 2 -type f \
    \( -name '*.service' -o -name '*.socket' -o -name '*.timer' \
       -o -name '*.mount' -o -name '*.slice' \) -print0 2>/dev/null \
    | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
  if [[ -z "$h" ]]; then printf '__ERROR__'; else printf '%s' "$h"; fi
}
kubepods_active() {
  systemctl list-units 'kubepods*' --no-legend 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' '
}
kubepods_loaded() {
  systemctl list-units --all 'kubepods*' --no-legend 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' '
}
PORTS_RE=':(16443|12379|20250|20248|20257|20259)[[:space:]]'
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

PRE_HOST_SNAP=/tmp/opencode/t015_host_pre.txt
if ! snapshot_with_retry "$PRE_HOST_SNAP"; then
  bad "宿主快照采集失败（重试 3 次仍失败）"
  echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) SKIP=$skip_count =="
  exit 1
fi
ok "宿主快照已采集（内容级：/etc/kubernetes、unit 集合、containerd、端口、sysctl、kubepods）"
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
  stop_proc "$SB/node1/usr/local/bin/kubelet"
  stop_proc "$SB/node1/usr/local/bin/containerd"
  stop_proc "$SB/usr/local/bin/kube-apiserver"
  stop_proc "$SB/usr/local/bin/etcd"
  stop_new_kubepods_slices
  [[ "$KEEP_SANDBOX" == "1" ]] || sudo -n rm -rf "$SB" 2>/dev/null || true
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
wait_ports_free() {
  local i
  for ((i = 0; i < 60; i++)); do
    [[ -z "$(snapshot_ports)" ]] && return 0
    sleep 0.5
  done
  return 1
}
fhash() {
  local h
  h="$(sudo -n sha256sum "$1" 2>/dev/null | awk '{print $1}')"
  [[ -n "$h" ]] && printf '%s' "$h" || printf '__MISSING__'
}
bin_version() {  # bin_version <path>：真实二进制 --version 输出的 vX.Y.Z
  # kubectl 不支持 --version（只有 `kubectl version --client`），其余组件均支持 --version
  local out
  out="$(sudo -n "$1" --version 2>/dev/null)"
  [[ -n "$out" ]] || out="$(sudo -n "$1" version --client 2>/dev/null)"
  printf '%s\n' "$out" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

echo "== T015 版本升级与回滚验收 =="

echo "-- A1 role / 测试资产结构"
for f in defaults/main.yml tasks/main.yml tasks/validate.yml tasks/backup.yml \
  tasks/binaries.yml tasks/verify.yml tasks/rollback_validate.yml tasks/rollback.yml \
  handlers/main.yml meta/main.yml README.md; do
  check "存在 $ROLE/$f" test -f "$ROLE/$f"
done
for f in "$INV" tests/upgrade/README.md "$PLAY_STACK" "$PLAY_CP" "$PLAY_NODE1" "$PLAY_NODE1_KL"; do
  check "存在 $f" test -f "$f"
done
check "存在入口 $PLAY_UPGRADE" test -f "$PLAY_UPGRADE"
check "存在 Makefile 目标 test-upgrade" grep -qE '^test-upgrade:' Makefile
check "make test 挂载 test_upgrade_flow.sh" \
  bash -c "awk '/^test:/{f=1} f&&/^[a-zA-Z0-9_-]+:/{if(\$0!~/^test:/)exit} f' Makefile | grep -q 'tests/upgrade/test_upgrade_flow.sh'"
for p in "$PLAY_STACK" "$PLAY_CP" "$PLAY_NODE1" "$PLAY_NODE1_KL" "$INV"; do
  check "sandbox 资产不写宿主 /etc/systemd/system：$p" bash -c "! grep -q '/etc/systemd/system' '$p'"
done

echo "-- A2 变量化（静态）"
check "defaults 定义动作（upgrade/rollback）" \
  bash -c "grep -qE '^upgrade_action:' '$ROLE/defaults/main.yml' && grep -q 'rollback' '$ROLE/defaults/main.yml'"
check "defaults 定义目标版本" grep -qE '^upgrade_version:' "$ROLE/defaults/main.yml"
check "defaults 定义跨 minor 开关" grep -qE '^upgrade_allow_minor_jump:' "$ROLE/defaults/main.yml"
check "defaults 定义降级开关" grep -qE '^upgrade_allow_downgrade:' "$ROLE/defaults/main.yml"
check "defaults 定义控制面组件清单" grep -qE '^upgrade_control_plane_components:' "$ROLE/defaults/main.yml"
check "defaults 定义节点组件清单" grep -qE '^upgrade_node_components:' "$ROLE/defaults/main.yml"
check "defaults 定义备份根目录" grep -qE '^upgrade_backup_root:' "$ROLE/defaults/main.yml"
check "defaults 定义备份保留数" grep -qE '^upgrade_backup_retention:' "$ROLE/defaults/main.yml"
check "defaults 定义 etcdctl / endpoints" \
  bash -c "grep -qE '^upgrade_etcdctl:' '$ROLE/defaults/main.yml' && grep -qE '^upgrade_etcd_endpoints:' '$ROLE/defaults/main.yml'"
check "defaults 定义 etcd CA/证书/私钥" \
  bash -c "grep -qE '^upgrade_etcd_ca_file:' '$ROLE/defaults/main.yml' && grep -qE '^upgrade_etcd_cert_file:' '$ROLE/defaults/main.yml' && grep -qE '^upgrade_etcd_key_file:' '$ROLE/defaults/main.yml'"
check "defaults 定义服务管理开关（沙箱可关）" grep -qE '^upgrade_manage_service:' "$ROLE/defaults/main.yml"
check "defaults 定义集群版本校验开关" grep -qE '^upgrade_verify_cluster_version:' "$ROLE/defaults/main.yml"
check "defaults 定义 Ready 严格模式开关" grep -qE '^upgrade_require_ready_nodes:' "$ROLE/defaults/main.yml"
check "defaults 定义回滚目录/离线确认/数据目录" \
  bash -c "grep -qE '^upgrade_rollback_dir:' '$ROLE/defaults/main.yml' && grep -qE '^upgrade_rollback_etcd_offline_ack:' '$ROLE/defaults/main.yml' && grep -qE '^upgrade_rollback_etcd_data_dir:' '$ROLE/defaults/main.yml'"
check "defaults 固定 1.32.13 官方 sha256（离线可复现）" \
  bash -c "grep -q '${SHA_NEW[kube-apiserver]}' '$ROLE/defaults/main.yml' && grep -q '${SHA_NEW[kubelet]}' '$ROLE/defaults/main.yml'"
check "defaults 固定 1.31.0 官方 sha256（回滚来源）" \
  bash -c "grep -q '${SHA_OLD[kube-apiserver]}' '$ROLE/defaults/main.yml'"

echo "-- A3 入口是真实实现（不是占位）"
check_not "入口无 Placeholder" grep -qi 'placeholder' "$PLAY_UPGRADE"
check_not "入口无 pending 占位" grep -qi 'pending' "$PLAY_UPGRADE"
check "入口控制面 play：hosts: k8s_master" \
  bash -c "grep -qE '^[[:space:]]*hosts:[[:space:]]*k8s_master[[:space:]]*$' '$PLAY_UPGRADE'"
check "入口工作节点 play：hosts: k8s_node" \
  bash -c "grep -qE '^[[:space:]]*hosts:[[:space:]]*k8s_node[[:space:]]*$' '$PLAY_UPGRADE'"
check_eq "两个 play 都是 serial: 1" 2 \
  "$(grep -cE '^[[:space:]]*serial:[[:space:]]*1[[:space:]]*$' "$PLAY_UPGRADE")"
check "入口带 upgrade tag" grep -qE 'tags:.*upgrade' "$PLAY_UPGRADE"
check "入口复用 upgrade role" grep -qE '^[[:space:]]*- role: upgrade' "$PLAY_UPGRADE"
check "role 入口按 validate→backup→binaries→verify 顺序编排" \
  bash -c "python3 - '$ROLE/tasks/main.yml' <<'PY'
import sys
t = open(sys.argv[1], encoding='utf-8').read()
order = ['validate.yml', 'backup.yml', 'binaries.yml', 'rollback_validate.yml', 'rollback.yml', 'verify.yml']
pos = []
for k in order:
    i = t.find(k)
    if i < 0:
        sys.exit(1)
    pos.append(i)
sys.exit(0 if pos == sorted(pos) else 1)
PY"

echo "-- A4 语法 / 风格 / 冻结资产"
for p in "$PLAY_UPGRADE" "$PLAY_STACK" "$PLAY_CP" "$PLAY_NODE1" "$PLAY_NODE1_KL"; do
  check "syntax-check $p" "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$p"
done
check "yamllint role + tests/upgrade + 入口" \
  "$YAMLLINT" -c .yamllint "$ROLE" tests/upgrade "$PLAY_UPGRADE"
check "已 PASS 的 role 未被修改（工作区含未跟踪文件）" \
  bash -c "[[ -z \"\$(git status --porcelain --untracked-files=all -- \
    roles/base roles/download roles/pki roles/etcd roles/haproxy roles/keepalived \
    roles/kube-apiserver roles/kube-controller-manager roles/kube-scheduler \
    roles/containerd roles/kubelet roles/kube-proxy roles/cilium roles/cluster-addons \
    roles/taints roles/add-node)\" ]]"
check "roles/upgrade 全量文件内容哈希在测试前可计算" test -n "$ROLE_TREE_PRE"
"$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_UPGRADE" --list-tasks --tags upgrade \
  >/tmp/opencode/t015_list_tasks.log 2>&1
check "入口 --list-tasks --tags upgrade 非空" \
  bash -c "[[ \$(grep -cE '^[[:space:]]+upgrade : ' /tmp/opencode/t015_list_tasks.log) -gt 15 ]]"
check "入口任务顺序：validate → backup → binaries → verify" \
  python3 - /tmp/opencode/t015_list_tasks.log <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
order = ["upgrade:validate", "upgrade:backup", "upgrade:binaries", "upgrade:verify"]
pos = []
for key in order:
    i = text.find(key)
    if i < 0:
        sys.exit(1)
    pos.append(i)
sys.exit(0 if pos == sorted(pos) else 1)
PY
check "契约 §5 真机命令指向 playbooks/upgrade.yml" \
  grep -q 'playbooks/upgrade.yml' docs/harness/state/contracts/T015.md
check "tests/upgrade/README.md 指向 playbooks/upgrade.yml" \
  grep -q 'playbooks/upgrade.yml' tests/upgrade/README.md
check "roles/upgrade/README.md 指向 playbooks/upgrade.yml" \
  grep -q 'playbooks/upgrade.yml' "$ROLE/README.md"
check "README 覆盖回滚命令（upgrade_action=rollback）" \
  bash -c "grep -q 'upgrade_action=rollback' '$ROLE/README.md' && grep -q 'upgrade_action=rollback' tests/upgrade/README.md"

echo "-- A5 check-mode 接线"
check "只读 command 显式 check_mode: false" \
  bash -c "grep -rq 'check_mode: false' '$ROLE/tasks'"
check "写任务在 check 模式被跳过（not ansible_check_mode）" \
  bash -c "[[ \$(grep -rc 'not ansible_check_mode' '$ROLE/tasks' | awk -F: '{s+=\$2} END{print s+0}') -ge 5 ]]"
check "备份任务在 check 模式被跳过" \
  bash -c "grep -q 'not ansible_check_mode' '$ROLE/tasks/backup.yml'"
check "二进制安装任务在 check 模式被跳过" \
  bash -c "grep -q 'not ansible_check_mode' '$ROLE/tasks/binaries.yml'"

echo "-- A6 不硬编码 / 不用 shell / 不直调 systemctl"
check_not "role 不使用 ansible.builtin.shell" grep -rqE 'ansible\.builtin\.shell' "$ROLE/tasks"
check_not "role 不直调 systemctl" grep -rqE 'systemctl' "$ROLE/tasks" "$ROLE/defaults"
check_not "role tasks 不硬编码版本号" grep -rqE '1\.3[0-9]\.[0-9]+' "$ROLE/tasks"
check "回滚使用 etcdctl snapshot restore（真恢复，非拷文件）" \
  grep -q 'snapshot.*restore\|restore.*snapshot' "$ROLE/tasks/rollback.yml"
check "备份使用 etcdctl snapshot save（真实快照）" \
  grep -q 'snapshot.*save\|save.*snapshot' "$ROLE/tasks/backup.yml"

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
ok "官方制品缓存命中（1.31.0 + 1.32.13 全组件 + etcd/containerd/runc/cni/crictl）"

# 磁盘前置：单个沙箱约 3.2G；余量不足时直接中止，否则会以「二进制写入失败」形式误报一片
_free_gb="$(df -BG --output=avail /tmp/opencode | tail -1 | tr -dc '0-9')"
if [[ "${_free_gb:-0}" -lt 6 ]]; then
  bad "磁盘余量不足：/tmp/opencode 可用 ${_free_gb:-?}G（本套件需要 ≥6G，先清理旧沙箱）"
  echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) SKIP=$skip_count =="
  exit 1
fi

SB="$(mktemp -d /tmp/opencode/t015.XXXXXX)"
chmod 0755 "$SB"
mkdir -p "$SB/opt/k8s/artifacts" "$SB/logs" "$SB/client" "$SB/etc" "$SB/var" \
  "$SB/node1/opt/k8s/artifacts"
chmod 0755 "$SB/etc" "$SB/var"
for n in $COMPONENTS; do
  cp "$CACHE/$n-$VERSION_OLD" "$SB/opt/k8s/artifacts/$n"
  cp "$CACHE/$n-$VERSION_OLD" "$SB/node1/opt/k8s/artifacts/$n"
done
for n in "$CONTAINERD_TARBALL" runc.amd64 "$CNI_TARBALL" "$CRICTL_TARBALL" "$ETCD_TARBALL"; do
  cp "$CACHE/$n" "$SB/opt/k8s/artifacts/$n"
  cp -l "$CACHE/$n" "$SB/node1/opt/k8s/artifacts/$n" 2>/dev/null \
    || cp "$CACHE/$n" "$SB/node1/opt/k8s/artifacts/$n"
done
sudo -n chown -R root:root "$SB/opt/k8s/artifacts" "$SB/node1/opt/k8s/artifacts"
sudo -n chmod 0644 "$SB"/opt/k8s/artifacts/* "$SB"/node1/opt/k8s/artifacts/*
ok "沙箱制品已就绪（基线 1.31.0 就位；$SB）"

ap() {  # ap <playbook> <log> [额外的 -e ...]
  local play="$1" log="$2"
  shift 2
  timeout 1200 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" -e "{\"sandbox_root\":\"$SB\"}" "$@" >"$log" 2>&1
}

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

echo "-- B1 升级前基线集群（真实 etcd + apiserver + CM/scheduler 渲染 + node1）"
if ap "$PLAY_STACK" "$SB/logs/stack.log"; then
  ok "stack playbook exit 0（kubectl + pki + etcd + apiserver）"
else
  bad "stack playbook 失败（见 $SB/logs/stack.log）"
fi
check "kubernetes-ca 已签发（集群根）" test -f "$SB/etc/kubernetes/pki/ca.crt"
check "node1 kubelet 证书已预签" test -f "$SB/etc/kubernetes/pki/kubelet/node1.crt"
check "etcdctl 已安装到沙箱" test -x "$SB/usr/local/bin/etcdctl"
check_eq "基线 kubectl 版本 = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kubectl")"

ETCD_UNIT="$(printf '%s/%s' "$SB/etc/systemd/system" etcd-etcd1.service)"
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

UNIT_API="$(printf '%s/%s' "$SB/etc/systemd/system" kube-apiserver.service)"
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
check_eq "基线 /version = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(kctl get --raw /version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gitVersion",""))' 2>/dev/null)"

if ap "$PLAY_CP" "$SB/logs/cp.log"; then
  ok "CM/scheduler 沙箱渲染 exit 0"
else
  bad "CM/scheduler 渲染失败（见 $SB/logs/cp.log）"
fi
check "kube-controller-manager unit 已渲染" test -f "$SB/etc/systemd/system/kube-controller-manager.service"
check "kube-scheduler unit 已渲染" test -f "$SB/etc/systemd/system/kube-scheduler.service"
check_eq "基线 kube-controller-manager 版本 = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kube-controller-manager")"
check_eq "基线 kube-scheduler 版本 = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kube-scheduler")"

if ap "$PLAY_NODE1" "$SB/logs/node1_cd.log" -l node1; then
  ok "node1 containerd 沙箱装配 exit 0"
else
  bad "node1 containerd 装配失败（见 $SB/logs/node1_cd.log）"
fi
CD1_UNIT="$(printf '%s/%s' "$SB/node1/etc/systemd/system" containerd.service)"
KL1_UNIT="$(printf '%s/%s' "$SB/node1/etc/systemd/system" kubelet.service)"
if start_unit cd1 "$CD1_UNIT" "$SB/logs/cd1.log"; then
  ok "已拉起 node1 containerd"
else
  bad "无法解析 node1 containerd ExecStart"
fi
wait_sock1() { local i; for ((i = 0; i < 120; i++)); do [[ -S "$SB/node1/run/containerd/containerd.sock" ]] && return 0; sleep 0.25; done; return 1; }
check "node1 containerd CRI socket 已创建" wait_sock1
if ap "$PLAY_NODE1_KL" "$SB/logs/node1_kl.log" -l node1; then
  ok "node1 kubelet 沙箱装配 exit 0"
else
  bad "node1 kubelet 装配失败（见 $SB/logs/node1_kl.log）"
fi
if start_unit kl1 "$KL1_UNIT" "$SB/logs/kl1.log"; then
  ok "已拉起 node1 真实 kubelet"
else
  bad "无法解析 node1 kubelet ExecStart"
fi
wait_node() {
  local i
  for ((i = 0; i < 240; i++)); do
    kctl get node "$1" -o name 2>/dev/null | grep -qx "node/$1" && return 0
    sleep 0.5
  done
  return 1
}
check "node1 已注册（升级前基线）" wait_node node1
check_eq "基线 node1 kube-proxy 版本 = v$VERSION_OLD（节点组件）" "v$VERSION_OLD" \
  "$(bin_version "$SB/node1/usr/local/bin/kube-proxy")"
node_ready() { kctl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
node_reason() { kctl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null; }
node_kubelet_version() { kctl get node "$1" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null; }
check_eq "基线 node1 kubeletVersion = v$VERSION_OLD" "v$VERSION_OLD" "$(node_kubelet_version node1)"
BASE_READY="$(node_ready node1)"
BASE_REASON="$(node_reason node1)"
printf '  （基线 node1 Ready=%s reason=%s；无 CNI 时 NotReady 可接受）\n' \
  "${BASE_READY:-?}" "${BASE_REASON:-none}"
check "基线 node1 Ready 条件存在" bash -c "[[ '$BASE_READY' == 'True' || '$BASE_READY' == 'False' ]]"
skipped "系统 Pod Running（无镜像；真机用真机步骤 §5）"
skipped "真实多节点滚动（需多台主机/VM；沙箱为单宿主单节点）"

echo "-- B2 升级前快照（用于回滚后内容哈希比对）"
BIN_PRE="$(fhash "$SB/usr/local/bin/kube-apiserver")|$(fhash "$SB/usr/local/bin/kube-controller-manager")|$(fhash "$SB/usr/local/bin/kube-scheduler")|$(fhash "$SB/usr/local/bin/kubectl")"
PKI_PRE="$(tree_hash "$SB/etc/kubernetes/pki")"
KCFG_PRE="$(fhash "$SB/etc/kubernetes/admin.conf")|$(fhash "$SB/etc/kubernetes/controller-manager.conf")|$(fhash "$SB/etc/kubernetes/scheduler.conf")"
NODE_BIN_PRE="$(fhash "$SB/node1/usr/local/bin/kubelet")|$(fhash "$SB/node1/usr/local/bin/kube-proxy")"
NODE_CONF_PRE="$(fhash "$SB/node1/var/lib/kubelet/kubelet.conf")|$(fhash "$SB/node1/var/lib/kubelet/config.yaml")"
for v in BIN_PRE PKI_PRE KCFG_PRE NODE_BIN_PRE NODE_CONF_PRE; do
  check "升级前快照非空：$v" bash -c "[[ -n '${!v}' && '${!v}' != *__MISSING__* ]]"
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
FF_BACKUP_ROOT="$SB/var/backups/ff"
ap_cp() {  # ap_cp <log> [额外参数...]
  local log="$1"
  shift
  timeout 1800 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_UPGRADE" --limit cp1 \
    -e "@$SB/upg-cp.json" "$@" >"$log" 2>&1
}
ap_node() {  # ap_node <log> [额外参数...]
  local log="$1"
  shift
  timeout 1800 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_UPGRADE" --limit node1 \
    -e "@$SB/upg-node.json" "$@" >"$log" 2>&1
}
backup_dir_count() { sudo -n find "$1" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l; }

echo "-- B3 fail-fast 矩阵（全部必须在任何副作用之前/之时拒绝）"
# E1 非法版本格式（3 种），只跑 validate tag：零下载、零备份
for badver in "1.32" "v1.32.13" "1.32.13-rc1"; do
  rc=0
  ap_cp "$SB/logs/ff_fmt.log" --tags upgrade:validate \
    -e "upgrade_version=$badver" -e "upgrade_backup_root=$FF_BACKUP_ROOT" || rc=$?
  check "非法版本格式 '$badver' → exit≠0" test "$rc" -ne 0
  check "非法版本格式 '$badver' → 信息含版本格式" \
    grep -qiE '版本格式|version.*format|格式' "$SB/logs/ff_fmt.log"
done
check_eq "非法版本格式全程未创建备份目录" 0 "$(backup_dir_count "$FF_BACKUP_ROOT")"

# E2 跨多个 minor（1.31 → 1.33）拒绝；显式 allow_minor_jump 时 validate 放行
rc=0
ap_cp "$SB/logs/ff_minor.log" --tags upgrade:validate \
  -e "upgrade_version=1.33.0" -e "upgrade_backup_root=$FF_BACKUP_ROOT" || rc=$?
check "跨两个 minor（1.31→1.33）→ exit≠0" test "$rc" -ne 0
check "跨两个 minor → 信息含 minor" grep -qiE 'minor|相邻' "$SB/logs/ff_minor.log"
check_not "跨两个 minor → 未进入备份/安装阶段" grep -q 'upgrade:backup' "$SB/logs/ff_minor.log"
rc=0
ap_cp "$SB/logs/ff_minor_force.log" --tags upgrade:validate \
  -e "upgrade_version=1.33.0" -e "upgrade_allow_minor_jump=true" \
  -e "upgrade_backup_root=$FF_BACKUP_ROOT" || rc=$?
check "显式 allow_minor_jump=true 时 validate 放行（rc=0）" test "$rc" -eq 0

# E3 降级
rc=0
ap_cp "$SB/logs/ff_downgrade.log" --tags upgrade:validate \
  -e "upgrade_version=1.30.0" -e "upgrade_backup_root=$FF_BACKUP_ROOT" || rc=$?
check "降级（1.31→1.30）→ exit≠0" test "$rc" -ne 0
check "降级 → 信息含降级/downgrade" grep -qiE '降级|downgrade' "$SB/logs/ff_downgrade.log"

# E4 无备份却请求回滚
APISERVER_HASH_BEFORE="$(fhash "$SB/usr/local/bin/kube-apiserver")"
check "fail-fast 前记录已安装 kube-apiserver 哈希（空值必须显式失败）" \
  bash -c "[[ -n '$APISERVER_HASH_BEFORE' && '$APISERVER_HASH_BEFORE' != __MISSING__ ]]"
rc=0
ap_cp "$SB/logs/ff_nobackup.log" -e upgrade_action=rollback \
  -e "upgrade_rollback_dir=$SB/var/backups/does-not-exist" \
  -e upgrade_rollback_etcd_offline_ack=true || rc=$?
check "无备份目录却请求回滚 → exit≠0" test "$rc" -ne 0
check "无备份却回滚 → 信息含备份" grep -qiE '备份|backup' "$SB/logs/ff_nobackup.log"
check_eq "无备份却回滚 → 未创建任何备份目录" 0 "$(backup_dir_count "$FF_BACKUP_ROOT")"

# E5 备份缺 SHA256SUMS
sudo -n mkdir -p "$SB/var/backups/nosha/bin"
printf 'version: %s\nhost: cp1\n' "$VERSION_OLD" | sudo -n tee "$SB/var/backups/nosha/MANIFEST.txt" >/dev/null
rc=0
ap_cp "$SB/logs/ff_nosha.log" -e upgrade_action=rollback \
  -e "upgrade_rollback_dir=$SB/var/backups/nosha" \
  -e upgrade_rollback_etcd_offline_ack=true || rc=$?
check "备份缺 SHA256SUMS → exit≠0" test "$rc" -ne 0
check "备份缺 SHA256SUMS → 信息含 sha256" grep -qiE 'sha256|SHA256SUMS' "$SB/logs/ff_nosha.log"
check_eq "备份缺 SHA256SUMS → 已安装二进制未变" "$APISERVER_HASH_BEFORE" \
  "$(fhash "$SB/usr/local/bin/kube-apiserver")"

# E6 备份被篡改（真实备份尚未产生 → 用伪造 + 真实哈希清单：复制 pki 后改一个文件）
FAKE_BK="$SB/var/backups/tampered"
sudo -n mkdir -p "$FAKE_BK/bin" "$FAKE_BK/pki"
sudo -n cp "$SB/usr/local/bin/kube-apiserver" "$FAKE_BK/bin/kube-apiserver"
sudo -n cp "$SB/etc/kubernetes/pki/ca.crt" "$FAKE_BK/pki/ca.crt"
printf 'version: %s\nhost: cp1\n' "$VERSION_OLD" | sudo -n tee "$FAKE_BK/MANIFEST.txt" >/dev/null
sudo -n bash -c "cd '$FAKE_BK' && sha256sum \$(find . -type f ! -name SHA256SUMS | sort) > SHA256SUMS"
sudo -n bash -c "printf 'tampered\n' >> '$FAKE_BK/bin/kube-apiserver'"
rc=0
ap_cp "$SB/logs/ff_tampered.log" -e upgrade_action=rollback \
  -e "upgrade_rollback_dir=$FAKE_BK" \
  -e upgrade_rollback_etcd_offline_ack=true || rc=$?
check "备份被篡改 → exit≠0" test "$rc" -ne 0
check "备份被篡改 → 信息含 sha256/校验失败" grep -qiE 'sha256|校验|checksum' "$SB/logs/ff_tampered.log"
check_eq "备份被篡改 → 已安装二进制未被覆盖" "$APISERVER_HASH_BEFORE" \
  "$(fhash "$SB/usr/local/bin/kube-apiserver")"

# E7 目标版本二进制 sha256 不符（file:// 假制品源 + 官方 sha）
FAKE_DL="$SB/fake-dl/v$VERSION_NEW/bin/linux/amd64"
mkdir -p "$FAKE_DL"
printf 'not-a-real-kube-apiserver\n' >"$FAKE_DL/kube-apiserver"
rc=0
ap_cp "$SB/logs/ff_sha.log" \
  -e "upgrade_download_url_base=file://$SB/fake-dl" \
  -e "upgrade_artifact_dir=$SB/var/fake-art" \
  -e "upgrade_bin_dir=$SB/var/fake-bin" \
  -e '{"upgrade_components":["kube-apiserver"]}' \
  -e "upgrade_backup_root=$FF_BACKUP_ROOT" \
  -e upgrade_backup_etcd=false -e upgrade_backup_pki=false \
  -e upgrade_download_retries=1 || rc=$?
check "目标二进制 sha256 不符 → exit≠0" test "$rc" -ne 0
check "目标二进制 sha256 不符 → 信息含 sha256/checksum" \
  grep -qiE 'sha256|checksum|校验' "$SB/logs/ff_sha.log"
check_eq "sha256 不符 → 真实 bin 未被改动" "$APISERVER_HASH_BEFORE" \
  "$(fhash "$SB/usr/local/bin/kube-apiserver")"
check_not "sha256 不符 → 未安装到 fake bin" test -f "$SB/var/fake-bin/kube-apiserver"

# E8 目标二进制版本不符（假制品 + 假 sha 匹配 → 下载通过但 --version 断言失败）
FAKE_BIN_SRC="$SB/var/fake-src/kube-apiserver"
mkdir -p "$SB/var/fake-src"
printf 'not-a-real-kube-apiserver\n' >"$FAKE_BIN_SRC"
FAKE_SHA="$(sha_of "$FAKE_BIN_SRC")"
FAKE_DL2="$SB/fake-dl2/v$VERSION_NEW/bin/linux/amd64"
mkdir -p "$FAKE_DL2"
cp "$FAKE_BIN_SRC" "$FAKE_DL2/kube-apiserver"
check_eq "假制品 sha256 与注入的 upgrade_known_sha256 一致（确保走到版本断言）" "$FAKE_SHA" \
  "$(sha_of "$FAKE_DL2/kube-apiserver")"
rc=0
ap_cp "$SB/logs/ff_binver.log" \
  -e "upgrade_known_sha256={\"$VERSION_NEW\":{\"kube-apiserver\":\"$FAKE_SHA\"}}" \
  -e "upgrade_download_url_base=file://$SB/fake-dl2" \
  -e "upgrade_artifact_dir=$SB/var/fake-art2" \
  -e "upgrade_bin_dir=$SB/var/fake-bin2" \
  -e '{"upgrade_components":["kube-apiserver"]}' \
  -e "upgrade_backup_root=$FF_BACKUP_ROOT" \
  -e upgrade_backup_etcd=false -e upgrade_backup_pki=false \
  -e upgrade_download_retries=1 || rc=$?
check "目标二进制版本不符 → exit≠0" test "$rc" -ne 0
check "目标二进制版本不符 → 信息含版本" grep -qiE '版本|version' "$SB/logs/ff_binver.log"
check_eq "版本不符 → 真实 bin 未被改动" "$APISERVER_HASH_BEFORE" \
  "$(fhash "$SB/usr/local/bin/kube-apiserver")"

echo "-- B3.5 制品切换为 1.32.13（升级目标就位；--check 需要真实目标制品）"
for n in $COMPONENTS; do
  cp "$CACHE/$n-$VERSION_NEW" "$SB/opt/k8s/artifacts/$n"
  cp "$CACHE/$n-$VERSION_NEW" "$SB/node1/opt/k8s/artifacts/$n"
done
sudo -n chown -R root:root "$SB/opt/k8s/artifacts" "$SB/node1/opt/k8s/artifacts"
sudo -n chmod 0644 "$SB"/opt/k8s/artifacts/* "$SB"/node1/opt/k8s/artifacts/*
for n in $COMPONENTS; do
  check_eq "制品 $n-$VERSION_NEW sha256 = 官方值" "${SHA_NEW[$n]}" \
    "$(sha_of "$SB/opt/k8s/artifacts/$n")"
done
ok "沙箱制品已切换为 1.32.13（模拟制品就位）"

echo "-- B4 --check 干跑（1.31 → 1.32，不落盘）"
HASHES_BEFORE_CHECK="$BIN_PRE|$PKI_PRE|$KCFG_PRE"
BK_COUNT_BEFORE_CHECK="$(backup_dir_count "$BACKUP_ROOT")"
rc=0
ap_cp "$SB/logs/check.log" --check || rc=$?
check "--check 模式 exit 0" test "$rc" -eq 0
check "--check 模式 changed>0（会升级）" test "$(changed_of "$SB/logs/check.log")" -gt 0
check_eq "--check 未创建备份目录" "$BK_COUNT_BEFORE_CHECK" "$(backup_dir_count "$BACKUP_ROOT")"
check_eq "--check 后二进制/PKI/kubeconfig 哈希不变" "$HASHES_BEFORE_CHECK" \
  "$(fhash "$SB/usr/local/bin/kube-apiserver")|$(fhash "$SB/usr/local/bin/kube-controller-manager")|$(fhash "$SB/usr/local/bin/kube-scheduler")|$(fhash "$SB/usr/local/bin/kubectl")|$(tree_hash "$SB/etc/kubernetes/pki")|$(fhash "$SB/etc/kubernetes/admin.conf")|$(fhash "$SB/etc/kubernetes/controller-manager.conf")|$(fhash "$SB/etc/kubernetes/scheduler.conf")"
check "--check 日志无 from_json/解析失败" \
  bash -c "! grep -qiE 'from_json|Expecting value' '$SB/logs/check.log'"
check_eq "check 后 /version 仍是 v$VERSION_OLD" "v$VERSION_OLD" \
  "$(kctl get --raw /version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gitVersion",""))' 2>/dev/null)"

echo "-- B5 升级前备份失败必须中止（etcd 不可达）"
rc=0
ap_cp "$SB/logs/ff_etcd.log" \
  -e "upgrade_etcd_endpoints=[\"https://127.0.0.1:12399\"]" \
  -e "upgrade_etcd_snapshot_timeout=10" || rc=$?
check "etcd 不可达 → 备份失败 exit≠0" test "$rc" -ne 0
check "etcd 不可达 → 信息含快照/etcd" grep -qiE '快照|snapshot|etcd' "$SB/logs/ff_etcd.log"
check_eq "备份失败 → 已安装 kube-apiserver 仍是 v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kube-apiserver")"
check_eq "备份失败 → 二进制哈希未变" "$APISERVER_HASH_BEFORE" \
  "$(fhash "$SB/usr/local/bin/kube-apiserver")"
check_not "备份失败 → 未产生完整备份目录" \
  bash -c "sudo -n find '$BACKUP_ROOT' -maxdepth 2 -name SHA256SUMS 2>/dev/null | grep -q ."
sudo -n rm -rf "$BACKUP_ROOT"

echo "-- B6 真实升级（1.32.13）：控制面 → 工作节点"
if ap_cp "$SB/logs/upg_cp.log"; then
  ok "控制面升级 play exit 0"
else
  bad "控制面升级失败（见 $SB/logs/upg_cp.log）"
fi
check "控制面升级首跑 changed>0" test "$(changed_of "$SB/logs/upg_cp.log")" -gt 0
if ap_node "$SB/logs/upg_node.log"; then
  ok "工作节点升级 play exit 0"
else
  bad "工作节点升级失败（见 $SB/logs/upg_node.log）"
fi
check "工作节点升级首跑 changed>0" test "$(changed_of "$SB/logs/upg_node.log")" -gt 0

BACKUP_CP="$(sudo -n find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | head -1)"
BACKUP_NODE="$(sudo -n find "$NODE_BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | head -1)"
check "控制面备份目录存在（带时间戳 + 主机名）" \
  bash -c "[[ -n '$BACKUP_CP' && \$(basename '$BACKUP_CP') =~ ^[0-9]{8}T[0-9]{6}Z-cp1$ ]]"
check "节点备份目录存在（带时间戳 + 主机名）" \
  bash -c "[[ -n '$BACKUP_NODE' && \$(basename '$BACKUP_NODE') =~ ^[0-9]{8}T[0-9]{6}Z-node1$ ]]"
for f in etcd-snapshot.db MANIFEST.txt SHA256SUMS; do
  check "备份含 $f" test -f "$BACKUP_CP/$f"
done
check "备份含旧二进制（bin/kube-apiserver）" test -f "$BACKUP_CP/bin/kube-apiserver"
check "备份含证书树（pki/ca.crt）" test -f "$BACKUP_CP/pki/ca.crt"
check "备份含 kubeconfig（kubeconfigs/admin.conf）" test -f "$BACKUP_CP/kubeconfigs/admin.conf"
check_eq "备份目录权限 0700（含私钥）" "700" "$(sudo -n stat -c '%a' "$BACKUP_CP" 2>/dev/null)"
check "etcd 快照非空" bash -c "[[ \$(sudo -n stat -c '%s' '$BACKUP_CP/etcd-snapshot.db') -gt 1000 ]]"
check "etcd 快照可读（etcdctl snapshot status）" \
  sudo -n "$ETCDCTL" snapshot status "$BACKUP_CP/etcd-snapshot.db"
check "备份 SHA256SUMS 自校验通过（sha256sum -c）" \
  sudo -n bash -c "cd '$BACKUP_CP' && sha256sum -c SHA256SUMS --quiet"
check_eq "备份的旧二进制 sha256 = 1.31.0 官方值" "${SHA_OLD[kube-apiserver]}" \
  "$(sha_of "$BACKUP_CP/bin/kube-apiserver")"
check_eq "备份的 CA 与集群 CA 同哈希" "$(fhash "$SB/etc/kubernetes/pki/ca.crt")" \
  "$(fhash "$BACKUP_CP/pki/ca.crt")"
check "MANIFEST 记录原版本与主机" \
  bash -c "grep -q '$VERSION_OLD' '$BACKUP_CP/MANIFEST.txt' && grep -q 'cp1' '$BACKUP_CP/MANIFEST.txt'"
check "节点备份含 kubelet 旧二进制与 kubelet.conf" \
  bash -c "[[ -f '$BACKUP_NODE/bin/kubelet' && -f '$BACKUP_NODE/kubeconfigs/kubelet.conf' ]]"

echo "-- B7 重启进程（沙箱无 systemd：按 unit ExecStart 拉起新二进制）"
APISERVER_PID_OLD="$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")"
check "升级前 apiserver PID 可读（空值必须显式失败）" test -n "$APISERVER_PID_OLD"
stop_proc "$SB/usr/local/bin/kube-apiserver"
check_not "旧 apiserver 进程已退出" proc_alive_path "$SB/usr/local/bin/kube-apiserver"
if start_unit apiserver "$UNIT_API" "$SB/logs/apiserver2.log"; then
  ok "已从 unit 拉起升级后的 kube-apiserver"
else
  bad "无法解析 apiserver unit 的 ExecStart"
fi
check "升级后 /healthz = ok" wait_healthz
check_eq "升级后 /version = v$VERSION_NEW（真实 apiserver gitVersion）" "v$VERSION_NEW" \
  "$(kctl get --raw /version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gitVersion",""))' 2>/dev/null)"
check_eq "已安装 kube-apiserver 二进制版本 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/usr/local/bin/kube-apiserver")"
check_eq "已安装 kube-controller-manager 版本 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/usr/local/bin/kube-controller-manager")"
check_eq "已安装 kube-scheduler 版本 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/usr/local/bin/kube-scheduler")"
check_eq "已安装 kube-proxy（node1）版本 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/node1/usr/local/bin/kube-proxy")"
check_eq "已安装 kubectl 版本 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/usr/local/bin/kubectl")"
check_eq "已安装 kubelet（node1）版本 = v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/node1/usr/local/bin/kubelet")"

stop_proc "$SB/node1/usr/local/bin/kubelet"
check_not "旧 kubelet 进程已退出" proc_alive_path "$SB/node1/usr/local/bin/kubelet"
if start_unit kl1b "$KL1_UNIT" "$SB/logs/kl1b.log"; then
  ok "已从 unit 拉起升级后的 node1 kubelet"
else
  bad "无法解析 node1 kubelet ExecStart"
fi
check "升级后 node1 仍注册" wait_node node1
wait_node_version() {  # wait_node_version <node> <version>
  local i
  for ((i = 0; i < 120; i++)); do
    [[ "$(node_kubelet_version "$1")" == "$2" ]] && return 0
    sleep 1
  done
  return 1
}
check "升级后 node1 kubeletVersion 已刷新为 v$VERSION_NEW" wait_node_version node1 "v$VERSION_NEW"
check_eq "升级后 node1 kubeletVersion = v$VERSION_NEW（全部节点版本已变更）" "v$VERSION_NEW" \
  "$(node_kubelet_version node1)"
UP_READY="$(node_ready node1)"
UP_REASON="$(node_reason node1)"
printf '  （升级后 node1 Ready=%s reason=%s；无 CNI 时 NotReady 可接受）\n' \
  "${UP_READY:-?}" "${UP_REASON:-none}"
check "升级后 node1 Ready 条件存在" bash -c "[[ '$UP_READY' == 'True' || '$UP_READY' == 'False' ]]"
check "升级后 node1 NotReady 时给出可诊断 reason" \
  bash -c "[[ '$UP_READY' == 'True' ]] || [[ -n '$UP_REASON' ]]"
check_eq "升级后节点总数 ≥ 1（全部节点仍注册）" 1 \
  "$(kctl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' | awk '{print ($1>=1)?1:0}')"
check "升级后 PID 已变化（真实重启，非假绿）" \
  bash -c "[[ '$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")' != '$APISERVER_PID_OLD' ]]"

echo "-- B8 Ready 判定有牙齿（require_ready=true 在无 CNI 沙箱必须失败）"
rc=0
ap_cp "$SB/logs/teeth_ready.log" --tags upgrade:verify \
  -e '{"upgrade_verify_cluster_version":false,"upgrade_require_ready_nodes":true}' || rc=$?
check "require_ready=true + NotReady 节点 → exit≠0" test "$rc" -ne 0
check "require_ready=true 失败信息含 Ready" grep -qiE 'Ready' "$SB/logs/teeth_ready.log"

echo "-- B9 备份保留数（retention=2 时裁剪旧目录）"
sudo -n mkdir -p "$BACKUP_ROOT/20000101T000000Z-cp1"
sudo -n mkdir -p "$BACKUP_ROOT/20000102T000000Z-cp1"
rc=0
ap_cp "$SB/logs/retention.log" -e upgrade_backup_retention=2 || rc=$?
check "retention 运行 exit 0" test "$rc" -eq 0
check "retention 后目录数 ≤ 2" test "$(backup_dir_count "$BACKUP_ROOT")" -le 2
check "retention 保留最新备份（含真实备份）" test -d "$BACKUP_CP"

echo "-- C1 幂等：同一命令第二次运行 changed=0 且不重复备份/不重启"
PID[apiserver]="$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")"
PID[kubelet]="$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")"
check "apiserver PID 可读（空值必须显式失败）" test -n "${PID[apiserver]}"
check "kubelet PID 可读（空值必须显式失败）" test -n "${PID[kubelet]}"
APISERVER_START="$(proc_starttime "${PID[apiserver]}")"
KUBELET_START="$(proc_starttime "${PID[kubelet]}")"
BK_CP_COUNT="$(backup_dir_count "$BACKUP_ROOT")"
BK_NODE_COUNT="$(backup_dir_count "$NODE_BACKUP_ROOT")"
BIN_AFTER_UPGRADE="$(fhash "$SB/usr/local/bin/kube-apiserver")|$(fhash "$SB/usr/local/bin/kube-controller-manager")|$(fhash "$SB/usr/local/bin/kube-scheduler")|$(fhash "$SB/usr/local/bin/kubectl")|$(fhash "$SB/node1/usr/local/bin/kubelet")|$(fhash "$SB/node1/usr/local/bin/kube-proxy")"
if ap_cp "$SB/logs/upg_cp2.log"; then
  ok "控制面第二次运行 exit 0"
else
  bad "控制面第二次运行失败（见 $SB/logs/upg_cp2.log）"
fi
check_eq "控制面第二次运行 changed=0" 0 "$(changed_of "$SB/logs/upg_cp2.log")"
if ap_node "$SB/logs/upg_node2.log"; then
  ok "节点第二次运行 exit 0"
else
  bad "节点第二次运行失败（见 $SB/logs/upg_node2.log）"
fi
check_eq "节点第二次运行 changed=0" 0 "$(changed_of "$SB/logs/upg_node2.log")"
check_eq "第二次运行未新增控制面备份目录" "$BK_CP_COUNT" "$(backup_dir_count "$BACKUP_ROOT")"
check_eq "第二次运行未新增节点备份目录" "$BK_NODE_COUNT" "$(backup_dir_count "$NODE_BACKUP_ROOT")"
check_eq "第二次运行未重启 apiserver（PID 不变）" "${PID[apiserver]}" \
  "$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")"
check_eq "第二次运行未重启 kubelet（PID 不变）" "${PID[kubelet]}" \
  "$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")"
check_eq "第二次运行 apiserver 启动时间不变" "$APISERVER_START" \
  "$(proc_starttime "$(proc_pid_path "$SB/usr/local/bin/kube-apiserver")")"
check_eq "第二次运行 kubelet 启动时间不变" "$KUBELET_START" \
  "$(proc_starttime "$(proc_pid_path "$SB/node1/usr/local/bin/kubelet")")"
check_eq "第二次运行后二进制哈希不变" "$BIN_AFTER_UPGRADE" \
  "$(fhash "$SB/usr/local/bin/kube-apiserver")|$(fhash "$SB/usr/local/bin/kube-controller-manager")|$(fhash "$SB/usr/local/bin/kube-scheduler")|$(fhash "$SB/usr/local/bin/kubectl")|$(fhash "$SB/node1/usr/local/bin/kubelet")|$(fhash "$SB/node1/usr/local/bin/kube-proxy")"
check_eq "第二次运行后 /version 仍为 v$VERSION_NEW" "v$VERSION_NEW" \
  "$(kctl get --raw /version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gitVersion",""))' 2>/dev/null)"

echo "-- C2 牙齿：二进制被回退后重跑必须自愈（不是恒真跳过）"
sudo -n cp "$CACHE/kube-scheduler-$VERSION_OLD" "$SB/usr/local/bin/kube-scheduler"
sudo -n chmod 0755 "$SB/usr/local/bin/kube-scheduler"
check_eq "篡改后 kube-scheduler 版本 = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kube-scheduler")"
rc=0
ap_cp "$SB/logs/teeth_bin.log" -e '{"upgrade_components":["kube-scheduler"]}' \
  -e upgrade_backup_etcd=false -e upgrade_backup_pki=false || rc=$?
check "被回退后重跑 exit 0" test "$rc" -eq 0
check "被回退后重跑 changed>0（真实重装）" test "$(changed_of "$SB/logs/teeth_bin.log")" -gt 0
check_eq "重跑后 kube-scheduler 回到 v$VERSION_NEW" "v$VERSION_NEW" \
  "$(bin_version "$SB/usr/local/bin/kube-scheduler")"
rc=0
ap_cp "$SB/logs/teeth_bin2.log" -e '{"upgrade_components":["kube-scheduler"]}' \
  -e upgrade_backup_etcd=false -e upgrade_backup_pki=false || rc=$?
check_eq "自愈后再次运行 changed=0" 0 "$(changed_of "$SB/logs/teeth_bin2.log")"

echo "-- D1 升级期间写入集群数据（用于证明 etcd 真的回退）"
check "创建升级后标记 ConfigMap" \
  kctl create configmap upgrade-marker --from-literal=phase=upgraded
check_eq "标记 ConfigMap 存在" "upgrade-marker" \
  "$(kctl -n default get cm upgrade-marker -o jsonpath='{.metadata.name}' 2>/dev/null)"

echo "-- D2 按文档回滚（控制面 + 节点；真实 etcd 快照恢复）"
# 沙箱无 systemd：测试按文档顺序先停进程（生产由 role/systemd 负责）
stop_proc "$SB/node1/usr/local/bin/kubelet"
stop_proc "$SB/usr/local/bin/kube-apiserver"
stop_proc "$SB/usr/local/bin/etcd"
check_not "回滚前 kubelet 已停止" proc_alive_path "$SB/node1/usr/local/bin/kubelet"
check_not "回滚前 apiserver 已停止" proc_alive_path "$SB/usr/local/bin/kube-apiserver"
check_not "回滚前 etcd 已停止" proc_alive_path "$SB/usr/local/bin/etcd"
rc=0
ap_cp "$SB/logs/rollback_cp.log" -e upgrade_action=rollback \
  -e "upgrade_rollback_dir=$BACKUP_CP" \
  -e upgrade_rollback_etcd_offline_ack=true || rc=$?
check "控制面回滚 exit 0" test "$rc" -eq 0
rc=0
ap_node "$SB/logs/rollback_node.log" -e upgrade_action=rollback \
  -e "upgrade_rollback_dir=$BACKUP_NODE" || rc=$?
check "节点回滚 exit 0" test "$rc" -eq 0
check "回滚日志含 etcd 快照恢复" \
  bash -c "grep -qiE 'snapshot restore|快照恢复|restore' '$SB/logs/rollback_cp.log'"
check "回滚日志含数据目录换入" \
  bash -c "grep -qiE 'pre-rollback|数据目录' '$SB/logs/rollback_cp.log'"
check_eq "回滚后 kube-apiserver 二进制 = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kube-apiserver")"
check_eq "回滚后 kubelet 二进制 = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/node1/usr/local/bin/kubelet")"
check_eq "回滚后 kube-controller-manager = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kube-controller-manager")"
check_eq "回滚后 kube-scheduler = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kube-scheduler")"
check_eq "回滚后 kube-proxy（node1）= v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/node1/usr/local/bin/kube-proxy")"
check_eq "回滚后 kubectl = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(bin_version "$SB/usr/local/bin/kubectl")"

if start_unit etcd2 "$ETCD_UNIT" "$SB/logs/etcd2.log" 65534; then
  ok "已从 unit 拉起回滚后的 etcd"
else
  bad "无法解析 etcd unit 的 ExecStart"
fi
check "回滚后 etcd healthy（恢复的数据目录可用）" wait_etcd
if start_unit apiserver2 "$UNIT_API" "$SB/logs/apiserver3.log"; then
  ok "已从 unit 拉起回滚后的 kube-apiserver"
else
  bad "无法解析 apiserver unit 的 ExecStart"
fi
check "回滚后 /healthz = ok" wait_healthz
check_eq "回滚后 /version = v$VERSION_OLD（真实 gitVersion）" "v$VERSION_OLD" \
  "$(kctl get --raw /version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gitVersion",""))' 2>/dev/null)"
if start_unit kl1c "$KL1_UNIT" "$SB/logs/kl1c.log"; then
  ok "已从 unit 拉起回滚后的 node1 kubelet"
else
  bad "无法解析 node1 kubelet ExecStart"
fi
check "回滚后 node1 仍注册" wait_node node1
check "回滚后 node1 kubeletVersion 已刷新为 v$VERSION_OLD" wait_node_version node1 "v$VERSION_OLD"
check_eq "回滚后 node1 kubeletVersion = v$VERSION_OLD" "v$VERSION_OLD" \
  "$(node_kubelet_version node1)"
RB_READY="$(node_ready node1)"
check "回滚后 node1 Ready 条件存在" bash -c "[[ '$RB_READY' == 'True' || '$RB_READY' == 'False' ]]"
check_not "升级期间写入的 ConfigMap 已随 etcd 回滚消失" \
  kctl -n default get cm upgrade-marker
check_eq "回滚后控制面二进制内容哈希 = 升级前" "$BIN_PRE" \
  "$(fhash "$SB/usr/local/bin/kube-apiserver")|$(fhash "$SB/usr/local/bin/kube-controller-manager")|$(fhash "$SB/usr/local/bin/kube-scheduler")|$(fhash "$SB/usr/local/bin/kubectl")"
check_eq "回滚后 PKI 全树内容哈希 = 升级前" "$PKI_PRE" "$(tree_hash "$SB/etc/kubernetes/pki")"
check_eq "回滚后 kubeconfig 内容哈希 = 升级前" "$KCFG_PRE" \
  "$(fhash "$SB/etc/kubernetes/admin.conf")|$(fhash "$SB/etc/kubernetes/controller-manager.conf")|$(fhash "$SB/etc/kubernetes/scheduler.conf")"
check_eq "回滚后 node1 kubelet/kube-proxy 二进制哈希 = 升级前" "$NODE_BIN_PRE" \
  "$(fhash "$SB/node1/usr/local/bin/kubelet")|$(fhash "$SB/node1/usr/local/bin/kube-proxy")"
check_eq "回滚后 node1 kubelet.conf/config.yaml 哈希 = 升级前" "$NODE_CONF_PRE" \
  "$(fhash "$SB/node1/var/lib/kubelet/kubelet.conf")|$(fhash "$SB/node1/var/lib/kubelet/config.yaml")"

echo "-- D3 回滚后仍可重放（--check）"
rc=0
ap_cp "$SB/logs/check_after_rollback.log" --check || rc=$?
check "回滚后 --check exit 0" test "$rc" -eq 0
check "回滚后 --check changed>0（可再次升级）" \
  test "$(changed_of "$SB/logs/check_after_rollback.log")" -gt 0
check_eq "回滚后 --check 未改动二进制" "$BIN_PRE" \
  "$(fhash "$SB/usr/local/bin/kube-apiserver")|$(fhash "$SB/usr/local/bin/kube-controller-manager")|$(fhash "$SB/usr/local/bin/kube-scheduler")|$(fhash "$SB/usr/local/bin/kubectl")"

echo "-- E1 清理与宿主零污染"
stop_proc "$SB/node1/usr/local/bin/kubelet"
stop_proc "$SB/node1/usr/local/bin/containerd"
stop_proc "$SB/usr/local/bin/kube-apiserver"
stop_proc "$SB/usr/local/bin/etcd"
restore_kernel_tunables
stop_new_kubepods_slices
for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
WRAPPER=()
all_stopped() {
  local p
  for p in "$SB/node1/usr/local/bin/kubelet" "$SB/node1/usr/local/bin/containerd" \
    "$SB/usr/local/bin/kube-apiserver" "$SB/usr/local/bin/etcd"; do
    proc_alive_path "$p" && return 1
  done
  return 0
}
check "沙箱进程已全部退出" all_stopped
check "高位端口全部释放（16443/12379/20250/20248）" wait_ports_free
check "沙箱 CRI socket 已随进程消失" \
  bash -c "[[ ! -S '$SB/node1/run/containerd/containerd.sock' ]]"
check "kubepods 清理仅停本次新建 slice 且无失败" test -z "$SLICE_STOP_ERRORS"

POST_HOST_SNAP=/tmp/opencode/t015_host_post.txt
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
else
  bad "宿主快照复采失败（重试 3 次仍失败，不静默）"
fi
check_eq "roles/upgrade 文件内容在测试期间未被改动" "$ROLE_TREE_PRE" "$(role_tree_hash "$ROLE")"
check_eq "SKIP 单独计数且不计入 PASS（无镜像/单节点限制项）" 2 "$skip_count"

if [[ "$KEEP_SANDBOX" == "1" ]]; then
  printf '  （T015_KEEP_SANDBOX=1，保留沙箱 %s 供诊断）\n' "$SB"
else
  sudo -n rm -rf "$SB"
fi
check "沙箱已清理" bash -c "[[ '$KEEP_SANDBOX' == 1 ]] || [[ ! -e '$SB' ]]"
SB=""

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail SKIP=$skip_count =="
[[ $fail -eq 0 ]]
