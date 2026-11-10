#!/usr/bin/env bash
# =============================================================================
# T010 Cilium CNI role 验收测试（TDD：先红后绿）
#   静态：结构 / 变量化 / 清单模板 / fail-fast 覆盖 / 离线渲染 / 语法 / 风格 / 文档。
#   动态：沙箱内真实渲染 Cilium 清单 → PyYAML 解析 + 逐项变量映射；
#         netns + veth + VXLAN 三组双节点拓扑（正例 / VNI 反证 / 端口反证），
#         用渲染出的 VNI(cluster-id)/tunnel-port/MTU 建立真实内核隧道，
#         验证跨 netns ICMP/HTTP；反证组 underlay 通但 Pod IP 必须不通。
#   受限：cilium-agent/Pod/Node Ready/cilium status 未验证（无镜像，见契约 §5）。
#   宿主零污染：套件自动 `sudo unshare -n -m`（私有 mount ns），netns/veth/VXLAN
#         只在隔离命名空间内；trap 清理；宿主只做本任务资源快照对比。
#   用法: tests/cilium/test_cilium_role.sh
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
changed_of() { grep -oE 'changed=[0-9]+' "$1" 2>/dev/null | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
snapshot_path() {
  local p="$1"
  if [[ -e "$p" ]]; then
    if [[ -f "$p" ]]; then sha_of "$p"; else stat -c '%F %a' "$p"; fi
  else printf '__MISSING__'; fi
}

# --- Ansible / yamllint 探测 ------------------------------------------------
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
have_ansible() { command -v "$ANSIBLE_PLAYBOOK" >/dev/null 2>&1 || [[ -x "$ANSIBLE_PLAYBOOK" ]]; }
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

ROLE=roles/cilium
INV=tests/cilium/inventory.ini
PLAY=tests/cilium/sandbox_cilium.yml
REAL=tests/cilium/real_cilium.yml
Q=tests/cilium/manifest.py
LOGDIR=/tmp/opencode
BODY=MOCK-OK-T010
TASK_NS_RE='^(pos|vni|prt)[12]$'

# --- 自动进入独立 netns（+ 私有 mount ns，避免 /var/run/netns 残留）--------
NETNS_MODE="none"
if [[ "${T010_IN_NETNS:-0}" == "1" ]]; then
  NETNS_MODE="suite"
else
  if sudo -n true 2>/dev/null && sudo -n unshare -n -m true 2>/dev/null; then
    exec sudo -n env T010_IN_NETNS=1 \
      PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}${USER_SITE:-}" \
      ANSIBLE_PLAYBOOK="$ANSIBLE_PLAYBOOK" \
      YAMLLINT="$YAMLLINT" \
      unshare -n -m bash -c 'mount --make-rprivate /; exec "$@"' _ bash "$(readlink -f "$0")"
  fi
fi

echo "== T010 Cilium CNI role 验收 =="

echo "-- B0 密闭性"
if [[ "$NETNS_MODE" == "suite" ]]; then
  if [[ -z "$(ip route show default 2>/dev/null)" ]] &&
    ! timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' >/dev/null 2>&1; then
    ok "B0 套件运行于独立 netns（无默认路由，外网不可达）"
  else
    bad "B0 netns 内存在默认路由或外网仍可达（断网验证失效）"
  fi
else
  bad "B0 未能进入独立 netns（需要免密 sudo + unshare）"
fi
if [[ -d /sys/module/vxlan ]]; then
  ok "B0 vxlan 内核模块已由环境预置（套件不 modprobe）"
elif [[ "${CILIUM_TEST_ALLOW_MODPROBE:-0}" == "1" ]] && sudo -n modprobe vxlan 2>/dev/null; then
  ok "B0 显式允许，已 modprobe vxlan（CILIUM_TEST_ALLOW_MODPROBE=1）"
else
  bad "B0 vxlan 内核模块缺失；套件不改宿主模块（见契约 §5.6）"
fi

echo "-- A1 role / 测试资产结构"
for f in defaults/main.yml tasks/main.yml tasks/validate.yml tasks/facts.yml \
  tasks/render.yml tasks/verify.yml meta/main.yml README.md templates/cilium.yaml.j2; do
  check "存在 $ROLE/$f" test -f "$ROLE/$f"
done
for f in "$INV" "$PLAY" "$REAL" "$Q" tests/cilium/README.md; do
  check "存在 $f" test -f "$f"
done
check_not "role 无被 .gitignore 忽略的文件" \
  bash -c 'find "$1" -type f | git check-ignore --stdin >/dev/null 2>&1' _ "$ROLE"

if [[ ! -d "$ROLE" ]]; then
  bad "role 目录缺失：A2–A9 与全部动态用例无法判定（红阶段）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi

