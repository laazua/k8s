#!/usr/bin/env bash
# =============================================================================
# T009 kube-proxy role 验收测试（TDD：先红后绿）
#   静态：结构 / 变量化 / config+unit 模板 / 服务接线 / 安全默认 / 语法 / 风格。
#   动态：沙箱内**真实** pki → **真实单成员 TLS etcd** → **真实 kube-apiserver**
#         → **真实 kube-proxy**（高位端口、沙箱 config/unit/kubeconfig，进程从 role
#         渲染出的 unit 的 ExecStart 拉起）；创建 Node/Service/EndpointSlice，
#         后端是 netns 内的本地 mock HTTP（非 Pod），验证 ClusterIP **真实可访问**
#         （A9 核心）、后端故障/EndpointSlice 移除的边界、幂等、fail-fast、密闭性、
#         宿主零污染。
#   受限：不写宿主 /etc/systemd/system、不 systemctl、不占默认 6443/10256/10249；
#         systemd active/enabled 与多节点 DaemonSet 调度见契约 §5（真机复验）。
#   用法: tests/kube-proxy/test_kube_proxy_role.sh
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
# 按 /proc/<pid>/exe 精确判断某二进制是否仍有存活进程（避免 pgrep -f 自匹配）。
proc_alive() {
  local exe p
  exe="$(readlink -f "$1" 2>/dev/null)" || return 1
  [[ -n "$exe" ]] || return 1
  for p in /proc/[0-9]*; do
    [[ "$(readlink "$p/exe" 2>/dev/null)" == "$exe" ]] && return 0
  done
  return 1
}
snapshot_path() {
  local p="$1"
  if [[ -e "$p" ]]; then
    if [[ -f "$p" ]]; then sha_of "$p"; else stat -c '%F %a' "$p"; fi
  else printf '__MISSING__'; fi
}

# --- Ansible 探测 -----------------------------------------------------------
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook 2>/dev/null || echo "$HOME/ansible/bin/ansible-playbook")}"
if [[ ! -x "$ANSIBLE_PLAYBOOK" && -n "${SUDO_USER:-}" ]]; then
  _sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  if [[ -n "$_sudo_home" && -x "$_sudo_home/ansible/bin/ansible-playbook" ]]; then
    ANSIBLE_PLAYBOOK="$_sudo_home/ansible/bin/ansible-playbook"
  fi
fi
if [[ "$ANSIBLE_PLAYBOOK" == */ansible/bin/ansible-playbook ]]; then
  # 空 PYTHONPATH 时不得产生前导/尾随冒号（CWD 进入 sys.path）。
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

ROLE=roles/kube-proxy
INV=tests/kube-proxy/inventory.ini
PLAY_STACK=tests/kube-proxy/sandbox_stack.yml
PLAY_APISERVER=tests/kube-proxy/sandbox_apiserver.yml
PLAY_KP=tests/kube-proxy/sandbox_kube_proxy.yml
PLAY_REAL=tests/kube-proxy/real_kube_proxy.yml
UNIT_EXEC=tests/etcd/unit_exec.py

VERSION=1.31.0
KP_SHA=b4b4ecbfeb9f8897b672ff8fa53f3288580b361340d7b2daa40b476e2f2967ca
CACHE="${T009_TEST_CACHE:-/tmp/opencode/k8s-cache}"
ETCD_TARBALL=etcd-v3.5.16-linux-amd64.tar.gz
ETCD_TARBALL_SHA=b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc

# 动态用例端口（全部高位，不占默认 6443/10256/10249）
PORT_API=16443
PORT_ETCD=12379
PORT_KP_HEALTHZ=20247
PORT_KP_METRICS=20249
PORT_MOCK=18080
MOCK_IP=10.0.0.10
SVC_IP=10.96.0.50
MOCK_BODY=MOCK-OK-T009

declare -A ART_URL=(
  [kube-proxy]="https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kube-proxy"
  [kube-apiserver]="https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kube-apiserver"
  [kubectl]="https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kubectl"
  ["$ETCD_TARBALL"]="https://storage.googleapis.com/etcd/v3.5.16/${ETCD_TARBALL}"
)
declare -A ART_SHA=(
  [kube-proxy]="$KP_SHA"
  [kube-apiserver]=9016f6048ff9827ef58934e98f28a8026634c10b4e6fcc1df49451038a23a9aa
  [kubectl]=7c27adc64a84d1c0cc3dcf7bf4b6e916cc00f3f576a2dbac51b318d926032437
  ["$ETCD_TARBALL"]="$ETCD_TARBALL_SHA"
)

# --- 缓存预取：必须在 re-exec 进 netns **之前**（宿主网络）-------------------
ensure_artifact() {  # ensure_artifact <name> <url> <sha>
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
  for n in kube-proxy kube-apiserver kubectl; do
    ensure_artifact "$n" "${ART_URL[$n]}" "${ART_SHA[$n]}" || return 1
  done
  ensure_etcd_tarball
}

# 密闭性模式：suite = 已在独立 netns（仅 lo）内；none = 未隔离。
NETNS_MODE="none"
if [[ "${T009_IN_NETNS:-0}" == "1" ]]; then
  NETNS_MODE="suite"
else
  if ! prefill_cache; then
    printf '  \033[31mFAIL\033[0m 无法预取官方制品（首次运行需要外网；见上方 curl 错误）\n'
    echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) =="
    exit 1
  fi
  if sudo -n true 2>/dev/null &&
    sudo -n unshare -n bash -c 'ip link set lo up >/dev/null 2>&1; ! ip route show default | grep -q .' >/dev/null 2>&1; then
    exec sudo -n env T009_IN_NETNS=1 \
      PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}${USER_SITE:-}" \
      ANSIBLE_PLAYBOOK="$ANSIBLE_PLAYBOOK" \
      T009_TEST_CACHE="$CACHE" \
      ETCD_TEST_CACHE="${ETCD_TEST_CACHE:-}" \
      YAMLLINT="$YAMLLINT" \
      unshare -n bash -c 'ip link set lo up; exec "$@"' _ bash "$(readlink -f "$0")"
  fi
fi

echo "== T009 kube-proxy role 验收 =="

echo "-- A1 role / 测试资产结构"
for f in defaults/main.yml tasks/main.yml tasks/facts.yml tasks/validate.yml \
  tasks/binary.yml tasks/kubeconfig_file.yml tasks/config.yml tasks/service.yml \
  tasks/verify.yml handlers/main.yml meta/main.yml README.md; do
  check "存在 $ROLE/$f" test -f "$ROLE/$f"
done
for f in templates/kube-proxy-config.yaml.j2 templates/kube-proxy.service.j2 \
  templates/kube-proxy.conf.j2; do
  check "存在 $ROLE/$f" test -f "$ROLE/$f"
done
for f in "$INV" "$PLAY_STACK" "$PLAY_APISERVER" "$PLAY_KP" "$PLAY_REAL" "$UNIT_EXEC"; do
  check "存在 $f" test -f "$f"
done
check "存在 tests/kube-proxy/README.md" test -f tests/kube-proxy/README.md
# role 内任何文件都不得被 .gitignore 忽略（`kubeconfig.*` 规则曾吞掉任务文件）。
check_not "role 无被 .gitignore 忽略的文件" \
  bash -c 'find "$1" -type f | git check-ignore --stdin >/dev/null 2>&1' _ "$ROLE"

if [[ ! -d "$ROLE" ]]; then
  bad "role 目录缺失：A2–A10 与全部动态用例无法判定（红阶段）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi

echo "-- A2 变量化 / 无硬编码"
D="$ROLE/defaults/main.yml"
for v in k8s_version k8s_artifact_dir k8s_bin_dir k8s_config_dir kube_systemd_dir; do
  check "defaults 复用 $v" grep -q "$v" "$D"
