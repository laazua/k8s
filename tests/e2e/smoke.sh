#!/usr/bin/env bash
# =============================================================================
#  T012 集群冒烟（一条命令）
#
#  用法:
#    tests/e2e/smoke.sh [--static-only]                 # 只做静态交付检查（秒级）
#    tests/e2e/smoke.sh --mode sandbox                  # 默认：沙箱真实控制面+节点+DNS
#    tests/e2e/smoke.sh --mode real --kubeconfig PATH   # 真机集群验收（镜像依赖项）
#
#  输出协议（机器可读）:
#    PASS / FAIL / SKIP 逐项一行；结尾 RESULT=PASS|FAIL、PASS=n、FAIL=n、SKIP=n。
#    退出码: 0=全部通过（SKIP 不算失败） 1=存在 FAIL 2=用法错误
#
#  受限（无镜像环境，见契约 §5）:
#    系统 Pod Running、kube-dns ClusterIP 解析、跨节点 Pod 互通 无法验证，
#    在 sandbox 模式以 SKIP 显式呈现；真机请用 --mode real（可配合 --image）。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

MODE="sandbox"
KUBECONFIG_PATH=""
STATIC_ONLY=0
IMAGE=""

usage() {
  cat <<'EOF'
T012 集群冒烟

  --static-only            只检查交付物与 playbook 语法（不启动任何进程）
  --mode sandbox           沙箱：真实 pki/etcd/apiserver/containerd/kubelet/CoreDNS
  --mode real              真机：--kubeconfig 指定管理员 kubeconfig
  --kubeconfig PATH        real 模式必填
  --image IMAGE            real 模式可选的业务镜像（用于跨节点 Pod 互通检查）
  -h, --help               显示本帮助
EOF
}

need_val() {  # <选项> [参数...]：缺值或值看起来是选项 → rc=2（不得 shift 失败后死循环）
  if (($# < 2)) || [[ -z "${2:-}" || "${2:-}" == --* ]]; then
    printf '参数 %s 缺少值\n' "$1" >&2
    usage >&2
    exit 2
  fi
}

while (($#)); do
  case "$1" in
    --static-only) STATIC_ONLY=1; shift ;;
    --mode) need_val "$@"; MODE="$2"; shift 2 ;;
    --kubeconfig) need_val "$@"; KUBECONFIG_PATH="$2"; shift 2 ;;
    --image) need_val "$@"; IMAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$MODE" != "sandbox" && "$MODE" != "real" ]]; then
  printf '无效模式: %s（sandbox|real）\n' "$MODE" >&2
  exit 2
fi
# --static-only 不接触集群，无需 kubeconfig（D5）
if [[ "$STATIC_ONLY" -eq 0 && "$MODE" == "real" && -z "$KUBECONFIG_PATH" ]]; then
  printf 'real 模式必须指定 --kubeconfig PATH\n' >&2
  exit 2
fi