echo "-- A2 变量化 / 无硬编码"
D="$ROLE/defaults/main.yml"
for v in cilium_version cilium_mode cilium_tunnel_port cilium_mtu cilium_cluster_name \
  cilium_cluster_id cilium_pod_cidr cilium_service_cidr cilium_k8s_api_endpoint \
  cilium_kube_proxy_replacement cilium_kube_proxy_enabled cilium_image_registry \
  cilium_image_repository cilium_namespace cilium_root_prefix cilium_tolerations \
  cilium_agent_resources cilium_operator_enabled; do
  check "defaults 定义 $v" grep -qE "^${v}:" "$D"
done
check "默认 mode=vxlan" grep -qE '^cilium_mode: vxlan' "$D"
check "默认保留 kube-proxy" grep -qE '^cilium_kube_proxy_enabled: true' "$D"
check "默认 kubeProxyReplacement=false" grep -qE '^cilium_kube_proxy_replacement: false' "$D"
check_not "tasks 无硬编码版本" grep -rqE '\b1\.[0-9]+\.[0-9]+\b' "$ROLE/tasks"
check_not "templates 无硬编码版本" grep -rqE '\b1\.[0-9]+\.[0-9]+\b' "$ROLE/templates"
check_not "tasks 无硬编码 IPv4 CIDR" grep -rqE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' "$ROLE/tasks"
check_not "templates 无硬编码 IPv4 CIDR" grep -rqE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' "$ROLE/templates"
check_not "tasks 无硬编码 registry（quay.io）" grep -rq 'quay\.io' "$ROLE/tasks"
check_not "templates 无硬编码 registry（quay.io）" grep -rq 'quay\.io' "$ROLE/templates"
check_not "tasks 无硬编码默认端口 8472" grep -rq '8472' "$ROLE/tasks"
check_not "templates 无硬编码默认端口 8472" grep -rq '8472' "$ROLE/templates"
check_not "tasks 无硬编码默认 MTU 1450" grep -rq '1450' "$ROLE/tasks"
check_not "templates 无硬编码默认 MTU 1450" grep -rq '1450' "$ROLE/templates"
check_not "tasks 无外网 URL" grep -rqE 'https?://' "$ROLE/tasks"
check_not "tasks 无硬编码 /etc/kubernetes" grep -rq '/etc/kubernetes' "$ROLE/tasks"
check_not "templates 无硬编码 /etc/kubernetes" grep -rq '/etc/kubernetes' "$ROLE/templates"
check_not "tasks 无硬编码 /etc/systemd/system" grep -rq '/etc/systemd/system' "$ROLE/tasks"
check_not "tasks 无网络获取模块（get_url/uri/helm/package）" \
  grep -rqE 'ansible\.builtin\.(get_url|uri|package)|community\.general\.helm' "$ROLE/tasks"
check_not "role 不依赖 download role" grep -rq 'name: download' "$ROLE/tasks"
check_not "tests 不拉镜像/不起 Pod" \
  grep -rqE --exclude=test_cilium_role.sh 'docker (pull|run)|podman|ctr .*image|kubectl .*apply' tests/cilium
check "tasks 使用 template 渲染" grep -q 'ansible.builtin.template' "$ROLE/tasks/render.yml"
check "tasks 使用 assert" grep -rq 'ansible.builtin.assert' "$ROLE/tasks"
check "tasks 使用 FQCN" grep -rq 'ansible\.builtin\.' "$ROLE/tasks"

echo "-- A3 清单模板（kind / 变量映射）"
T="$ROLE/templates/cilium.yaml.j2"
for kind in ServiceAccount ClusterRole ClusterRoleBinding ConfigMap DaemonSet Deployment; do
  check "A3 模板含 kind: $kind" grep -q "^kind: $kind" "$T"
done
check "A3 ConfigMap cluster-name 变量" grep -q 'cluster-name: "{{ cilium_cluster_name }}"' "$T"
check "A3 ConfigMap cluster-id 变量" grep -q 'cluster-id: "{{ cilium_cluster_id }}"' "$T"
check "A3 ConfigMap kube-proxy-replacement 变量" grep -q 'kube-proxy-replacement: "{{ cilium_kube_proxy_replacement' "$T"
check "A3 ConfigMap routing-mode 变量" grep -q 'routing-mode: "{{ cilium_routing_mode }}"' "$T"
check "A3 ConfigMap tunnel-protocol 变量" grep -q 'tunnel-protocol: "{{ cilium_tunnel_protocol }}"' "$T"
check "A3 ConfigMap tunnel-port 变量" grep -q 'tunnel-port: "{{ cilium_tunnel_port }}"' "$T"
check "A3 ConfigMap mtu 变量" grep -q 'mtu: "{{ cilium_mtu }}"' "$T"
check "A3 ConfigMap Pod CIDR 变量" grep -q 'cluster-pool-ipv4-cidr: "{{ cilium_pod_cidr }}"' "$T"
check "A3 ConfigMap service CIDR 变量" grep -q 'k8s-service-cidr: "{{ cilium_service_cidr }}"' "$T"
check "A3 ConfigMap API endpoint host 变量" grep -q 'k8s-service-host: "{{ cilium_k8s_api_host }}"' "$T"
check "A3 ConfigMap API endpoint port 变量" grep -q 'k8s-service-port: "{{ cilium_k8s_api_port }}"' "$T"
check "A3 镜像 registry/repository/version 变量" \
  grep -q '{{ cilium_image_registry }}/{{ cilium_image_repository }}:{{ cilium_version }}' "$T"