done
check "defaults 版本/已知 sha256 固定" \
  bash -c "grep -q 'kube_proxy_version' '$D' && grep -q 'kube_proxy_known_sha256' '$D'"
check "defaults proxy_mode 可配" grep -q '^kube_proxy_proxy_mode:' "$D"
check "defaults cluster_cidr 可配" grep -q '^kube_proxy_cluster_cidr:' "$D"
check "defaults healthz/metrics 可配" \
  bash -c "grep -q '^kube_proxy_healthz_bind_address:' '$D' && grep -q '^kube_proxy_metrics_bind_address:' '$D'"
check "defaults conntrack 可配" grep -q 'kube_proxy_conntrack_max_per_core' "$D"
check "defaults iptables/ipvs 参数可配" \
  bash -c "grep -q 'kube_proxy_iptables_sync_period' '$D' && grep -q 'kube_proxy_ipvs_scheduler' '$D'"
check "defaults kubeconfig 来源/权限可配" \
  bash -c "grep -q '^kube_proxy_kubeconfig_source:' '$D' && grep -q '^kube_proxy_kubeconfig_mode:' '$D'"
check_not "tasks 无硬编码 IPv4" \
  grep -rqE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$ROLE/tasks"
check_not "tasks 无硬编码 6443/10256/10249/2379" \
  grep -rqE '(^|[^0-9])(6443|10256|10249|2379)([^0-9]|$)' "$ROLE/tasks"
check_not "tasks 无硬编码 /etc/kubernetes" grep -rq '/etc/kubernetes' "$ROLE/tasks"
check_not "tasks 无硬编码 /etc/systemd/system" grep -rq '/etc/systemd/system' "$ROLE/tasks"
check_not "tasks 无硬编码 /var/lib/kube-proxy" grep -rq '/var/lib/kube-proxy' "$ROLE/tasks"
check_not "tasks 无硬编码下载 URL" grep -rqE 'https?://' "$ROLE/tasks"
check "使用 FQCN ansible.builtin" grep -rq 'ansible\.builtin\.' "$ROLE/tasks"
check "二进制经 download role（不直连）" grep -rq 'name: download' "$ROLE/tasks"
check_not "templates 无硬编码 /etc/kubernetes" grep -rq '/etc/kubernetes' "$ROLE/templates"
check_not "templates 无硬编码 /etc/systemd/system" grep -rq '/etc/systemd/system' "$ROLE/templates"

echo "-- A3 KubeProxyConfiguration 模板"
T_CONF="$ROLE/templates/kube-proxy-config.yaml.j2"
check "A3 apiVersion 正确" grep -q 'apiVersion: kubeproxy.config.k8s.io/v1alpha1' "$T_CONF"
check "A3 kind 正确" grep -q 'kind: KubeProxyConfiguration' "$T_CONF"
check "A3 mode 变量化" grep -q 'mode: {{ kube_proxy_proxy_mode }}' "$T_CONF"
check "A3 clusterCIDR 变量化" grep -q 'clusterCIDR: {{ kube_proxy_cluster_cidr }}' "$T_CONF"
check "A3 bindAddress 变量化" grep -q 'bindAddress: {{ kube_proxy_bind_address }}' "$T_CONF"
check "A3 healthzBindAddress 变量化" grep -q 'healthzBindAddress: {{ kube_proxy_healthz_bind_address }}' "$T_CONF"
check "A3 metricsBindAddress 变量化" grep -q 'metricsBindAddress: {{ kube_proxy_metrics_bind_address }}' "$T_CONF"
check "A3 hostnameOverride 变量化" grep -q 'hostnameOverride: {{ kube_proxy_hostname_override }}' "$T_CONF"
check "A3 detectLocalMode 变量化" grep -q 'detectLocalMode: {{ kube_proxy_detect_local_mode }}' "$T_CONF"
check "A3 clientConnection.kubeconfig 变量化" \
  bash -c "grep -q '^clientConnection:' '$T_CONF' && grep -q 'kubeconfig: {{ kube_proxy_kubeconfig_path }}' '$T_CONF'"
check "A3 conntrack 段" \
  bash -c "grep -q '^conntrack:' '$T_CONF' && grep -q 'maxPerCore: {{ kube_proxy_conntrack_max_per_core }}' '$T_CONF' && grep -q 'tcpEstablishedTimeout:' '$T_CONF'"
check "A3 iptables 段" \
  bash -c "grep -q '^iptables:' '$T_CONF' && grep -q 'masqueradeAll:' '$T_CONF' && grep -q 'syncPeriod: {{ kube_proxy_iptables_sync_period }}' '$T_CONF'"
check "A3 ipvs 段（条件渲染）" \
  bash -c "grep -q \"kube_proxy_proxy_mode == 'ipvs'\" '$T_CONF' && grep -q '^ipvs:' '$T_CONF'"
check "A3 nodePortAddresses 变量化" grep -q 'nodePortAddresses: {{ kube_proxy_node_port_addresses' "$T_CONF"

echo "-- A4 systemd unit 模板"
T_UNIT="$ROLE/templates/kube-proxy.service.j2"
check "A4 ExecStart 使用变量二进制 + 参数列表" \
  grep -q 'ExecStart={{ kube_proxy_binary }} {{ kube_proxy_args | join' "$T_UNIT"
check "A4 Restart=always" grep -q '^Restart=always' "$T_UNIT"
check "A4 RestartSec" grep -q '^RestartSec=' "$T_UNIT"
check "A4 LimitNOFILE" grep -q '^LimitNOFILE=' "$T_UNIT"
check "A4 After=network-online.target" grep -q '^After=network-online.target' "$T_UNIT"
check "A4 WantedBy=multi-user.target" grep -q '^WantedBy=multi-user.target' "$T_UNIT"
check_not "A4 unit 无硬编码默认端口" grep -qE '10256|10249' "$T_UNIT"

echo "-- A5 facts / 服务接线"
check "A5 facts 渲染 --config" grep -q -- '--config=' "$ROLE/tasks/facts.yml"
check "A5 facts 渲染 --hostname-override" grep -q -- '--hostname-override=' "$ROLE/tasks/facts.yml"
check "A5 service.yml 使用 ansible.builtin.systemd" \
  grep -q 'ansible.builtin.systemd' "$ROLE/tasks/service.yml"
check "A5 service.yml 设置 enabled" grep -q 'enabled:' "$ROLE/tasks/service.yml"
check "A5 service.yml daemon_reload" grep -q 'daemon_reload: true' "$ROLE/tasks/service.yml"
check "A5 defaults manage_service=true" grep -qE '^kube_proxy_manage_service:[[:space:]]*true' "$D"
check "A5 defaults enabled=true" grep -qE '^kube_proxy_service_enabled:[[:space:]]*true' "$D"
check "A5 defaults state=started" grep -qE '^kube_proxy_service_state:[[:space:]]*started' "$D"
check "A5 handler 使用 restarted" grep -q 'state: restarted' "$ROLE/handlers/main.yml"
check "A5 handler 受 manage_service 控制" grep -q 'kube_proxy_manage_service | bool' "$ROLE/handlers/main.yml"

echo "-- A6 安全默认"
check "A6 healthz 默认 127.0.0.1" grep -qE '^kube_proxy_healthz_bind_address:.*127\.0\.0\.1' "$D"
check "A6 metrics 默认 127.0.0.1" grep -qE '^kube_proxy_metrics_bind_address:.*127\.0\.0\.1' "$D"
check_not "A6 healthz 默认非 0.0.0.0" grep -qE '^kube_proxy_healthz_bind_address:.*0\.0\.0\.0' "$D"
check_not "A6 metrics 默认非 0.0.0.0" grep -qE '^kube_proxy_metrics_bind_address:.*0\.0\.0\.0' "$D"
check "A6 kubeconfig 0600" grep -qE '^kube_proxy_kubeconfig_mode:[[:space:]]*"0600"' "$D"
check "A6 无非安全 --anonymous 参数" \
  bash -c "! grep -rq -- '--anonymous-auth=true' '$ROLE'"