pass=0; fail=0; skip=0
ok()    { printf 'PASS  %s\n' "$*"; pass=$((pass+1)); }
bad()   { printf 'FAIL  %s\n' "$*"; fail=$((fail+1)); }
skipped(){ printf 'SKIP  %s\n' "$*"; skip=$((skip+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_eq() { local d="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok "$d"; else bad "$d [期望=$want 实际=${got:-<空>}]"; fi; }

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
changed_of() { grep -oE 'changed=[0-9]+' "$1" 2>/dev/null | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
role_default() {  # <file> <key>：读 role defaults / group_vars 的标量默认值（避免双源，D6）
  sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}
first_host_ip() {  # <cidr> [override]：校验后给出 Service ClusterIP
  python3 - "$1" "$2" <<'PY'
import ipaddress, sys
cidr, override = sys.argv[1], sys.argv[2]
try:
    net = ipaddress.ip_network(cidr, strict=False)
except ValueError:
    sys.exit("bad cidr: %r" % cidr)
try:
    ip = ipaddress.ip_address(override) if override else net.network_address + 1
except ValueError:
    sys.exit("bad ip: %r" % override)
if ip not in net:
    sys.exit("%s 不在 %s 内" % (ip, net))
print(ip)
PY
}

ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook 2>/dev/null || echo "$HOME/ansible/bin/ansible-playbook")}"
if [[ ! -x "$ANSIBLE_PLAYBOOK" && -n "${SUDO_USER:-}" ]]; then
  _h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  [[ -n "$_h" && -x "$_h/ansible/bin/ansible-playbook" ]] && ANSIBLE_PLAYBOOK="$_h/ansible/bin/ansible-playbook"
fi
if [[ "$ANSIBLE_PLAYBOOK" == */ansible/bin/ansible-playbook ]]; then
  export PYTHONPATH="$(dirname "$(dirname "$ANSIBLE_PLAYBOOK")")${PYTHONPATH:+:$PYTHONPATH}"
fi

# --- 静态交付检查 -------------------------------------------------------------
static_checks() {
  local r d p missing=0
  for r in base download pki etcd haproxy keepalived kube-apiserver \
           kube-controller-manager kube-scheduler containerd kubelet kube-proxy \
           cilium cluster-addons; do
    if [[ -d "roles/$r" ]]; then :; else bad "role 缺失: roles/$r"; missing=$((missing+1)); fi
  done
  [[ "$missing" -eq 0 ]] && ok "14 个 role 目录齐全"
  missing=0
  for p in site add-node control-plane node upgrade; do
    if [[ -f "playbooks/$p.yml" ]]; then :; else bad "playbook 缺失: playbooks/$p.yml"; missing=$((missing+1)); fi
  done
  [[ "$missing" -eq 0 ]] && ok "5 个 playbook 齐全"
  missing=0
  for d in skeleton base download pki etcd ha control-plane node kube-proxy cilium cluster-addons e2e; do
    if [[ -d "tests/$d" ]]; then :; else bad "测试目录缺失: tests/$d"; missing=$((missing+1)); fi
  done
  [[ "$missing" -eq 0 ]] && ok "12 个测试套件目录齐全"

  local n=0 synerr=0
  for p in playbooks/*.yml; do
    [[ -f "$p" ]] || continue
    n=$((n+1))
    if ! "$ANSIBLE_PLAYBOOK" -i inventory/hosts.example --syntax-check "$p" >/dev/null 2>&1; then
      bad "语法检查失败: $p"
      synerr=$((synerr+1))
    fi
  done
  [[ "$synerr" -eq 0 ]] && ok "playbook 语法检查通过（$n 个）"
  check "e2e 脚本自身可执行" test -x tests/e2e/smoke.sh
}

# --- sandbox 模式 -------------------------------------------------------------
SANDBOX_MODE=0
SB=""
declare -A WRAPPER=()
PRE_KERNEL_PANIC=""
PRE_KERNEL_PANIC_ON_OOPS=""
PRE_KUBEPODS_SLICES=""

CACHE="${T012_TEST_CACHE:-/tmp/opencode/k8s-cache}"
VERSION=1.31.0
CONTAINERD_VERSION=2.0.0
RUNC_VERSION=1.2.1
CNI_VERSION=1.5.1
CRICTL_VERSION=1.31.1
ETCD_TARBALL=etcd-v3.5.16-linux-amd64.tar.gz
ETCD_SHA=b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc
CD_VERSION=""          # 运行时取 roles/cluster-addons/defaults（D6）
CD_TARBALL=""
CD_SHA=""
declare -A CD_SHA_MAP=([1.11.3]=6af4d6a5412734417378f778343c4fba363a61ae027060675123d4296f5a8ee5)
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
  ["$ETCD_TARBALL"]="$ETCD_SHA"
)

ensure_artifact() {  # <name> <url> <sha>
  local n="$1" u="$2" sh="$3" p="$CACHE/$1"
  [[ -f "$p" && "$(sha_of "$p")" == "$sh" ]] && return 0
  printf '（预取制品 %s）\n' "$n" >&2
  curl -fL --retry 3 --connect-timeout 20 --max-time 1200 -o "$p.tmp" "$u" || { rm -f "$p.tmp"; return 1; }
  mv "$p.tmp" "$p"
  [[ "$(sha_of "$p")" == "$sh" ]]
}

prefill_cache() {
  mkdir -p "$CACHE" || return 1
  local n
  for n in kube-apiserver kubectl kubelet "$CONTAINERD_TARBALL" runc.amd64 \
           "$CNI_TARBALL" "$CRICTL_TARBALL" "$ETCD_TARBALL" "$CD_TARBALL"; do
    ensure_artifact "$n" "${ART_URL[$n]}" "${ART_SHA[$n]}" || return 1
  done
}

proc_pid() { pgrep -f -- "$SB/usr/local/bin/$1" 2>/dev/null | head -1; }
unit_path() { printf '%s/etc/systemd/system/%s.service' "$SB" "$1"; }
stop_proc() {  # 返回非 0 = 进程仍在运行
  local pat="$1" i
  pgrep -f -- "$pat" >/dev/null 2>&1 || return 0
  sudo -n pkill -TERM -f -- "$pat" 2>/dev/null || true
  for ((i=0;i<80;i++)); do pgrep -f -- "$pat" >/dev/null 2>&1 || return 0; sleep 0.1; done
  sudo -n pkill -9 -f -- "$pat" 2>/dev/null || true
  sleep 0.2
  ! pgrep -f -- "$pat" >/dev/null 2>&1
}
restore_kernel_tunables() {  # 返回非 0 = 未能恢复
  local rc=0
  if [[ -n "$PRE_KERNEL_PANIC" && "$PRE_KERNEL_PANIC" != "__MISSING__" ]]; then
    sudo -n sysctl -q -w "kernel.panic=$PRE_KERNEL_PANIC" >/dev/null 2>&1 || true
    [[ "$(cat /proc/sys/kernel/panic 2>/dev/null)" == "$PRE_KERNEL_PANIC" ]] || rc=1
  fi
  if [[ -n "$PRE_KERNEL_PANIC_ON_OOPS" && "$PRE_KERNEL_PANIC_ON_OOPS" != "__MISSING__" ]]; then
    sudo -n sysctl -q -w "kernel.panic_on_oops=$PRE_KERNEL_PANIC_ON_OOPS" >/dev/null 2>&1 || true
    [[ "$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null)" == "$PRE_KERNEL_PANIC_ON_OOPS" ]] || rc=1
  fi
  return "$rc"
}
cleanup_new_kubepods() {  # 只停本次新增的 slice（跑前差集），无新增则不动宿主
  local pre=" ${PRE_KUBEPODS_SLICES:-} " u rc=0
  for u in $(systemctl list-units --all 'kubepods*' --no-legend 2>/dev/null | awk '{print $1}' | sort -u); do
    [[ "$pre" == *" $u "* ]] && continue
    sudo -n systemctl stop "$u" >/dev/null 2>&1 || rc=1
  done
  return "$rc"
}
CLEANED=0
cleanup() {  # 幂等；每步失败记一行 FAIL 并计入 RESULT（T017-4）
  [[ "$CLEANED" -eq 1 ]] && return 0
  CLEANED=1
  local rc=0 p
  restore_kernel_tunables || { bad "清理失败: kernel.panic* 未恢复（期望 ${PRE_KERNEL_PANIC:-?}/${PRE_KERNEL_PANIC_ON_OOPS:-?}）"; rc=1; }
  if [[ -n "${SB:-}" ]]; then
    for p in kubelet containerd kube-apiserver etcd coredns; do
      stop_proc "$SB/usr/local/bin/$p" || { bad "清理失败: 进程残留 $p"; rc=1; }
    done
    cleanup_new_kubepods || { bad "清理失败: 新增 kubepods slice 未停止（见 systemctl list-units 'kubepods*'）"; rc=1; }
    sudo -n rm -rf "$SB" 2>/dev/null || true
    [[ -e "$SB" ]] && { bad "清理失败: 沙箱目录未删除 $SB"; rc=1; }
  fi
  WRAPPER=()
  return "$rc"
}
trap cleanup EXIT

run_sandbox() {
  SANDBOX_MODE=1
  local INV=tests/node/inventory.ini
  local PLAY_STACK=tests/node/sandbox_stack.yml
  local PLAY_API=tests/node/sandbox_apiserver.yml
  local PLAY_CD=tests/node/sandbox_containerd.yml
  local PLAY_KL=tests/node/sandbox_kubelet.yml
  local UNIT_EXEC=tests/etcd/unit_exec.py
  local PORT_API=16443 PORT_ETCD=12379 PORT_KLT=20250 PORT_KLT_HZ=20248
  local PORT_DNS=15353 PORT_METRICS=19153 PORT_READY=19156
  local SVC_KUBE="" CIDR=""

  # D6：CoreDNS 版本与 Service CIDR 以 role defaults 为唯一来源（env 可覆盖并校验）
  CIDR="$(role_default group_vars/all/main.yml k8s_service_cidr)"
  [[ -n "$CIDR" ]] || CIDR="$(role_default roles/kube-apiserver/defaults/main.yml k8s_service_cidr)"
  CD_VERSION="${E2E_COREDNS_VERSION:-$(role_default roles/cluster-addons/defaults/main.yml cluster_addons_coredns_version)}"
  CD_TARBALL="coredns_${CD_VERSION}_linux_amd64.tgz"
  CD_SHA="${CD_SHA_MAP[$CD_VERSION]:-}"
  if [[ -z "$CD_VERSION" || -z "$CD_SHA" ]]; then
    bad "CoreDNS 版本与 sha256 未对齐（版本=${CD_VERSION:-空}，E2E_COREDNS_VERSION 可覆盖；新版本需在 CD_SHA_MAP 登记）"
    return
  fi
  ART_URL["$CD_TARBALL"]="https://github.com/coredns/coredns/releases/download/v${CD_VERSION}/${CD_TARBALL}"
  ART_SHA["$CD_TARBALL"]="$CD_SHA"
  if ! SVC_KUBE="$(first_host_ip "$CIDR" "${E2E_SERVICE_IP:-}")"; then
    bad "无法由 k8s_service_cidr 推导 Service ClusterIP（cidr=${CIDR:-空}，E2E_SERVICE_IP 可覆盖）"
    return
  fi

  check "沙箱环境具备免密 sudo" sudo -n true
  check "端口 16443/12379/20250/20248/15353 空闲" \
    bash -c '! ss -ltn 2>/dev/null | grep -qE ":(16443|12379|20250|20248|15353)[[:space:]]"'
  if ! prefill_cache; then
    bad "官方制品缓存不可用（首次运行需外网）"
    return
  fi
  ok "官方制品缓存就绪（$CACHE）"

  SB="$(mktemp -d /tmp/opencode/t012.XXXXXX)"
  chmod 0755 "$SB"
  mkdir -p "$SB/opt/k8s/artifacts" "$SB/logs" "$SB/client" "$SB/etc" "$SB/var"
  chmod 0755 "$SB/etc" "$SB/var"
  local n
  for n in "${!ART_SHA[@]}"; do cp "$CACHE/$n" "$SB/opt/k8s/artifacts/$n"; done
  sudo -n chown -R root:root "$SB/opt/k8s/artifacts"
  sudo -n chmod 0644 "$SB"/opt/k8s/artifacts/*

  PRE_KERNEL_PANIC="$(cat /proc/sys/kernel/panic 2>/dev/null || echo __MISSING__)"
  PRE_KERNEL_PANIC_ON_OOPS="$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null || echo __MISSING__)"
  PRE_KUBEPODS_SLICES="$(systemctl list-units --all 'kubepods*' --no-legend 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' ')"

  ap() { local play="$1" log="$2"; shift 2
    timeout 900 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" -e "{\"sandbox_root\":\"$SB\"}" "$@" >"$log" 2>&1; }

  # 1) 控制面：pki + etcd unit + kubectl
  if ap "$PLAY_STACK" "$SB/logs/stack.log"; then ok "控制面沙箱渲染（pki + etcd + kubectl）"; else bad "控制面沙箱渲染失败（$SB/logs/stack.log）"; return; fi
  check "kubernetes-ca 已签发" sudo -n test -f "$SB/etc/kubernetes/pki/ca.crt"
  check "node1 kubelet 证书已签发" sudo -n test -f "$SB/etc/kubernetes/pki/kubelet/node1.crt"

  local ETCD_UNIT ETCD_ARGS=()
  ETCD_UNIT="$(unit_path etcd-etcd1)"
  mapfile -t ETCD_ARGS < <(python3 "$UNIT_EXEC" "$ETCD_UNIT" 2>/dev/null)
  if [[ ${#ETCD_ARGS[@]} -gt 0 ]]; then
    ( sudo -n setpriv --reuid 65534 --regid 65534 --clear-groups "${ETCD_ARGS[@]}" </dev/null >>"$SB/logs/etcd.log" 2>&1 ) &
    WRAPPER[etcd]=$!
  else
    bad "无法解析 etcd ExecStart"; return
  fi
  sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/pki/etcd/ca.crt" "$SB/client/etcd-ca.crt"
  sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/pki/apiserver-etcd-client.crt" "$SB/client/etcd-client.crt"
  sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/pki/apiserver-etcd-client.key" "$SB/client/etcd-client.key"
  etcd_ok() { ETCDCTL_API=3 "$SB/usr/local/bin/etcdctl" --endpoints="https://127.0.0.1:$PORT_ETCD" \
    --cacert "$SB/client/etcd-ca.crt" --cert "$SB/client/etcd-client.crt" --key "$SB/client/etcd-client.key" \
    --command-timeout=2s endpoint health >/dev/null 2>&1; }
  local i=0
  while ((i<120)) && ! etcd_ok; do sleep 0.5; i=$((i+1)); done
  check "etcd 单成员健康（真实 TLS）" etcd_ok

  if ap "$PLAY_API" "$SB/logs/apiserver.log"; then ok "kube-apiserver 沙箱渲染"; else bad "kube-apiserver 渲染失败（$SB/logs/apiserver.log）"; return; fi
  local API_ARGS=()
  mapfile -t API_ARGS < <(python3 "$UNIT_EXEC" "$(unit_path kube-apiserver)" 2>/dev/null)
  if [[ ${#API_ARGS[@]} -gt 0 ]]; then
    ( sudo -n "${API_ARGS[@]}" </dev/null >>"$SB/logs/apiserver.log" 2>&1 ) &
    WRAPPER[apiserver]=$!
  else
    bad "无法解析 kube-apiserver ExecStart"; return
  fi
  sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/admin.conf" "$SB/client/admin.conf"
  sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/pki/ca.crt" "$SB/client/ca.crt"
  local KUBECTL="$SB/usr/local/bin/kubectl"
  kctl() { "$KUBECTL" --kubeconfig "$SB/client/admin.conf" --cache-dir "$SB/client/kc" --request-timeout=10s "$@"; }
  i=0
  while ((i<180)) && [[ "$(kctl get --raw /healthz 2>/dev/null)" != "ok" ]]; do sleep 0.5; i=$((i+1)); done
  check_eq "kube-apiserver /healthz = ok" "ok" "$(kctl get --raw /healthz 2>/dev/null)"
  check_eq "admin kubeconfig 认证（can-i '*' '*'）" "yes" "$(kctl auth can-i '*' '*' 2>/dev/null | tr -d '\r' | awk '{print $1}')"

  # 2) 节点运行时：containerd → kubelet
  if ap "$PLAY_CD" "$SB/logs/containerd-render.log"; then ok "containerd 沙箱渲染"; else bad "containerd 渲染失败（$SB/logs/containerd-render.log）"; return; fi
  local CD_ARGS=()
  mapfile -t CD_ARGS < <(python3 "$UNIT_EXEC" "$(unit_path containerd)" 2>/dev/null)
  if [[ ${#CD_ARGS[@]} -gt 0 ]]; then
    ( sudo -n "${CD_ARGS[@]}" </dev/null >>"$SB/logs/containerd.log" 2>&1 ) &
    WRAPPER[containerd]=$!
  else
    bad "无法解析 containerd ExecStart"; return
  fi
  local SOCK="$SB/run/containerd/containerd.sock" i=0
  while ((i<120)) && [[ ! -S "$SOCK" ]]; do sleep 0.25; i=$((i+1)); done
  check "containerd CRI socket 已创建" test -S "$SOCK"
  sudo -n "$SB/usr/local/bin/crictl" --runtime-endpoint "unix://$SOCK" info >"$SB/client/crictl-info.json" 2>/dev/null
  check "containerd RuntimeReady（CRI 端点真实可用）" \
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=[x for x in d["status"]["conditions"] if x.get("type")=="RuntimeReady"]; sys.exit(0 if c and c[0].get("status") is True else 1)' "$SB/client/crictl-info.json"

  if ap "$PLAY_KL" "$SB/logs/kubelet-render.log"; then ok "kubelet 沙箱渲染"; else bad "kubelet 渲染失败（$SB/logs/kubelet-render.log）"; return; fi
  local KL_ARGS=()
  mapfile -t KL_ARGS < <(python3 "$UNIT_EXEC" "$(unit_path kubelet)" 2>/dev/null)
  if [[ ${#KL_ARGS[@]} -gt 0 ]]; then
    ( sudo -n "${KL_ARGS[@]}" </dev/null >>"$SB/logs/kubelet.log" 2>&1 ) &
    WRAPPER[kubelet]=$!
  else
    bad "无法解析 kubelet ExecStart"; return
  fi
  i=0
  while ((i<240)) && [[ "$(kctl get node node1 -o name 2>/dev/null)" != "node/node1" ]]; do sleep 0.5; i=$((i+1)); done
  check_eq "节点 node1 已注册（真实 kubelet）" "node/node1" "$(kctl get node node1 -o name 2>/dev/null)"
  local READY REASON
  READY="$(kctl get node node1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  REASON="$(kctl get node node1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)"
  if [[ "$READY" == "True" || "$READY" == "False" ]]; then
    ok "节点 Ready 条件存在（Ready=$READY reason=${REASON:-none}）"
  else
    bad "节点 Ready 条件缺失（Ready=${READY:-空}）"
  fi
  if [[ "$READY" == "True" || -n "$REASON" ]]; then ok "NotReady 时给出可诊断 reason（CNI 未装可接受）"; else bad "NotReady 且无 reason"; fi

  # 3) 附加组件：kubeconfig / RBAC
  if ap tests/cluster-addons/render.yml "$SB/logs/addons.log" -e '{"cluster_addons_kubelet_node":"node1"}'; then
    ok "cluster-addons 渲染（kubeconfig/RBAC/CoreDNS）"
  else
    bad "cluster-addons 渲染失败（$SB/logs/addons.log）"; return
  fi
  check "kubelet.conf 0600 root:root" \
    bash -c '[[ "$(sudo -n stat -c "%a %U %G" "$1" 2>/dev/null)" == "600 root root" ]]' _ "$SB/etc/kubernetes/kubelet.conf"
  sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/kubelet.conf" "$SB/client/kubelet.conf"
  check_eq "kubelet.conf 身份 = system:node:node1" "system:node:node1" \
    "$("$KUBECTL" --kubeconfig "$SB/client/kubelet.conf" --cache-dir "$SB/client/kck" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)"
  if kctl apply -f "$SB/etc/kubernetes/addons/manifests/rbac.yaml" >/dev/null 2>&1; then
    ok "RBAC 清单可 apply"
  else
    bad "RBAC 清单 apply 失败"
  fi
  check_eq "kubelet RBAC: get nodes = yes" "yes" \
    "$("$KUBECTL" --kubeconfig "$SB/client/kubelet.conf" --cache-dir "$SB/client/kck" auth can-i get nodes 2>/dev/null | tr -d '\r' | awk '{print $1}')"
  check_eq "kubelet RBAC: create serviceaccounts = no" "no" \
    "$("$KUBECTL" --kubeconfig "$SB/client/kubelet.conf" --cache-dir "$SB/client/kck" auth can-i create serviceaccounts -n default 2>/dev/null | tr -d '\r' | awk '{print $1}')"

  # 4) 集群 DNS：CoreDNS 官方二进制按渲染 Corefile 真实解析
  sudo -n tar -xzf "$CACHE/$CD_TARBALL" -C "$SB/usr/local/bin" coredns 2>/dev/null
  sudo -n chmod 0755 "$SB/usr/local/bin/coredns" 2>/dev/null
  local CDIR="$SB/coredns-manifests"
  if ap tests/cluster-addons/render.yml "$SB/logs/addons-dns.log" \
      -e "{\"cluster_addons_kubelet_node\":\"node1\",\"cluster_addons_manifest_dir\":\"$CDIR\",\"cluster_addons_coredns_listen_port\":$PORT_DNS,\"cluster_addons_coredns_metrics_port\":$PORT_METRICS,\"cluster_addons_coredns_ready_port\":$PORT_READY,\"cluster_addons_coredns_kubernetes_endpoint\":\"https://127.0.0.1:$PORT_API\",\"cluster_addons_coredns_tls_cert\":\"$SB/etc/kubernetes/pki/admin.crt\",\"cluster_addons_coredns_tls_key\":\"$SB/etc/kubernetes/pki/admin.key\",\"cluster_addons_coredns_tls_ca\":\"$SB/etc/kubernetes/pki/ca.crt\"}"; then
    ok "Corefile 测试渲染（TLS endpoint + 高位端口）"
  else
    bad "Corefile 测试渲染失败（$SB/logs/addons-dns.log）"; return
  fi
  ( sudo -n "$SB/usr/local/bin/coredns" -conf "$CDIR/Corefile" >"$SB/logs/coredns.log" 2>&1 ) &
  WRAPPER[coredns]=$!
  dns_a() { python3 tests/cluster-addons/dnsq.py 127.0.0.1 "$1" "$2" 2>/dev/null | awk -F= '/^A=/{print $2}'; }
  i=0
  while ((i<60)) && [[ "$(dns_a "$PORT_DNS" "kubernetes.default.svc.cluster.local")" != "$SVC_KUBE" ]]; do sleep 0.5; i=$((i+1)); done
  check_eq "DNS kubernetes.default → $SVC_KUBE" "$SVC_KUBE" "$(dns_a "$PORT_DNS" "kubernetes.default.svc.cluster.local")"

  # 5) 镜像依赖项：显式受限
  skipped "系统 Pod Running（无镜像；真机用 --mode real）"
  skipped "集群内 DNS（kube-dns ClusterIP；无镜像）"
  skipped "跨节点 Pod 互通（无镜像；真机用 --mode real --image）"
}

# --- real 模式 ----------------------------------------------------------------
# T017-2/3：任何查询失败或空集都必须 FAIL，禁止 0/0 恒真与 SKIP 吞故障。
run_real() {
  local KUBECTL="${KUBECTL:-$(command -v kubectl || true)}"
  check "kubeconfig 存在" test -f "$KUBECONFIG_PATH"
  if [[ -z "$KUBECTL" ]]; then bad "未找到 kubectl"; return; fi
  if [[ ! -f "$KUBECONFIG_PATH" ]]; then
    bad "real 模式中止：kubeconfig 不存在（$KUBECONFIG_PATH）"
    return
  fi
  k() { "$KUBECTL" --kubeconfig "$KUBECONFIG_PATH" --request-timeout=15s "$@"; }

  local out rc
  if ! out="$(k get --raw /healthz 2>/dev/null)"; then
    bad "API 不可达（kubectl get --raw /healthz rc≠0），跳过后续查询"
    return
  fi
  check_eq "API /healthz = ok" "ok" "$out"

  local nodes_json total ready
  if ! nodes_json="$(k get nodes -o json 2>/dev/null)"; then
    bad "kubectl get nodes 失败（rc≠0），跳过后续查询"
    return
  fi
  if ! read -r total ready < <(printf '%s' "$nodes_json" | python3 -c '
import json, sys
items = (json.load(sys.stdin).get("items") or [])
ready = sum(1 for i in items if any(
    c.get("type") == "Ready" and c.get("status") == "True"
    for c in ((i.get("status") or {}).get("conditions") or [])))
print(len(items), ready)
'); then
    bad "节点列表解析失败（kubectl get nodes -o json 非法）"
    return
  fi
  if [[ "${total:-0}" -eq 0 ]]; then
    bad "节点列表为空（kubectl 查询成功但 0 节点，禁止空集判定通过）"
    return
  fi
  check_eq "全部节点 Ready（$ready/$total）" "$total" "$ready"
  local want="${E2E_EXPECT_NODES:-1}"
  check "节点数 >= $want（$total）" bash -c '[ "$1" -ge "$2" ]' _ "$total" "$want"

  local pods_json pods bad_pods
  if ! pods_json="$(k -n kube-system get pods -o json 2>/dev/null)"; then
    bad "kubectl get pods 失败（rc≠0）"
  elif ! read -r pods bad_pods < <(printf '%s' "$pods_json" | python3 -c '
import json, sys
items = (json.load(sys.stdin).get("items") or [])
print(len(items), sum(1 for i in items if (i.get("status") or {}).get("phase") != "Running"))
'); then
    bad "Pod 列表解析失败（kubectl get pods -o json 非法）"
  elif [[ "${pods:-0}" -eq 0 ]]; then
    bad "kube-system Pod 列表为空（禁止空集判定通过）"
  else
    check_eq "kube-system 全部 Pod Running（$pods 个）" 0 "$bad_pods"
  fi
  check "kube-dns Service 存在" k -n kube-system get svc kube-dns -o name

  if [[ -n "$IMAGE" ]]; then
    local job="e2e-dns-$RANDOM" errf
    errf="$(mktemp /tmp/opencode/e2e-job.XXXXXX)" || errf=/dev/null
    k -n default delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
    if k -n default create job "$job" --image="$IMAGE" -- sh -c 'nslookup kubernetes.default.svc.cluster.local' >/dev/null 2>"$errf"; then
      if k -n default wait --for=condition=complete "job/$job" --timeout=180s >/dev/null 2>&1; then
        ok "集群内 DNS 解析（Job 成功）"
      else
        bad "集群内 DNS 解析（Job 未完成）"
      fi
      k -n default delete job "$job" --ignore-not-found >/dev/null 2>&1 \
        || bad "集群内 DNS Job 清理失败（job/$job，需人工删除）"
    else
      bad "集群内 DNS（Job 创建失败: $(tr '\n' ' ' <"$errf" | cut -c1-200)）"
    fi
    [[ "$errf" == /dev/null ]] || rm -f "$errf"
    skipped "跨节点 Pod 互通（需按集群拓扑指定两台节点，本脚本不自动投放）"
  else
    skipped "集群内 DNS（未提供 --image）"
    skipped "跨节点 Pod 互通（未提供 --image）"
  fi
}

echo "== T012 集群冒烟（mode=$MODE$([[ $STATIC_ONLY -eq 1 ]] && echo ',static-only')）=="
static_checks
if [[ "$STATIC_ONLY" -eq 0 ]]; then
  if [[ "$MODE" == "sandbox" ]]; then run_sandbox; else run_real; fi
fi

# T017-4：先清理（失败计入 FAIL），再打印 RESULT
cleanup || true
trap - EXIT

printf 'RESULT=%s\n' "$([[ "$fail" -eq 0 ]] && echo PASS || echo FAIL)"
printf 'PASS=%d\nFAIL=%d\nSKIP=%d\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]]