check "A3 tolerations 变量" grep -q 'cilium_tolerations' "$T"
check "A3 resources 变量" grep -q 'cilium_agent_resources' "$T"
check "A3 operator resources 变量" grep -q 'cilium_operator_resources' "$T"
check "A3 namespace/serviceAccount 变量" \
  bash -c "grep -q 'namespace: {{ cilium_namespace }}' '$T' && grep -q 'serviceAccountName: {{ cilium_service_account }}' '$T'"
check "A3 hostNetwork" grep -q 'hostNetwork: true' "$T"
check "A3 agent 从 configmap 目录读配置" grep -q -- '--config-dir=' "$T"
check "A3 operator 条件渲染" grep -q 'cilium_operator_enabled' "$T"

echo "-- A4 fail-fast 覆盖（且先于 render）"
V="$ROLE/tasks/validate.yml"
for token in cilium_mode cilium_pod_cidr cilium_service_cidr cilium_kube_proxy_replacement \
  cilium_kube_proxy_enabled cilium_version cilium_cluster_name cilium_k8s_api_endpoint \
  cilium_tunnel_port cilium_mtu cilium_cluster_id cilium_image_registry cilium_namespace \
  cilium_image_pull_policy; do
  check "A4 validate 覆盖 $token" grep -q "$token" "$V"
done
check "A4 validate 使用 assert" grep -q 'ansible.builtin.assert' "$V"
check "A4 validate 在 render 之前" \
  bash -c "v=\$(grep -n 'validate.yml' '$ROLE/tasks/main.yml' | head -1 | cut -d: -f1); \
           r=\$(grep -n 'render.yml' '$ROLE/tasks/main.yml' | head -1 | cut -d: -f1); \
           [[ -n \"\$v\" && -n \"\$r\" && \"\$v\" -lt \"\$r\" ]]"

echo "-- A5 离线渲染"
check "A5 role tasks 无网络模块" \
  bash -c "! grep -rqE 'get_url|ansible\.builtin\.uri|community\.general\.helm|curl|wget' '$ROLE/tasks'"
check "A5 role README 声明离线渲染" grep -qi '离线' "$ROLE/README.md"
check "A5 role README 声明不拉 chart/镜像" \
  bash -c "grep -qiE 'chart|镜像' '$ROLE/README.md'"

echo "-- A6 语法与风格"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY" >"$LOGDIR/t010_syntax_sandbox.log" 2>&1 &&
    "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$REAL" >"$LOGDIR/t010_syntax_real.log" 2>&1; then
    ok "tests/cilium playbook --syntax-check 通过"
  else
    bad "tests/cilium playbook --syntax-check 失败（见 $LOGDIR/t010_syntax_*.log）"
  fi
else
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi
if [[ -x "$YAMLLINT" ]] || command -v "$YAMLLINT" >/dev/null 2>&1; then
  if PYTHONPATH="${USER_SITE:+$USER_SITE}${PYTHONPATH:+:$PYTHONPATH}" "$YAMLLINT" -c .yamllint \
    "$ROLE" tests/cilium >"$LOGDIR/t010_yamllint.log" 2>&1; then
    ok "yamllint（roles/cilium, tests/cilium）无 error"
  else
    bad "yamllint 失败（见 $LOGDIR/t010_yamllint.log）"
  fi
else
  bad "找不到 yamllint"
fi

echo "-- A7 文档"
check "A7 role README 说明变量" grep -qi '变量' "$ROLE/README.md"
check "A7 role README 说明验证/受限" \
  bash -c "grep -qi '验证' '$ROLE/README.md' && grep -qi '受限' '$ROLE/README.md'"
check "A7 role README 声明 VXLAN 与 kube-proxy" \
  bash -c "grep -qi 'vxlan' '$ROLE/README.md' && grep -qi 'kube-proxy' '$ROLE/README.md'"
check "A7 tests README 说明 netns/VXLAN" \
  bash -c "grep -qi 'netns' tests/cilium/README.md && grep -qi 'vxlan' tests/cilium/README.md"
check "A7 tests README 声明未验证 agent/Pod" \
  bash -c "grep -qiE 'cilium-agent|agent' tests/cilium/README.md && grep -qiE 'Pod' tests/cilium/README.md"