echo "-- A7 kubeconfig 两种来源"
check "A7 source 分支使用 copy + 0600" \
  bash -c "grep -q 'ansible.builtin.copy' '$ROLE/tasks/kubeconfig_file.yml' && grep -q 'kube_proxy_kubeconfig_mode' '$ROLE/tasks/kubeconfig_file.yml'"
check "A7 embedded 分支内嵌证书/私钥" \
  bash -c "grep -q 'client-certificate-data' '$ROLE/templates/kube-proxy.conf.j2' && grep -q 'client-key-data' '$ROLE/templates/kube-proxy.conf.j2'"
check "A7 embedded 分支变量化 server/CA" \
  bash -c "grep -q 'certificate-authority-data' '$ROLE/templates/kube-proxy.conf.j2' && grep -q 'server: {{ kube_proxy_apiserver_url }}' '$ROLE/templates/kube-proxy.conf.j2'"

echo "-- A8 范围约束（不接入 site.yml；不改已验收资产）"
check_not "playbooks/site.yml 未引用 kube-proxy" grep -qE 'kube-proxy|kube_proxy' playbooks/site.yml
if git rev-parse --git-dir >/dev/null 2>&1; then
  frozen="tests/skeleton tests/base tests/download tests/pki tests/etcd tests/ha tests/control-plane tests/node roles/base roles/download roles/pki roles/etcd roles/haproxy roles/keepalived roles/kube-apiserver roles/kube-controller-manager roles/kube-scheduler roles/containerd roles/kubelet"
  dirty="$(git status --porcelain -- $frozen | wc -l)"
  check "已 PASS 的 roles/tests 未被改动" test "$dirty" -eq 0
  check_not "工作区无未忽略的密钥/证书/kubeconfig" \
    bash -c "git status --porcelain | grep -qE '\.(key|crt|pem)$'"
fi

echo "-- A9 语法与风格"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_STACK" >/tmp/opencode/t009_syntax_stack.log 2>&1 &&
    "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_APISERVER" >/tmp/opencode/t009_syntax_apiserver.log 2>&1 &&
    "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_KP" >/tmp/opencode/t009_syntax_kp.log 2>&1 &&
    "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_REAL" >/tmp/opencode/t009_syntax_real.log 2>&1; then
    ok "全部 tests/kube-proxy playbook --syntax-check 通过"
  else
    bad "tests/kube-proxy playbook --syntax-check 失败（见 /tmp/opencode/t009_syntax_*.log）"
  fi
else
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi
if [[ -x "$YAMLLINT" ]] || command -v "$YAMLLINT" >/dev/null 2>&1; then
  if PYTHONPATH="${USER_SITE:+$USER_SITE}${PYTHONPATH:+:$PYTHONPATH}" "$YAMLLINT" -c .yamllint \
    "$ROLE" tests/kube-proxy >/tmp/opencode/t009_yamllint.log 2>&1; then
    ok "yamllint（roles/kube-proxy, tests/kube-proxy）无 error"
  else
    bad "yamllint 失败（见 /tmp/opencode/t009_yamllint.log）"
  fi
else
  bad "找不到 yamllint"
fi

echo "-- A10 文档"
check "A10 role README 说明变量与验证方式" \
  bash -c "grep -qi '变量' '$ROLE/README.md' && grep -qi '验证' '$ROLE/README.md'"
check "A10 role README 声明 systemd/受限" grep -qi 'systemd' "$ROLE/README.md"
check "A10 role README 声明未使用镜像/Pod" \
  bash -c "grep -qiE '镜像|Pod' '$ROLE/README.md'"
check "A10 tests README 说明缓存/netns/受限" \
  bash -c "grep -qi '缓存' tests/kube-proxy/README.md && grep -qi 'netns' tests/kube-proxy/README.md"

# ---------------------------------------------------------------------------
if ! have_ansible; then
  bad "找不到 ansible-playbook（跳过全部动态用例）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi
if [[ ! -d "$ROLE" ]]; then
  bad "kube-proxy role 不存在：动态用例无法执行（红阶段）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi
if ! sudo -n true 2>/dev/null; then
  bad "需要免密 sudo：以 root 应用属主模型并从 unit 拉起真实 kube-proxy"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi

# --- 缓存就绪校验（netns 内零网络；缺任何一个即失败）------------------------
cache_ok=1
for n in "${!ART_SHA[@]}"; do
  if [[ ! -f "$CACHE/$n" || "$(sha_of "$CACHE/$n")" != "${ART_SHA[$n]}" ]]; then
    bad "缓存缺失/校验失败：$n（需在宿主网络下预取）"
    cache_ok=0
  fi
done
if [[ $cache_ok -eq 1 ]]; then
  ok "全部 ${#ART_SHA[@]} 个制品缓存就绪（sha256 校验通过）"
else
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi

# --- B0 密闭性门禁 ---------------------------------------------------------
if [[ "$NETNS_MODE" == "suite" ]]; then
  if [[ -z "$(ip route show default 2>/dev/null)" ]] &&
    ! timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' >/dev/null 2>&1; then
    printf '  \033[32mOK\033[0m   B0 密闭性：套件运行于独立 netns（仅 lo、无默认路由，外网不可达）\n'
  else
    bad "B0 密闭性失败：netns 内存在默认路由或外网仍可达（断网验证失效）"
  fi
elif sudo -n unshare -n true >/dev/null 2>&1; then
  bad "B0 密闭性失败：unshare 可用但套件未在隔离 netns 中运行（re-exec 未生效）"
else
  printf '  （WARN 无 unshare 权限：无法启用断网自证）\n'
fi

# 空缓存 + 断网必须明确失败（反证：不得静默回退外网）
EMPTY_CACHE="$(mktemp -d /tmp/opencode/t009empty.XXXXXX)"
OFF_SB="$(mktemp -d /tmp/opencode/t009off.XXXXXX)"
chmod 0755 "$EMPTY_CACHE" "$OFF_SB"
mkdir -p "$OFF_SB/opt/k8s/artifacts" "$OFF_SB/etc/kubernetes"
cat >"$OFF_SB/etc/kubernetes/admin.conf" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: kubernetes
    cluster:
      server: https://127.0.0.1:16443
      insecure-skip-tls-verify: true
users:
  - name: dummy
    user:
      token: dummy
contexts:
  - name: dummy
    context:
      cluster: kubernetes
      user: dummy