echo "-- A8 范围约束 / 无凭据"
check_not "playbooks/site.yml 未引用 cilium" grep -qEi 'cilium' playbooks/site.yml
if git rev-parse --git-dir >/dev/null 2>&1; then
  frozen="tests/skeleton tests/base tests/download tests/pki tests/etcd tests/ha tests/control-plane tests/node tests/kube-proxy roles/base roles/download roles/pki roles/etcd roles/haproxy roles/keepalived roles/kube-apiserver roles/kube-controller-manager roles/kube-scheduler roles/containerd roles/kubelet roles/kube-proxy"
  dirty="$(git status --porcelain -- $frozen | wc -l)"
  check "已 PASS 的 roles/tests 未被改动" test "$dirty" -eq 0
  check_not "git 跟踪文件无密钥/证书/实际 kubeconfig" \
    bash -c "git ls-files | grep -qE '(^|/)(kubeconfig|admin\\.conf|[^/]+\\.(key|pem|crt))$'"
  check_not "工作区无未忽略的密钥/证书" \
    bash -c "git status --porcelain | grep -qE '\\.(key|crt|pem)$'"
fi

echo "-- A9 --list-tasks / --check 接线"
if have_ansible; then
  LT="$(timeout 120 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" --list-tasks 2>&1)"
  check "A9 --list-tasks 含 validate" grep -q 'cilium:validate' <<<"$LT"
  check "A9 --list-tasks 含 render" grep -q 'cilium:render' <<<"$LT"
  check "A9 --list-tasks 含 verify" grep -q 'cilium:verify' <<<"$LT"
  CHK="$(mktemp -d /tmp/opencode/t010chk.XXXXXX)"
  chmod 0755 "$CHK"
  rc=0
  timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" \
    -e "{\"sandbox_root\":\"$CHK\"}" --check >"$LOGDIR/t010_check.log" 2>&1 || rc=$?
  check "A9 --check 干跑 exit 0" test "$rc" -eq 0
  check "A9 --check 不落盘清单" test ! -e "$CHK/etc/kubernetes/cilium/cilium.yaml"
  rm -rf "$CHK"
else
  bad "找不到 ansible-playbook（跳过 A9）"
fi

# ---------------------------------------------------------------------------
if ! have_ansible; then
  bad "找不到 ansible-playbook（跳过全部动态用例）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi
if ! sudo -n true 2>/dev/null; then
  bad "需要免密 sudo：unshare/netns 与宿主快照"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi

# --- 宿主快照（只收敛到本任务资源；spec v1.5）------------------------------
host_snapshot() {
  {
    nsenter -t 1 -n ip -d link show type vxlan 2>/dev/null | grep -cE '^[0-9]+:' || true
    ls /var/run/netns 2>/dev/null | grep -cE "$TASK_NS_RE" || true
    nsenter -t 1 -n ip route show 2>/dev/null | grep -cE '10\.(88|89|90)\.|192\.168\.5[0-2]\.' || true
    nsenter -t 1 -n iptables-save 2>/dev/null | grep -ci cilium || true
    nsenter -t 1 -n ss -ltn 2>/dev/null | grep -c ':18081' || true
    snapshot_path /etc/kubernetes
    snapshot_path /etc/systemd/system/cilium.service
    ls /etc/systemd/system/cilium* 2>/dev/null | wc -l
  } | tr '\n' ' '
}
PRE_HOST="$(host_snapshot)"

SB=""
HTTP_PID=""
declare -A WRAPPER=()

cleanup_net() {
  local t
  if [[ -n "${HTTP_PID:-}" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
    HTTP_PID=""
  fi
  pkill -f "http.server 18081" 2>/dev/null || true
  for t in pos vni prt; do
    ip netns del "${t}1" 2>/dev/null || true
    ip netns del "${t}2" 2>/dev/null || true
    rm -f "/var/run/netns/${t}1" "/var/run/netns/${t}2" 2>/dev/null || true
  done
}
cleanup() {
  cleanup_net
  [[ "${T010_KEEP_SB:-0}" == "1" ]] && { printf '  （T010_KEEP_SB=1：保留沙箱 %s）\n' "${SB:-}"; return 0; }
  [[ -n "${SB:-}" ]] && rm -rf "$SB"
}
trap cleanup EXIT

SB="$(mktemp -d /tmp/opencode/t010.XXXXXX)"
chmod 0755 "$SB"
MAN="$SB/etc/kubernetes/cilium/cilium.yaml"
ap() { timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" -e "{\"sandbox_root\":\"$SB\"}" "$@"; }

echo "-- B1 沙箱渲染 + YAML 解析 + 变量映射"
if ap >"$LOGDIR/t010_render1.log" 2>&1; then
  ok "B1 Cilium role 首跑 exit 0"
else
  bad "B1 Cilium role 首跑失败（见 $LOGDIR/t010_render1.log）"
fi
check "B1 清单已落盘" test -f "$MAN"
if [[ -f "$MAN" ]]; then
  DOCS="$(python3 "$Q" "$MAN" count 2>/dev/null || echo 0)"
  check "B1 清单可被 PyYAML 解析（$DOCS docs）" test "${DOCS:-0}" -ge 6
  check "B1 必需 kind 齐全（含 operator Deployment）" \
    python3 "$Q" "$MAN" check-required Deployment
  check "B1 cluster-name=test-cluster" \
    test "$(python3 "$Q" "$MAN" get-config cluster-name)" = "test-cluster"
  check "B1 cluster-id=7（VNI 来源）" \
    test "$(python3 "$Q" "$MAN" get-config cluster-id)" = "7"
  check "B1 kube-proxy-replacement=false" \
    test "$(python3 "$Q" "$MAN" get-config kube-proxy-replacement)" = "false"
  check "B1 routing-mode=tunnel" \
    test "$(python3 "$Q" "$MAN" get-config routing-mode)" = "tunnel"
  check "B1 tunnel-protocol=vxlan" \
    test "$(python3 "$Q" "$MAN" get-config tunnel-protocol)" = "vxlan"
  check "B1 tunnel-port=9472（变量生效）" \
    test "$(python3 "$Q" "$MAN" get-config tunnel-port)" = "9472"
  check "B1 mtu=1400（变量生效）" \
    test "$(python3 "$Q" "$MAN" get-config mtu)" = "1400"
  check "B1 Pod CIDR=10.88.0.0/16（变量生效）" \
    test "$(python3 "$Q" "$MAN" get-config cluster-pool-ipv4-cidr)" = "10.88.0.0/16"
  check "B1 service CIDR=10.128.0.0/12（变量生效）" \
    test "$(python3 "$Q" "$MAN" get-config k8s-service-cidr)" = "10.128.0.0/12"
  check "B1 API endpoint host=192.0.2.10" \
    test "$(python3 "$Q" "$MAN" get-config k8s-service-host)" = "192.0.2.10"
  check "B1 API endpoint port=16443" \
    test "$(python3 "$Q" "$MAN" get-config k8s-service-port)" = "16443"
  check "B1 DaemonSet 镜像=registry+repository+version" \
    test "$(python3 "$Q" "$MAN" get DaemonSet cilium \
      spec.template.spec.containers[0].image)" = "registry.example.local/cilium/cilium:1.16.3"
  check "B1 DaemonSet hostNetwork=true" \
    test "$(python3 "$Q" "$MAN" get DaemonSet cilium \
      spec.template.spec.hostNetwork)" = "true"
  check "B1 DaemonSet tolerations=Exists" \
    test "$(python3 "$Q" "$MAN" get DaemonSet cilium \
      spec.template.spec.tolerations[0].operator)" = "Exists"
  check "B1 DaemonSet resources 已渲染（requests.cpu）" \
    test "$(python3 "$Q" "$MAN" get DaemonSet cilium \
      spec.template.spec.containers[0].resources.requests.cpu)" = "100m"
  check "B1 operator 镜像使用同一 registry/版本" \
    test "$(python3 "$Q" "$MAN" get Deployment cilium-operator \
      spec.template.spec.containers[0].image)" = "registry.example.local/cilium/operator-generic:1.16.3"
  check "B1 DaemonSet 从 configmap 目录读配置" \
    bash -c "python3 '$Q' '$MAN' get DaemonSet cilium spec.template.spec.containers[0].args | grep -q 'config-dir'"
  check_not "B1 未泄漏默认 Pod CIDR 10.244.0.0/16" grep -q '10\.244\.0\.0/16' "$MAN"
  check_not "B1 未泄漏默认 registry quay.io" grep -q 'quay\.io' "$MAN"
  check_not "B1 未泄漏默认 tunnel 端口 8472" grep -q '8472' "$MAN"
  check_not "B1 未泄漏默认 MTU 1450" grep -q '1450' "$MAN"
  H0="$(sha_of "$MAN")"
else
  bad "B1 清单缺失：B2/B3/B4 无法判定"
  H0="__MISSING__"
fi

echo "-- B1b 变量映射变体（geneve / native / replacement=true / 自定义 registry）"
SB2="$(mktemp -d /tmp/opencode/t010var.XXXXXX)"
chmod 0755 "$SB2"
MAN2="$SB2/etc/kubernetes/cilium/cilium.yaml"
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" \
  -e "{\"sandbox_root\":\"$SB2\",\"cilium_mode\":\"geneve\",\"cilium_tunnel_port\":6081,\"cilium_mtu\":1300,\"cilium_cluster_name\":\"variant\",\"cilium_kube_proxy_replacement\":true,\"cilium_kube_proxy_enabled\":false,\"cilium_image_registry\":\"mirror.local\"}" \
  >"$LOGDIR/t010_variant_geneve.log" 2>&1 || rc=$?
check "B1b geneve 变体渲染 exit 0" test "$rc" -eq 0
check "B1b geneve → routing-mode=tunnel" \
  test "$(python3 "$Q" "$MAN2" get-config routing-mode 2>/dev/null)" = "tunnel"
check "B1b geneve → tunnel-protocol=geneve" \
  test "$(python3 "$Q" "$MAN2" get-config tunnel-protocol 2>/dev/null)" = "geneve"
check "B1b geneve → tunnel-port=6081" \
  test "$(python3 "$Q" "$MAN2" get-config tunnel-port 2>/dev/null)" = "6081"
check "B1b geneve → mtu=1300" \
  test "$(python3 "$Q" "$MAN2" get-config mtu 2>/dev/null)" = "1300"
check "B1b geneve → cluster-name=variant" \
  test "$(python3 "$Q" "$MAN2" get-config cluster-name 2>/dev/null)" = "variant"
check "B1b geneve → kube-proxy-replacement=true（变量生效）" \
  test "$(python3 "$Q" "$MAN2" get-config kube-proxy-replacement 2>/dev/null)" = "true"
check "B1b geneve → 镜像 registry=mirror.local" \
  test "$(python3 "$Q" "$MAN2" get DaemonSet cilium \
    spec.template.spec.containers[0].image 2>/dev/null)" = "mirror.local/cilium/cilium:1.16.3"
rm -rf "$SB2"

SB3="$(mktemp -d /tmp/opencode/t010nat.XXXXXX)"
chmod 0755 "$SB3"
MAN3="$SB3/etc/kubernetes/cilium/cilium.yaml"
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" \
  -e "{\"sandbox_root\":\"$SB3\",\"cilium_mode\":\"native\"}" \
  >"$LOGDIR/t010_variant_native.log" 2>&1 || rc=$?
check "B1b native 变体渲染 exit 0" test "$rc" -eq 0
check "B1b native → routing-mode=native" \
  test "$(python3 "$Q" "$MAN3" get-config routing-mode 2>/dev/null)" = "native"
check "B1b native → tunnel-protocol 为空" \
  test "$(python3 "$Q" "$MAN3" get-config tunnel-protocol 2>/dev/null)" = ""
rm -rf "$SB3"

echo "-- B2 fail-fast 矩阵（失败不得改动已渲染清单）"
ff_case() {  # ff_case <label> <json-fragment> <grep-regex> <desc>
  local label="$1" frag="$2" pattern="$3" desc="$4" rc=0
  local log="$LOGDIR/t010_ff_${label}.log"
  timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" \
    -e "{\"sandbox_root\":\"$SB\"}" -e "$frag" >"$log" 2>&1 || rc=$?
  check "B2 $desc → exit≠0" test "$rc" -ne 0
  check "B2 $desc → 错误可定位" grep -qiE "$pattern" "$log"
  check "B2 $desc → 已渲染清单未变" test "$(sha_of "$MAN")" = "$H0"
}
ff_case mode_bad '{"cilium_mode":"ipip"}' 'cilium_mode|mode' '非法 mode'
ff_case pod_missing '{"cilium_pod_cidr":""}' 'pod.?cidr|cidr' 'Pod CIDR 缺失'
ff_case pod_invalid '{"cilium_pod_cidr":"10.88.0.0"}' 'cidr' 'Pod CIDR 非法'
ff_case svc_invalid '{"cilium_service_cidr":"10.128.0.0"}' 'cidr' 'Service CIDR 非法'
ff_case conflict '{"cilium_kube_proxy_replacement":true,"cilium_kube_proxy_enabled":true}' \
  'kube.?proxy|replacement' 'replacement=true 且 kube-proxy 仍启用'
ff_case ver_fmt '{"cilium_version":"latest"}' 'cilium_version|版本' '版本格式非法'
ff_case ver_old '{"cilium_version":"1.9.0"}' 'cilium_version|版本|minimum|最低' '版本低于最低支持'
ff_case name_missing '{"cilium_cluster_name":""}' 'cluster_name|集群名' 'cluster name 缺失'
ff_case api_bad '{"cilium_k8s_api_endpoint":"not-a-url"}' 'api_endpoint|endpoint|API' 'API endpoint 非法'
ff_case port_bad '{"cilium_tunnel_port":70000}' 'tunnel_port|端口' 'tunnel 端口越界'
ff_case mtu_bad '{"cilium_mtu":100}' 'mtu' 'MTU 越界'
ff_case id_bad '{"cilium_cluster_id":99999999}' 'cluster_id|cluster-id' 'cluster id 越界'
ff_case reg_missing '{"cilium_image_registry":""}' 'image_registry|registry' '镜像 registry 缺失'
ff_case ns_missing '{"cilium_namespace":""}' 'namespace' 'namespace 缺失'
ff_case pull_bad '{"cilium_image_pull_policy":"Sometimes"}' 'pull_policy' 'pull policy 非法'

# 全新沙箱：fail-fast 不落盘
FFSB="$(mktemp -d /tmp/opencode/t010ff.XXXXXX)"
chmod 0755 "$FFSB"
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" \
  -e "{\"sandbox_root\":\"$FFSB\",\"cilium_mode\":\"bogus\"}" >"$LOGDIR/t010_ff_fresh.log" 2>&1 || rc=$?
check "B2 全新沙箱 fail-fast → exit≠0" test "$rc" -ne 0
check "B2 全新沙箱 fail-fast → 不落盘清单" \
  test ! -e "$FFSB/etc/kubernetes/cilium/cilium.yaml"
rm -rf "$FFSB"

echo "-- B3 幂等（第二次 changed=0 / --check 不写）"
if ap >"$LOGDIR/t010_render2.log" 2>&1; then
  C2="$(changed_of "$LOGDIR/t010_render2.log")"
  check "B3 第二次运行 changed=0" test "${C2:-x}" = "0"
else
  bad "B3 第二次运行失败（见 $LOGDIR/t010_render2.log）"
fi
check "B3 第二次运行未改动清单" test "$(sha_of "$MAN")" = "$H0"
if ap --check >"$LOGDIR/t010_check_same.log" 2>&1; then
  check "B3 同沙箱 --check changed=0" test "$(changed_of "$LOGDIR/t010_check_same.log")" = "0"
else
  bad "B3 同沙箱 --check 失败（见 $LOGDIR/t010_check_same.log）"
fi
check "B3 --check 未改动清单" test "$(sha_of "$MAN")" = "$H0"

echo "-- B4 VXLAN 真实内核数据面（参数取自渲染清单）"
VNI="$(python3 "$Q" "$MAN" get-config cluster-id 2>/dev/null || echo 0)"
PORT="$(python3 "$Q" "$MAN" get-config tunnel-port 2>/dev/null || echo 0)"
MTU="$(python3 "$Q" "$MAN" get-config mtu 2>/dev/null || echo 0)"
POD_CIDR="$(python3 "$Q" "$MAN" get-config cluster-pool-ipv4-cidr 2>/dev/null || echo '')"
read -r POD1 POD2 <<<"$(python3 - "$POD_CIDR" <<'PY' 2>/dev/null || echo "10.88.0.1 10.88.0.2"
import ipaddress
import sys

net = ipaddress.ip_network(sys.argv[1])
hosts = list(net.hosts())
print(hosts[0], hosts[1])
PY
)"
check "B4 渲染参数可用（VNI=$VNI PORT=$PORT MTU=$MTU）" \
  bash -c "[[ '$VNI' =~ ^[0-9]+$ && '$PORT' =~ ^[0-9]+$ && '$MTU' =~ ^[0-9]+$ ]]"

net_pair() {  # tag u1 u2 vni1 port1 vni2 port2 mtu ip1 ip2 cidr
  local tag="$1" u1="$2" u2="$3" vni1="$4" port1="$5" vni2="$6" port2="$7"
  local mtu="$8" ip1="$9" ip2="${10}" cidr="${11}"
  ip netns add "${tag}1" || return 1
  ip netns add "${tag}2" || return 1
  ip link add "${tag}1v" type veth peer name "${tag}2v" || return 1
  ip link set "${tag}1v" netns "${tag}1" || return 1
  ip link set "${tag}2v" netns "${tag}2" || return 1
  ip -n "${tag}1" link set lo up
  ip -n "${tag}2" link set lo up
  ip -n "${tag}1" addr add "$u1/24" dev "${tag}1v"
  ip -n "${tag}1" link set "${tag}1v" up
  ip -n "${tag}2" addr add "$u2/24" dev "${tag}2v"
  ip -n "${tag}2" link set "${tag}2v" up
  ip -n "${tag}1" link add vxlan0 type vxlan id "$vni1" dev "${tag}1v" \
    dstport "$port1" remote "$u2" nolearning || return 1
  ip -n "${tag}2" link add vxlan0 type vxlan id "$vni2" dev "${tag}2v" \
    dstport "$port2" remote "$u1" nolearning || return 1
  ip -n "${tag}1" addr add "$ip1/32" dev vxlan0
  ip -n "${tag}2" addr add "$ip2/32" dev vxlan0
  ip -n "${tag}1" link set vxlan0 mtu "$mtu" up
  ip -n "${tag}2" link set vxlan0 mtu "$mtu" up
  ip -n "${tag}1" route add "$cidr" dev vxlan0
  ip -n "${tag}2" route add "$cidr" dev vxlan0
}

# 正例：两侧 VNI/端口与渲染一致
check "B4 正例拓扑创建成功（VNI=$VNI, port=$PORT, mtu=$MTU）" \
  net_pair pos 192.168.50.1 192.168.50.2 "$VNI" "$PORT" "$VNI" "$PORT" \
  "$MTU" "$POD1" "$POD2" "$POD_CIDR"
# 反证 1：一侧 VNI 不一致
check "B4 VNI 反证拓扑创建成功（一侧 VNI=$((VNI + 1))）" \
  net_pair vni 192.168.51.1 192.168.51.2 "$VNI" "$PORT" "$((VNI + 1))" "$PORT" \
  "$MTU" 10.89.0.1 10.89.0.2 10.89.0.0/16
# 反证 2：一侧 tunnel 端口不一致
check "B4 端口反证拓扑创建成功（一侧 port=$((PORT + 1))）" \
  net_pair prt 192.168.52.1 192.168.52.2 "$VNI" "$PORT" "$VNI" "$((PORT + 1))" \
  "$MTU" 10.90.0.1 10.90.0.2 10.90.0.0/16

check "B4 正例 underlay 可达" ip netns exec pos1 ping -c 1 -W 2 192.168.50.2
check "B4 正例 Pod 路由走 vxlan0" \
  bash -c "ip -n pos1 route get '$POD2' | grep -q 'dev vxlan0'"
check "B4 正例 VXLAN 设备参数 = 渲染值（id=$VNI）" \
  bash -c "ip -n pos1 -d link show vxlan0 | grep -q 'vxlan id $VNI'"
check "B4 正例 VXLAN 设备参数 = 渲染值（dstport=$PORT）" \
  bash -c "ip -n pos1 -d link show vxlan0 | grep -q 'dstport $PORT'"
check "B4 正例 VXLAN MTU = 渲染值（$MTU）" \
  bash -c "ip -n pos1 link show vxlan0 | grep -q 'mtu $MTU'"
check "B4 正例跨 netns ICMP 成功（$POD1 → $POD2）" \
  ip netns exec pos1 ping -c 3 -W 2 "$POD2"
check "B4 正例 MTU 内大包可通（-M do -s $((MTU - 28))）" \
  ip netns exec pos1 ping -c 1 -W 2 -M do -s "$((MTU - 28))" "$POD2"
check "B4 正例超过 MTU 的 DF 包必须失败（-s $((MTU - 28 + 100))）" \
  bash -c "! ip netns exec pos1 ping -c 1 -W 1 -M do -s '$((MTU - 28 + 100))' '$POD2' >/dev/null 2>&1"

mkdir -p "$SB/www"
printf '%s\n' "$BODY" >"$SB/www/health"
( ip netns exec pos2 python3 -m http.server 18081 --bind "$POD2" --directory "$SB/www" \
    >"$LOGDIR/t010_http.log" 2>&1 ) &
HTTP_PID=$!
HTTP_OK=0
for _ in $(seq 1 50); do
  if ip netns exec pos1 curl -sS --noproxy '*' -m 2 "http://$POD2:18081/health" 2>/dev/null | grep -qx "$BODY"; then
    HTTP_OK=1
    break
  fi
  sleep 0.2
done
check "B4 正例跨 netns HTTP 成功且响应体已知" test "$HTTP_OK" = "1"

# 反证组：underlay 必须通（证明拓扑本身没问题），Pod IP 必须不通
check "B4 VNI 反证组 underlay 可达" ip netns exec vni1 ping -c 1 -W 2 192.168.51.2
check "B4 反证：VNI 不一致 → Pod IP 不通" \
  bash -c "! ip netns exec vni1 ping -c 2 -W 1 10.89.0.2 >/dev/null 2>&1"
check "B4 端口反证组 underlay 可达" ip netns exec prt1 ping -c 1 -W 2 192.168.52.2
check "B4 反证：tunnel 端口不一致 → Pod IP 不通" \
  bash -c "! ip netns exec prt1 ping -c 2 -W 1 10.90.0.2 >/dev/null 2>&1"
check "B4 反证后正例仍可通（无串扰）" \
  ip netns exec pos1 ping -c 2 -W 2 "$POD2"

echo "-- B5 清理与宿主零污染"
cleanup_net
check "B5 本任务 netns 已全部删除" \
  bash -c "! ip netns list 2>/dev/null | awk '{print \$1}' | grep -qE '$TASK_NS_RE'"
check "B5 /var/run/netns 无本任务残留文件" \
  bash -c "! ls /var/run/netns 2>/dev/null | grep -qE '$TASK_NS_RE'"
check "B5 无 http.server 18081 残留进程" \
  bash -c "! pgrep -f '[h]ttp.server 18081' >/dev/null 2>&1"
check "B5 沙箱内无 vxlan/veth 接口（已随 netns 销毁）" \
  bash -c "! ip -o link show 2>/dev/null | grep -qE '(vxlan0|(pos|vni|prt)[12]v)'"

POST_HOST="$(host_snapshot)"
if [[ "$PRE_HOST" != "$POST_HOST" ]]; then
  {
    printf 'PRE  : %s\n' "$PRE_HOST"
    printf 'POST : %s\n' "$POST_HOST"
  } >"$LOGDIR/t010_host_diff.log" 2>&1
fi
check "B5 宿主本任务资源快照一致（vxlan/netns/路由/iptables/端口/etc）" \
  test "$PRE_HOST" = "$POST_HOST"

rm -rf "$SB"
check "B5 沙箱已清理" test ! -e "$SB"
SB=""

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