current-context: dummy
preferences: {}
YAML
chmod 0600 "$OFF_SB/etc/kubernetes/admin.conf"
cp "$CACHE/kube-proxy" "$OFF_SB/opt/k8s/artifacts/kube-proxy"
chmod 0644 "$OFF_SB/opt/k8s/artifacts/kube-proxy"
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_KP" \
  -e "{\"sandbox_root\":\"$OFF_SB\",\"kube_proxy_artifact_dir\":\"$EMPTY_CACHE\",\"kube_proxy_artifact_path\":\"$EMPTY_CACHE/kube-proxy\",\"kube_proxy_download_url\":\"http://127.0.0.1:1/kube-proxy\",\"kube_proxy_sha256\":\"$KP_SHA\"}" \
  >/tmp/opencode/t009_b0_empty.log 2>&1 || rc=$?
check "B0 空缓存 + 断网 → role exit≠0" test "$rc" -ne 0
check "B0 空缓存 + 断网 → 错误可定位（download/URL/不可达）" \
  grep -qiE 'download|Failed to|unreachable|Connection refused|Could not resolve|sha256' /tmp/opencode/t009_b0_empty.log

# 缓存命中 + 不可达 URL → 必须成功（证明走 roles/download 缓存）
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_KP" \
  -e "{\"sandbox_root\":\"$OFF_SB\",\"kube_proxy_artifact_dir\":\"$OFF_SB/opt/k8s/artifacts\",\"kube_proxy_artifact_path\":\"$OFF_SB/opt/k8s/artifacts/kube-proxy\",\"kube_proxy_download_url\":\"http://127.0.0.1:1/kube-proxy\",\"kube_proxy_sha256\":\"$KP_SHA\"}" \
  >/tmp/opencode/t009_b0_offline.log 2>&1 || rc=$?
check "B0 缓存命中 + 不可达 URL → role exit 0" test "$rc" -eq 0
check "B0 缓存命中 → kube-proxy 二进制存在且可执行" test -x "$OFF_SB/usr/local/bin/kube-proxy"
check "B0 缓存命中 → 未发起外网请求（日志无连接失败）" \
  bash -c "! grep -qiE 'Could not resolve|Connection refused|Failed to download' /tmp/opencode/t009_b0_offline.log"
sudo -n rm -rf "$EMPTY_CACHE" "$OFF_SB"

# --- 宿主零污染快照（宿主 netns 经 nsenter -t 1 -n 观测）-------------------
host_ipt_raw() {
  # nft 后端的 iptables-save 会带 [packets:bytes] 计数器（链策略与规则都会变化），
  # 且首行含时间戳；两者都必须剥离后再比较。空输出（xtables lock 争用）时重试。
  local i out
  for ((i = 0; i < 20; i++)); do
    out="$({ nsenter -t 1 -n iptables-save; nsenter -t 1 -n ip6tables-save; } 2>/dev/null \
      | grep -v '^#' | sed -E 's/\[[0-9]+:[0-9]+\]//g' | sed -E 's/[[:space:]]+$//' \
      | sed '/^$/d' | sort)"
    [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    sleep 0.2
  done
  return 1
}
host_ipt() { host_ipt_raw | sha256sum | awk '{print $1}'; }
# iptables-save 会按 ~80 列用反斜杠续行，规则匹配前先折叠续行。
nat_rules() { iptables-save -t nat 2>/dev/null | sed -e ':a' -e 'N' -e '$!ba' -e 's/\\\n/ /g'; }
host_ports() {
  # 与 host_ipt_raw() 对齐：nsenter/ss 可能瞬时失败或输出为空（netlink 争用、
  # nsenter 启动抖动）。空输出时重试（20 次 × 0.2s）；重试耗尽返回非零，
  # 避免把「采集失败」误判成「端口变化」而随机红（r1 的 flaky 根因）。
  local i out
  for ((i = 0; i < 20; i++)); do
    out="$(nsenter -t 1 -n ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | sort -u | tr '\n' ' ')"
    [[ -n "${out// /}" ]] && { printf '%s\n' "$out"; return 0; }
    sleep 0.2
  done
  return 1
}
# B10 只断言「本任务端口是否泄漏到宿主」，不比较全局监听端口：
# 共享宿主的无关进程（编辑器/dev server/浏览器等）会随机增删监听端口，
# 全局快照因此天然 flaky（r1 实测 5 次中 1 次红）；本任务端口集合是确定的。
TASK_PORTS_RE=":(${PORT_API}|${PORT_ETCD}|${PORT_KP_HEALTHZ}|${PORT_KP_METRICS}|${PORT_MOCK})$"
filter_task_ports() {
  printf '%s\n' "$1" | tr ' ' '\n' | grep -E "$TASK_PORTS_RE" | sort -u | tr '\n' ' ' || true
}
PRE_HOST_IPT="$(host_ipt)"
PRE_HOST_IPT_RAW="$(host_ipt_raw)"
PRE_HOST_PORTS_FULL="$(host_ports)" || PRE_HOST_PORTS_FULL="__CAPTURE_FAILED__"
if [[ "$PRE_HOST_PORTS_FULL" == "__CAPTURE_FAILED__" ]]; then
  bad "B10 宿主监听端口快照（PRE）采集失败（重试耗尽）"
  PRE_HOST_PORTS="__CAPTURE_FAILED__"
else
  PRE_HOST_PORTS="$(filter_task_ports "$PRE_HOST_PORTS_FULL")"
fi
PRE_HOST_UNIT="$(snapshot_path /etc/systemd/system/kube-proxy.service)"
PRE_ETC_K8S="$(snapshot_path /etc/kubernetes)"
PRE_VAR_LIB_KP="$(snapshot_path /var/lib/kube-proxy)"
PRE_HOST_SVC_IP="$(nsenter -t 1 -n ip route show 2>/dev/null | grep -c '10.96.0.0/12')"
PRE_HOST_SVC_RULES="$(host_ipt_raw | grep -c "$SVC_IP" || true)"

SB=""
declare -A WRAPPER=()
KUBECTL=""
MOCK_WRAPPER=""
KP_WRAPPER=""

stop_proc() {
  local pat="$1" i
  pkill -TERM -f -- "$pat" 2>/dev/null || true
  for ((i = 0; i < 80; i++)); do
    pgrep -f -- "$pat" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  pkill -9 -f -- "$pat" 2>/dev/null || true
  for ((i = 0; i < 40; i++)); do
    pgrep -f -- "$pat" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 0
}
cleanup() {
  local k
  [[ -n "${SB:-}" ]] || return 0
  stop_proc "$SB/usr/local/bin/kube-proxy"
  stop_proc "http.server $PORT_MOCK"
  stop_proc "$SB/usr/local/bin/kube-apiserver"
  stop_proc "$SB/usr/local/bin/etcd"
  for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
  [[ "${T009_KEEP_SB:-0}" == "1" ]] && { printf '  （T009_KEEP_SB=1：保留沙箱 %s）\n' "$SB"; return 0; }
  rm -rf "$SB" 2>/dev/null || true
}
trap cleanup EXIT

port_free() { ! ss -ltn 2>/dev/null | grep -qE ':('"$PORT_API"'|'"$PORT_KP_HEALTHZ"'|'"$PORT_KP_METRICS"'|'"$PORT_ETCD"'|'"$PORT_MOCK"')[[:space:]]'; }
wait_port() {
  local p="$1" i
  for ((i = 0; i < 160; i++)); do
    ss -ltn 2>/dev/null | grep -qE ":${p}[[:space:]]" && return 0
    sleep 0.25
  done
  return 1
}
wait_ports_free() {
  local i
  for ((i = 0; i < 60; i++)); do port_free && return 0; sleep 0.5; done
  return 1
}
proc_pid() { pgrep -f -- "$SB/usr/local/bin/$1" 2>/dev/null | head -1; }
proc_starttime() { awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/${1}/stat" 2>/dev/null; }
unit_path() { printf '%s/etc/systemd/system/%s.service' "$SB" "$1"; }

SB="$(mktemp -d /tmp/opencode/t009.XXXXXX)"
chmod 0755 "$SB"
mkdir -p "$SB/opt/k8s/artifacts" "$SB/logs" "$SB/client" "$SB/etc" "$SB/var" "$SB/www"
chmod 0755 "$SB/etc" "$SB/var"
for n in "${!ART_SHA[@]}"; do
  cp "$CACHE/$n" "$SB/opt/k8s/artifacts/$n"
done
chown -R root:root "$SB/opt/k8s/artifacts"
chmod 0644 "$SB"/opt/k8s/artifacts/*
ok "沙箱制品已就绪（$SB）"

ap() {  # ap <playbook> <log> [额外的 -e ...]
  local play="$1" log="$2"
  shift 2
  timeout 900 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" -e "{\"sandbox_root\":\"$SB\"}" "$@" >"$log" 2>&1
}

echo "-- B1 真实控制面（pki + 单成员 TLS etcd + kube-apiserver）"
if ap "$PLAY_STACK" /tmp/opencode/t009_stack.log; then
  ok "stack playbook exit 0（kubectl + pki + etcd 渲染）"
else
  bad "stack playbook 失败（见 /tmp/opencode/t009_stack.log）"
fi
check "B1 产出 kubernetes-ca" test -f "$SB/etc/kubernetes/pki/ca.crt"
check "B1 kubectl 已安装到沙箱" test -x "$SB/usr/local/bin/kubectl"

ETCD_UNIT="$(unit_path etcd-etcd1)"
check "B1 etcd unit 已渲染" test -f "$ETCD_UNIT"
mapfile -t ETCD_ARGS < <(python3 "$UNIT_EXEC" "$ETCD_UNIT")
if [[ ${#ETCD_ARGS[@]} -gt 0 ]]; then
  ( setpriv --reuid 65534 --regid 65534 --clear-groups \
      "${ETCD_ARGS[@]}" </dev/null >>"$SB/logs/etcd.log" 2>&1 ) &
  WRAPPER[etcd]=$!
  ok "已从 etcd unit 拉起单成员 TLS etcd"
else
  bad "无法解析 etcd unit 的 ExecStart"
fi
ETCD_PKI="$SB/etc/kubernetes/pki/etcd"
install -m 0600 -o "$(id -u)" -g "$(id -g)" "$ETCD_PKI/ca.crt" "$SB/client/etcd-ca.crt"
install -m 0600 -o "$(id -u)" -g "$(id -g)" \
  "$SB/etc/kubernetes/pki/apiserver-etcd-client.crt" "$SB/client/etcd-client.crt"
install -m 0600 -o "$(id -u)" -g "$(id -g)" \
  "$SB/etc/kubernetes/pki/apiserver-etcd-client.key" "$SB/client/etcd-client.key"
ETCDCTL="$SB/usr/local/bin/etcdctl"
etcd_healthy() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints=https://127.0.0.1:"$PORT_ETCD" \
    --cacert "$SB/client/etcd-ca.crt" --cert "$SB/client/etcd-client.crt" \
    --key "$SB/client/etcd-client.key" --command-timeout=2s endpoint health >/dev/null 2>&1
}
wait_etcd() {
  local i
  for ((i = 0; i < 120; i++)); do etcd_healthy && return 0; sleep 0.5; done
  return 1
}
check "B1 单成员 etcd healthy（真实 TLS）" wait_etcd

if ap "$PLAY_APISERVER" /tmp/opencode/t009_apiserver.log; then
  ok "apiserver playbook exit 0（沙箱渲染）"
else
  bad "apiserver playbook 失败（见 /tmp/opencode/t009_apiserver.log）"
fi
UNIT_API="$(unit_path kube-apiserver)"
check "B1 apiserver unit 已渲染" test -f "$UNIT_API"
check "B1 产出 admin.conf（kube-proxy 的引导 kubeconfig）" test -f "$SB/etc/kubernetes/admin.conf"
mapfile -t API_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_API")
if [[ ${#API_ARGS[@]} -gt 0 ]]; then
  ( "${API_ARGS[@]}" </dev/null >>"$SB/logs/apiserver.log" 2>&1 ) &
  WRAPPER[apiserver]=$!
  ok "已从 unit 拉起 kube-apiserver"
else
  bad "无法解析 apiserver unit 的 ExecStart"
fi
install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/admin.conf" "$SB/client/admin.conf"
install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/pki/ca.crt" "$SB/client/ca.crt"
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
check "B1 kubectl get --raw /healthz = ok" wait_healthz

echo "-- B2 Service/EndpointSlice 夹具 + 本地 mock 后端（无镜像/无 Pod）"
kctl create -f - >"$SB/logs/node-create.log" 2>&1 <<'YAML'
apiVersion: v1
kind: Node
metadata:
  name: node1
  labels:
    kubernetes.io/hostname: node1
status:
  addresses:
    - type: InternalIP
      address: 127.0.0.1
    - type: Hostname
      address: node1
YAML
check "B2 Node node1 已创建（kube-proxy 启动前置）" \
  bash -c "'$KUBECTL' --kubeconfig '$SB/client/admin.conf' get node node1 -o name 2>/dev/null | grep -qx node/node1"
kctl create -f - >"$SB/logs/svc-create.log" 2>&1 <<YAML
apiVersion: v1
kind: Service
metadata:
  name: mock
  namespace: default
spec:
  type: ClusterIP
  clusterIP: $SVC_IP
  selector:
    app: mock
  ports:
    - name: http
      port: 80
      targetPort: $PORT_MOCK
      protocol: TCP
YAML
check "B2 Service mock ClusterIP=$SVC_IP:80 已创建" \
  bash -c "[[ \"\$('$KUBECTL' --kubeconfig '$SB/client/admin.conf' get svc mock -o jsonpath='{.spec.clusterIP}' 2>/dev/null)\" == '$SVC_IP' ]]"
kctl create -f - >"$SB/logs/epslice-create.log" 2>&1 <<YAML
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: mock-abc
  namespace: default
  labels:
    kubernetes.io/service-name: mock
addressType: IPv4
ports:
  - name: http
    port: $PORT_MOCK
    protocol: TCP
endpoints:
  - addresses:
      - $MOCK_IP
    conditions:
      ready: true
      serving: true
      terminating: false
YAML
check "B2 EndpointSlice mock-abc 已创建" \
  bash -c "[[ \"\$('$KUBECTL' --kubeconfig '$SB/client/admin.conf' get endpointslice mock-abc -o jsonpath='{.metadata.name}' 2>/dev/null)\" == 'mock-abc' ]]"

# 后端地址（非 loopback：EndpointSlice 拒绝 127/8）+ service CIDR 路由
# （真实节点有默认路由；netns 内显式给 ClusterIP 一条 lo 路由，属测试夹具）。
ip addr add "$MOCK_IP/32" dev lo 2>/dev/null || true
# 说明：给 ClusterIP 加 lo 路由**不构成绕过 kube-proxy**——DNAT 在 OUTPUT 链生效
# （KUBE-SERVICES/KUBE-NODEPORTS），curl 发往 10.96.0.50 时先被 DNAT 到
# 10.0.0.10:18080；若 kube-proxy 规则缺失，路由仍指向 lo 但该端口无监听 → 连接拒绝
# （B5 会红）。因此该路由只是补足 netns 缺少默认路由的夹具。
ip route add "$SVC_IP/32" dev lo 2>/dev/null || true
ip route add 10.96.0.0/12 dev lo 2>/dev/null || true
printf '%s\n' "$MOCK_BODY" >"$SB/www/health"
start_mock() {
  ( cd "$SB/www" && exec python3 -m http.server "$PORT_MOCK" --bind "$MOCK_IP" >"$SB/logs/mock.log" 2>&1 ) &
  MOCK_WRAPPER=$!
  local i
  for ((i = 0; i < 60; i++)); do
    curl -sS --noproxy '*' -m 1 "http://$MOCK_IP:$PORT_MOCK/health" 2>/dev/null | grep -qx "$MOCK_BODY" && return 0
    sleep 0.1
  done
  return 1
}
stop_mock() {
  pkill -TERM -f "http.server $PORT_MOCK" 2>/dev/null || true
  wait "$MOCK_WRAPPER" 2>/dev/null || true
  local i
  for ((i = 0; i < 40; i++)); do
    ss -ltn 2>/dev/null | grep -qE ":${PORT_MOCK}[[:space:]]" || return 0
    sleep 0.1
  done
  return 0
}
check "B2 本地 mock HTTP 已启动（$MOCK_IP:$PORT_MOCK）" start_mock
check "B2 mock 直连返回已知响应" \
  bash -c "curl -sS --noproxy '*' -m 2 'http://$MOCK_IP:$PORT_MOCK/health' | grep -qx '$MOCK_BODY'"

echo "-- B3 kube-proxy role 首跑（真实安装/渲染，不调 systemctl）"
if ap "$PLAY_KP" /tmp/opencode/t009_kp_run1.log; then
  ok "kube-proxy playbook 首跑 exit 0"
else
  bad "kube-proxy playbook 首跑失败（见 /tmp/opencode/t009_kp_run1.log）"
fi
K1="$(changed_of /tmp/opencode/t009_kp_run1.log)"
check "B3 首跑 changed>0（真实安装/渲染）" test "${K1:-0}" -gt 0
UNIT_KP="$(unit_path kube-proxy)"
CONF_KP="$SB/etc/kubernetes/kube-proxy.yaml"
KC_KP="$SB/etc/kubernetes/kube-proxy.conf"
check "B3 kube-proxy 二进制已安装且可执行" test -x "$SB/usr/local/bin/kube-proxy"
check "B3 kube-proxy 版本 = v$VERSION" \
  bash -c "'$SB/usr/local/bin/kube-proxy' --version 2>/dev/null | grep -q 'Kubernetes v$VERSION'"
check "B3 config 已渲染" test -f "$CONF_KP"
check "B3 unit 已渲染" test -f "$UNIT_KP"
check "B3 kubeconfig 已渲染" test -f "$KC_KP"
check "B3 kubeconfig 权限 0600 root:root" \
  bash -c "[[ \"\$(stat -c '%u:%g %a' '$KC_KP' 2>/dev/null)\" == '0:0 600' ]]"
check "B3 kubeconfig 是 admin.conf 的副本（引导凭据）" \
  bash -c "[[ \"\$(sha256sum '$KC_KP' | awk '{print \$1}')\" == \"\$(sha256sum '$SB/etc/kubernetes/admin.conf' | awk '{print \$1}')\" ]]"
check "B3 config mode=iptables" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("mode")=="iptables" else 1)' "$CONF_KP"
check "B3 config clusterCIDR=10.244.0.0/16" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("clusterCIDR")=="10.244.0.0/16" else 1)' "$CONF_KP"
check "B3 config bindAddress=127.0.0.1" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("bindAddress")=="127.0.0.1" else 1)' "$CONF_KP"
check "B3 config healthzBindAddress=127.0.0.1:$PORT_KP_HEALTHZ" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("healthzBindAddress")==sys.argv[2] else 1)' "$CONF_KP" "127.0.0.1:$PORT_KP_HEALTHZ"
check "B3 config metricsBindAddress=127.0.0.1:$PORT_KP_METRICS" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("metricsBindAddress")==sys.argv[2] else 1)' "$CONF_KP" "127.0.0.1:$PORT_KP_METRICS"
check "B3 config hostnameOverride=node1" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("hostnameOverride")=="node1" else 1)' "$CONF_KP"
check "B3 config detectLocalMode=ClusterCIDR" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("detectLocalMode")=="ClusterCIDR" else 1)' "$CONF_KP"
check "B3 config clientConnection.kubeconfig 指向沙箱" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d["clientConnection"]["kubeconfig"]==sys.argv[2] else 1)' "$CONF_KP" "$KC_KP"
check "B3 config conntrack 段存在且可解析" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); c=d.get("conntrack") or {}; sys.exit(0 if "maxPerCore" in c and "tcpEstablishedTimeout" in c else 1)' "$CONF_KP"
check "B3 config iptables.syncPeriod 变量生效" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d["iptables"].get("syncPeriod")=="5s" else 1)' "$CONF_KP"
check "B3 unit ExecStart 使用沙箱二进制 + --config" \
  grep -q "^ExecStart=$SB/usr/local/bin/kube-proxy .*--config=$CONF_KP" "$UNIT_KP"
check "B3 unit --hostname-override=node1" grep -q -- '--hostname-override=node1' "$UNIT_KP"
check "B3 unit Restart=always" grep -q '^Restart=always' "$UNIT_KP"
check "B3 unit LimitNOFILE" grep -q '^LimitNOFILE=' "$UNIT_KP"
check "B3 unit After=network-online.target" grep -q '^After=network-online.target' "$UNIT_KP"
check "B3 unit WantedBy=multi-user.target" grep -q '^WantedBy=multi-user.target' "$UNIT_KP"
check_not "B3 unit 未占用默认 10256/10249" grep -qE '10256|10249' "$UNIT_KP"

echo "-- B4 从 unit ExecStart 拉起真实 kube-proxy → 规则下发"
mapfile -t KP_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_KP")
if [[ ${#KP_ARGS[@]} -gt 0 ]]; then
  ( "${KP_ARGS[@]}" </dev/null >>"$SB/logs/kube-proxy.log" 2>&1 ) &
  KP_WRAPPER=$!
  for _ in $(seq 1 120); do PID_KP="$(proc_pid kube-proxy)"; [[ -n "$PID_KP" ]] && break; sleep 0.1; done
  ok "已从 unit 拉起真实 kube-proxy（PID ${PID_KP:-?}）"
else
  bad "无法解析 kube-proxy unit 的 ExecStart"
fi
check "B4 kube-proxy 进程存活" test -n "${PID_KP:-}"
kp_healthy() {
  local i
  for ((i = 0; i < 160; i++)); do
    [[ "$(curl -sS --noproxy '*' -m 2 -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:$PORT_KP_HEALTHZ/healthz" 2>/dev/null)" == "200" ]] && return 0
    sleep 0.25
  done
  return 1
}
check "B4 healthz /healthz = HTTP 200（proxier 已同步）" kp_healthy
check "B4 healthz 内容含 nodeEligible" \
  bash -c "curl -sS --noproxy '*' -m 2 'http://127.0.0.1:$PORT_KP_HEALTHZ/healthz' | grep -q 'nodeEligible'"
check "B4 metrics 仅监听 127.0.0.1:$PORT_KP_METRICS（非 0.0.0.0）" \
  bash -c "ss -ltn 2>/dev/null | grep -qE '127\.0\.0\.1:${PORT_KP_METRICS}[[:space:]]' && ! ss -ltn 2>/dev/null | grep -qE '0\.0\.0\.0:${PORT_KP_METRICS}[[:space:]]'"
check "B4 metrics /metrics 含 kube_proxy 指标" \
  bash -c "curl -sS --noproxy '*' -m 3 'http://127.0.0.1:$PORT_KP_METRICS/metrics' | grep -qi 'kubeproxy'"
rule_present() { nat_rules | grep -qE "$1"; }
wait_rule() {
  local pat="$1" i
  for ((i = 0; i < 120; i++)); do rule_present "$pat" && return 0; sleep 0.25; done
  return 1
}
check "B4 iptables nat 含 KUBE-SERVICES 链" wait_rule 'KUBE-SERVICES'
check "B4 iptables 含 Service $SVC_IP:80 → KUBE-SVC 规则" \
  wait_rule "KUBE-SERVICES -d ${SVC_IP//./\\.}/32 .*--dport 80"
check "B4 iptables 含 DNAT 到后端 $MOCK_IP:$PORT_MOCK" \
  wait_rule "DNAT --to-destination $MOCK_IP:$PORT_MOCK"
check "B4 进程参数含 --config" \
  bash -c "tr '\\0' '\\n' <'/proc/${PID_KP:-0}/cmdline' | grep -q -- '--config=$CONF_KP'"
check "B4 进程参数含 --hostname-override=node1" \
  bash -c "tr '\\0' '\\n' <'/proc/${PID_KP:-0}/cmdline' | grep -qx -- '--hostname-override=node1'"
check "B4 日志显示 iptables 规则同步完成" \
  grep -qE 'SyncProxyRules complete|Syncing iptables rules' "$SB/logs/kube-proxy.log"

echo "-- B5 ClusterIP 真实可访问（A9 核心）"
clusterip_get() {
  curl -sS --noproxy '*' -m 5 -w '\n%{http_code}' "http://$SVC_IP/health" 2>/dev/null
}
wait_clusterip() {
  local i out
  for ((i = 0; i < 80; i++)); do
    out="$(clusterip_get)" || true
    [[ "$(printf '%s' "$out" | tail -1)" == "200" ]] && return 0
    sleep 0.25
  done
  return 1
}
check "B5 curl http://$SVC_IP:80/health → HTTP 200" wait_clusterip
check "B5 ClusterIP 响应体 = mock 已知响应（$MOCK_BODY）" \
  bash -c "curl -sS --noproxy '*' -m 5 'http://$SVC_IP/health' | grep -qx '$MOCK_BODY'"
check "B5 响应来自本地 mock（后端端口 $PORT_MOCK）" \
  bash -c "curl -sS --noproxy '*' -m 5 -D - 'http://$SVC_IP/health' -o /dev/null | grep -qi '^HTTP/1.0 200'"

echo "-- B6 边界：后端不可用 → ClusterIP 失败；恢复 → 成功"
stop_mock
check "B6 mock 停止后端口已释放" \
  bash -c "! ss -ltn 2>/dev/null | grep -qE ':${PORT_MOCK}[[:space:]]'"
check "B6 后端不可用 → curl ClusterIP 失败（非 0）" \
  bash -c "! curl -sS --noproxy '*' -m 3 'http://$SVC_IP/health' >/dev/null 2>&1"
check "B6 mock 重启" start_mock
check "B6 后端恢复 → curl ClusterIP 再次成功" wait_clusterip
check "B6 恢复后响应体正确" \
  bash -c "curl -sS --noproxy '*' -m 5 'http://$SVC_IP/health' | grep -qx '$MOCK_BODY'"

echo "-- B7 边界：EndpointSlice 移除 → 规则移除且 ClusterIP 失败；恢复 → 成功"
kctl delete endpointslice mock-abc >"$SB/logs/epslice-delete.log" 2>&1
check "B7 EndpointSlice 已删除" \
  bash -c "! '$KUBECTL' --kubeconfig '$SB/client/admin.conf' get endpointslice mock-abc >/dev/null 2>&1"
wait_dnat_gone() {
  local i
  for ((i = 0; i < 160; i++)); do
    nat_rules | grep -q "DNAT --to-destination $MOCK_IP:$PORT_MOCK" || return 0
    sleep 0.25
  done
  return 1
}
check "B7 后端 DNAT 规则已移除（kube-proxy 已同步）" wait_dnat_gone
check "B7 无端点 → curl ClusterIP 失败（非 0）" \
  bash -c "! curl -sS --noproxy '*' -m 3 'http://$SVC_IP/health' >/dev/null 2>&1"
kctl create -f - >"$SB/logs/epslice-restore.log" 2>&1 <<YAML
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: mock-abc
  namespace: default
  labels:
    kubernetes.io/service-name: mock
addressType: IPv4
ports:
  - name: http
    port: $PORT_MOCK
    protocol: TCP
endpoints:
  - addresses:
      - $MOCK_IP
    conditions:
      ready: true
      serving: true
      terminating: false
YAML
wait_dnat_back() {
  local i
  for ((i = 0; i < 160; i++)); do
    nat_rules | grep -q "DNAT --to-destination $MOCK_IP:$PORT_MOCK" && return 0
    sleep 0.25
  done
  return 1
}
check "B7 EndpointSlice 恢复 → DNAT 规则重新下发" wait_dnat_back
check "B7 恢复后 curl ClusterIP 成功" wait_clusterip

echo "-- B8 幂等（运行中重跑：changed=0 / 不通知 handler / PID 不变）"
PID_BEFORE="${PID_KP:-0}"
ST_BEFORE="$(proc_starttime "$PID_BEFORE")"
HASH_BEFORE="$(sha_of "$CONF_KP") $(sha_of "$UNIT_KP") $(sha_of "$KC_KP") $(sha_of "$SB/usr/local/bin/kube-proxy")"
if ap "$PLAY_KP" /tmp/opencode/t009_kp_run2.log; then
  c="$(changed_of /tmp/opencode/t009_kp_run2.log)"
  check "B8 第二次运行 changed=0" test "${c:-x}" = "0"
else
  bad "B8 第二次运行失败（见 /tmp/opencode/t009_kp_run2.log）"
fi
check "B8 未通知任何 restart handler" \
  bash -c "! grep -q 'RUNNING HANDLER' /tmp/opencode/t009_kp_run2.log"
check "B8 kube-proxy PID 未变（未被重启）" test "${PID_KP:-x}" = "$PID_BEFORE"
check "B8 /proc starttime 未变" \
  bash -c "[[ \"\$(awk '{ sub(/^.*\\) /, \"\"); print \$20 }' '/proc/${PID_KP:-0}/stat' 2>/dev/null)\" == '$ST_BEFORE' ]]"
check "B8 config/unit/kubeconfig/二进制内容未变" \
  bash -c "[[ \"\$(sha256sum '$CONF_KP' '$UNIT_KP' '$KC_KP' '$SB/usr/local/bin/kube-proxy' | awk '{print \$1}' | tr '\\n' ' ')\" == '$(printf '%s ' $HASH_BEFORE)' ]]"
check "B8 幂等后 ClusterIP 仍可访问" wait_clusterip

echo "-- B9 fail-fast 矩阵（任何失败都不得改动已渲染 unit）"
UNIT_HASH_NOW="$(sha_of "$UNIT_KP")"
CONF_HASH_NOW="$(sha_of "$CONF_KP")"
run_ff() {  # run_ff <log> <extra-json>
  local log="$1" extra="$2"
  timeout 600 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_KP" \
    -e "{\"sandbox_root\":\"$SB\"}" -e "$extra" >"$log" 2>&1
}
unit_unchanged() { [[ "$(sha_of "$UNIT_KP")" == "$UNIT_HASH_NOW" && "$(sha_of "$CONF_KP")" == "$CONF_HASH_NOW" ]]; }
# ① proxy_mode 非法
rc=0
run_ff /tmp/opencode/t009_ff_mode.log '{"kube_proxy_proxy_mode":"userspace"}' || rc=$?
check "B9 proxy_mode 非法 → exit≠0" test "$rc" -ne 0
check "B9 proxy_mode 非法 → 错误提及 proxy_mode/iptables/ipvs" \
  grep -qiE 'proxy_mode|kube_proxy_proxy_mode' /tmp/opencode/t009_ff_mode.log
check "B9 proxy_mode 非法 → unit/config 未变" unit_unchanged
# ② cluster-cidr 缺失
rc=0
run_ff /tmp/opencode/t009_ff_cidr_missing.log '{"kube_proxy_cluster_cidr":""}' || rc=$?
check "B9 cluster-cidr 缺失 → exit≠0" test "$rc" -ne 0
check "B9 cluster-cidr 缺失 → 错误提及 cluster" \
  grep -qiE 'cluster.?cidr' /tmp/opencode/t009_ff_cidr_missing.log
check "B9 cluster-cidr 缺失 → unit/config 未变" unit_unchanged
# ③ cluster-cidr 非法
rc=0
run_ff /tmp/opencode/t009_ff_cidr_invalid.log '{"kube_proxy_cluster_cidr":"10.96.0.0"}' || rc=$?
check "B9 cluster-cidr 非法 → exit≠0" test "$rc" -ne 0
check "B9 cluster-cidr 非法 → 错误提及 CIDR 格式" \
  grep -qiE 'cidr' /tmp/opencode/t009_ff_cidr_invalid.log
check "B9 cluster-cidr 非法 → unit/config 未变" unit_unchanged
# ④ kubeconfig 缺失
rc=0
run_ff /tmp/opencode/t009_ff_kubeconfig.log "{\"kube_proxy_kubeconfig_source\":\"$SB/missing/admin.conf\"}" || rc=$?
check "B9 kubeconfig 缺失 → exit≠0" test "$rc" -ne 0
check "B9 kubeconfig 缺失 → 错误提及 kubeconfig/不存在" \
  grep -qiE 'kubeconfig|admin\.conf|不存在' /tmp/opencode/t009_ff_kubeconfig.log
check "B9 kubeconfig 缺失 → unit/config 未变" unit_unchanged
# ⑤ iptables 依赖缺失
rc=0
run_ff /tmp/opencode/t009_ff_iptables.log "{\"kube_proxy_iptables_binary\":\"$SB/missing/iptables\"}" || rc=$?
check "B9 iptables 依赖缺失 → exit≠0" test "$rc" -ne 0
check "B9 iptables 依赖缺失 → 错误提及 iptables" \
  grep -qi 'iptables' /tmp/opencode/t009_ff_iptables.log
check "B9 iptables 依赖缺失 → unit/config 未变" unit_unchanged
# ⑥ ipvs 但 ip_vs 未加载
if [[ -e /proc/net/ip_vs ]]; then
  bad "B9 前置不成立：本机已加载 ip_vs，无法验证「ipvs 但模块缺失」分支（契约 §5 需声明）"
else
  rc=0
  run_ff /tmp/opencode/t009_ff_ipvs.log '{"kube_proxy_proxy_mode":"ipvs"}' || rc=$?
  check "B9 ipvs 但 ip_vs 未加载 → exit≠0" test "$rc" -ne 0
  check "B9 ipvs 分支 → 错误提及 ip_vs/ipvs" \
    grep -qiE 'ip_vs|ipvs' /tmp/opencode/t009_ff_ipvs.log
  check "B9 ipvs 分支 → unit/config 未变" unit_unchanged
fi
# ⑦ 版本不匹配
rc=0
run_ff /tmp/opencode/t009_ff_version.log \
  "{\"kube_proxy_version\":\"1.30.0\",\"kube_proxy_artifact_path\":\"$SB/opt/k8s/artifacts/kube-proxy\",\"kube_proxy_download_url\":\"http://127.0.0.1:1/kube-proxy\",\"kube_proxy_sha256\":\"$KP_SHA\"}" || rc=$?
check "B9 版本不匹配 → exit≠0" test "$rc" -ne 0
check "B9 版本不匹配 → 错误给出实际版本" \
  bash -c "grep -q 'kube_proxy_version=1.30.0' /tmp/opencode/t009_ff_version.log && grep -q 'v$VERSION' /tmp/opencode/t009_ff_version.log"
check "B9 版本不匹配 → unit/config 未变" unit_unchanged
check "B9 全部 fail-fast 后 kube-proxy 仍存活" \
  bash -c "ps -o pid= -p '${PID_KP:-0}' >/dev/null 2>&1"
check "B9 全部 fail-fast 后 ClusterIP 仍可访问" wait_clusterip

echo "-- B10 清理与宿主零污染"
stop_proc "$SB/usr/local/bin/kube-proxy"
stop_mock
stop_proc "$SB/usr/local/bin/kube-apiserver"
stop_proc "$SB/usr/local/bin/etcd"
for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
WRAPPER=()
all_stopped() {
  local b
  for b in kube-proxy kube-apiserver etcd; do
    proc_alive "$SB/usr/local/bin/$b" && return 1
  done
  pgrep -f "http.server $PORT_MOCK" >/dev/null 2>&1 && return 1
  return 0
}
check "B10 kube-proxy/控制面/mock 进程已全部退出" all_stopped
check "B10 高位端口全部释放" wait_ports_free
check "B10 测试 Service 规则未泄漏到宿主（与本 netns 内规则无关）" \
  test "$PRE_HOST_SVC_RULES" = "$(host_ipt_raw | grep -c "$SVC_IP" || true)"

POST_HOST_IPT="$(host_ipt)"
POST_HOST_IPT_RAW="$(host_ipt_raw)"
POST_HOST_PORTS_FULL="$(host_ports)" || POST_HOST_PORTS_FULL="__CAPTURE_FAILED__"
if [[ "$POST_HOST_PORTS_FULL" == "__CAPTURE_FAILED__" ]]; then
  bad "B10 宿主监听端口快照（POST）采集失败（重试耗尽）"
  POST_HOST_PORTS="__CAPTURE_FAILED__"
else
  POST_HOST_PORTS="$(filter_task_ports "$POST_HOST_PORTS_FULL")"
fi
POST_HOST_UNIT="$(snapshot_path /etc/systemd/system/kube-proxy.service)"
POST_ETC_K8S="$(snapshot_path /etc/kubernetes)"
POST_VAR_LIB_KP="$(snapshot_path /var/lib/kube-proxy)"
POST_HOST_SVC_IP="$(nsenter -t 1 -n ip route show 2>/dev/null | grep -c '10.96.0.0/12')"
POST_HOST_SVC_RULES="$(host_ipt_raw | grep -c "$SVC_IP" || true)"
if [[ "$PRE_HOST_IPT" != "$POST_HOST_IPT" ]]; then
  diff -u <(printf '%s\n' "$PRE_HOST_IPT_RAW") <(printf '%s\n' "$POST_HOST_IPT_RAW") \
    >/tmp/opencode/t009_host_ipt.diff 2>&1 || true
fi
if [[ "$PRE_HOST_PORTS" != "$POST_HOST_PORTS" ]]; then
  {
    printf 'PRE  host task ports : %s\n' "$PRE_HOST_PORTS"
    printf 'POST host task ports : %s\n' "$POST_HOST_PORTS"
    printf '\n-- 全量宿主监听端口 PRE/POST diff（仅诊断，不参与断言）--\n'
    diff -u <(printf '%s\n' "${PRE_HOST_PORTS_FULL// /$'\n'}") \
            <(printf '%s\n' "${POST_HOST_PORTS_FULL// /$'\n'}") || true
  } >/tmp/opencode/t009_host_ports.diff 2>&1 || true
fi
check "B10 宿主 iptables/ip6tables 快照一致（零污染）" test "$PRE_HOST_IPT" = "$POST_HOST_IPT"
check "B10 宿主监听端口快照一致（仅本任务端口）" test "$PRE_HOST_PORTS" = "$POST_HOST_PORTS"
check "B10 宿主未新增 kube-proxy.service" test "$PRE_HOST_UNIT" = "$POST_HOST_UNIT"
check "B10 宿主 /etc/kubernetes 未被创建/改动" test "$PRE_ETC_K8S" = "$POST_ETC_K8S"
check "B10 宿主 /var/lib/kube-proxy 未被创建/改动" test "$PRE_VAR_LIB_KP" = "$POST_VAR_LIB_KP"
check "B10 宿主未新增 10.96.0.0/12 路由" test "$PRE_HOST_SVC_IP" = "$POST_HOST_SVC_IP"
check "B10 宿主 iptables 未出现测试 Service 规则" test "$PRE_HOST_SVC_RULES" = "$POST_HOST_SVC_RULES"

rm -rf "$SB"
check "B10 沙箱已清理" test ! -e "$SB"
SB=""

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
