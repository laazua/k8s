#!/usr/bin/env bash
# =============================================================================
# T008 运行时与节点组件 role 验收测试（TDD：先红后绿）
#   静态：结构 / 变量化 / 安全默认 / unit+config 模板 / 服务接线 / 语法 / 风格。
#   动态：沙箱内**真实** pki → **真实单成员 TLS etcd** → **真实 kube-apiserver**
#         → **真实 containerd** → **真实 kubelet**（高位端口、沙箱 root/state/config/
#         socket），进程均从 role 渲染出的 unit 的 ExecStart 拉起；验证 crictl info /
#         CRI 端点 / 节点注册 / cgroup 一致性 / 幂等 / fail-fast / 密闭性。
#   受限：不写宿主 /etc/systemd/system、不 systemctl、不占默认 6443/10250；trap 全量清理。
#   用法: tests/node/test_node_roles.sh
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
# 按 /proc/<pid>/exe 精确判断某二进制是否仍有存活进程。
# 不用 pgrep -f：调用方自身的 cmdline 含该路径会造成自匹配（假阳性）。
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
snapshot_ports() {
  ss -ltn 2>/dev/null | grep -E ':(16443|20250|20248|12379)[[:space:]]' \
    | awk '{print $4}' | sort | tr '\n' ' '
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
  # N5 教训：空 PYTHONPATH 时不得产生前导/尾随冒号（CWD 进入 sys.path）。
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

ROLE_CONTAINERD=roles/containerd
ROLE_KUBELET=roles/kubelet
INV=tests/node/inventory.ini
PLAY_STACK=tests/node/sandbox_stack.yml
PLAY_APISERVER=tests/node/sandbox_apiserver.yml
PLAY_CONTAINERD=tests/node/sandbox_containerd.yml
PLAY_KUBELET=tests/node/sandbox_kubelet.yml
PLAY_REAL=tests/node/real_node.yml
UNIT_EXEC=tests/etcd/unit_exec.py

VERSION=1.31.0
CONTAINERD_VERSION=2.0.0
RUNC_VERSION=1.2.1
CNI_VERSION=1.5.1
CRICTL_VERSION=1.31.1
CACHE="${T008_TEST_CACHE:-/tmp/opencode/k8s-cache}"
ETCD_TARBALL=etcd-v3.5.16-linux-amd64.tar.gz
ETCD_TARBALL_SHA=b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc
CONTAINERD_TARBALL="containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
CNI_TARBALL="cni-plugins-linux-amd64-v${CNI_VERSION}.tgz"
CRICTL_TARBALL="crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz"

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

# --- 缓存预取：必须在 re-exec 进 netns **之前**（M6 教训）----------------------
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
  for n in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet \
    "$CONTAINERD_TARBALL" runc.amd64 "$CNI_TARBALL" "$CRICTL_TARBALL"; do
    ensure_artifact "$n" "${ART_URL[$n]}" "${ART_SHA[$n]}" || return 1
  done
  ensure_etcd_tarball
}

# 密闭性模式：suite = 已在独立 netns（仅 lo）内；none = 未隔离。
NETNS_MODE="none"
if [[ "${T008_IN_NETNS:-0}" == "1" ]]; then
  NETNS_MODE="suite"
else
  # 冷缓存自举：先在宿主网络预取（M6），再进入 netns；netns 内只做 sha 校验。
  if ! prefill_cache; then
    printf '  \033[31mFAIL\033[0m 无法预取官方制品（首次运行需要外网；见上方 curl 错误）\n'
    echo "== 汇总: PASS=$pass_count FAIL=$((fail + 1)) =="
    exit 1
  fi
  if sudo -n true 2>/dev/null &&
    sudo -n unshare -n bash -c 'ip link set lo up >/dev/null 2>&1; ! ip route show default | grep -q .' >/dev/null 2>&1; then
    exec sudo -n env T008_IN_NETNS=1 \
      PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}${USER_SITE:-}" \
      ANSIBLE_PLAYBOOK="$ANSIBLE_PLAYBOOK" \
      T008_TEST_CACHE="$CACHE" \
      ETCD_TEST_CACHE="${ETCD_TEST_CACHE:-}" \
      YAMLLINT="$YAMLLINT" \
      unshare -n bash -c 'ip link set lo up; exec "$@"' _ bash "$(readlink -f "$0")"
  fi
fi

echo "== T008 运行时与节点组件 role 验收 =="

echo "-- A1 role / 测试资产结构"
for f in defaults/main.yml tasks/main.yml tasks/facts.yml tasks/validate.yml \
  tasks/binary.yml tasks/config.yml tasks/service.yml handlers/main.yml \
  meta/main.yml README.md; do
  check "存在 $ROLE_CONTAINERD/$f" test -f "$ROLE_CONTAINERD/$f"
  check "存在 $ROLE_KUBELET/$f" test -f "$ROLE_KUBELET/$f"
done
for f in tasks/runc.yml tasks/cni.yml tasks/crictl.yml tasks/verify.yml; do
  check "存在 $ROLE_CONTAINERD/$f" test -f "$ROLE_CONTAINERD/$f"
done
for f in tasks/kubeconfig_file.yml tasks/verify.yml; do
  check "存在 $ROLE_KUBELET/$f" test -f "$ROLE_KUBELET/$f"
done
# B1 类缺陷防线（T007 r1 教训）：role 内的任何文件都不得被 .gitignore 忽略，
# 否则干净检出（git archive）会缺文件、role 直接失败。`kubeconfig.*` 规则曾吞掉
# roles/kubelet/tasks/kubeconfig.yml（本轮实测命中），故改名为 kubeconfig_file.yml。
check_not "两 role 无被 .gitignore 忽略的文件（防 kubeconfig.* 吞掉任务文件）" \
  bash -c 'find "$1" "$2" -type f | git check-ignore --stdin >/dev/null 2>&1' _ "$ROLE_CONTAINERD" "$ROLE_KUBELET"
check "存在 containerd config.toml 模板" test -f "$ROLE_CONTAINERD/templates/config.toml.j2"
check "存在 containerd.service 模板" test -f "$ROLE_CONTAINERD/templates/containerd.service.j2"
check "存在 kubelet config 模板" test -f "$ROLE_KUBELET/templates/kubelet-config.yaml.j2"
check "存在 kubelet.service 模板" test -f "$ROLE_KUBELET/templates/kubelet.service.j2"
check "存在 kubelet.conf 模板" test -f "$ROLE_KUBELET/templates/kubelet.conf.j2"
for f in "$INV" "$PLAY_STACK" "$PLAY_APISERVER" "$PLAY_CONTAINERD" "$PLAY_KUBELET" "$PLAY_REAL" "$UNIT_EXEC"; do
  check "存在 $f" test -f "$f"
done
check "存在 tests/node/README.md" test -f tests/node/README.md

if [[ ! -d "$ROLE_CONTAINERD" || ! -d "$ROLE_KUBELET" ]]; then
  bad "role 目录缺失：A2–A10 与全部动态用例无法判定（红阶段）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi

echo "-- A2 变量化 / 无硬编码"
for d in "$ROLE_CONTAINERD/defaults/main.yml" "$ROLE_KUBELET/defaults/main.yml"; do
  check "$d 复用 k8s_artifact_dir" grep -q 'k8s_artifact_dir' "$d"
  check "$d 复用 k8s_bin_dir" grep -q 'k8s_bin_dir' "$d"
  check "$d 复用 kube_systemd_dir" grep -q 'kube_systemd_dir' "$d"
done
for d in "$ROLE_KUBELET/defaults/main.yml"; do
  check "$d 复用 k8s_version" grep -q 'k8s_version' "$d"
  check "$d 复用 k8s_config_dir" grep -q 'k8s_config_dir' "$d"
done
check "containerd defaults 版本/sha256 固定" \
  bash -c "grep -q 'containerd_version' '$ROLE_CONTAINERD/defaults/main.yml' && grep -q 'containerd_known_sha256' '$ROLE_CONTAINERD/defaults/main.yml'"
check "containerd defaults runc/CNI 版本可配" \
  bash -c "grep -q 'runc_version' '$ROLE_CONTAINERD/defaults/main.yml' && grep -q 'cni_plugins_version' '$ROLE_CONTAINERD/defaults/main.yml'"
check "containerd defaults cgroup driver 可配" \
  grep -q 'containerd_cgroup_driver' "$ROLE_CONTAINERD/defaults/main.yml"
check "kubelet defaults 版本/sha256 固定" \
  bash -c "grep -q 'kubelet_version' '$ROLE_KUBELET/defaults/main.yml' && grep -q 'kubelet_known_sha256' '$ROLE_KUBELET/defaults/main.yml'"
check "kubelet defaults cgroup driver 可配" \
  grep -q 'kubelet_cgroup_driver' "$ROLE_KUBELET/defaults/main.yml"
check "kubelet defaults runtime endpoint 可配" \
  grep -q 'kubelet_container_runtime_endpoint' "$ROLE_KUBELET/defaults/main.yml"
check "kubelet defaults 证书路径可配" \
  bash -c "grep -q 'kubelet_client_cert_file' '$ROLE_KUBELET/defaults/main.yml' && grep -q 'kubelet_client_key_file' '$ROLE_KUBELET/defaults/main.yml'"
check_not "containerd tasks 无硬编码 IPv4" \
  grep -rqE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$ROLE_CONTAINERD/tasks"
check_not "kubelet tasks 无硬编码 IPv4" \
  grep -rqE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$ROLE_KUBELET/tasks"
check_not "containerd tasks 无硬编码 6443/10250/10248/2379" \
  grep -rqE '(^|[^0-9])(6443|10250|10248|2379)([^0-9]|$)' "$ROLE_CONTAINERD/tasks"
check_not "kubelet tasks 无硬编码 6443/10250/10248/2379" \
  grep -rqE '(^|[^0-9])(6443|10250|10248|2379)([^0-9]|$)' "$ROLE_KUBELET/tasks"
check_not "containerd tasks 无硬编码 /etc/systemd/system" \
  grep -rq '/etc/systemd/system' "$ROLE_CONTAINERD/tasks"
check_not "kubelet tasks 无硬编码 /etc/systemd/system" \
  grep -rq '/etc/systemd/system' "$ROLE_KUBELET/tasks"
check_not "containerd tasks 无硬编码 /etc/containerd" \
  grep -rq '/etc/containerd' "$ROLE_CONTAINERD/tasks"
check_not "containerd tasks 无硬编码 /run/containerd" \
  grep -rq '/run/containerd' "$ROLE_CONTAINERD/tasks"
check_not "kubelet tasks 无硬编码 /var/lib/kubelet" \
  grep -rq '/var/lib/kubelet' "$ROLE_KUBELET/tasks"
check_not "两 role tasks 无硬编码下载 URL" \
  grep -rqE 'https?://' "$ROLE_CONTAINERD/tasks" "$ROLE_KUBELET/tasks"
check "两 role 使用 FQCN ansible.builtin" \
  bash -c "grep -rq 'ansible\.builtin\.' '$ROLE_CONTAINERD/tasks' && grep -rq 'ansible\.builtin\.' '$ROLE_KUBELET/tasks'"
check "两 role 二进制经 download role（不直连）" \
  bash -c "grep -rq 'name: download' '$ROLE_CONTAINERD/tasks' && grep -rq 'name: download' '$ROLE_KUBELET/tasks'"

echo "-- A3 containerd unit 模板"
T_CD_UNIT="$ROLE_CONTAINERD/templates/containerd.service.j2"
check "A3 ExecStart 使用变量二进制 + 参数列表" \
  grep -q 'ExecStart={{ containerd_binary }} {{ containerd_exec_args | join' "$T_CD_UNIT"
check "A3 Restart=always" grep -q '^Restart=always' "$T_CD_UNIT"
check "A3 RestartSec" grep -q '^RestartSec=' "$T_CD_UNIT"
check "A3 LimitNOFILE" grep -q '^LimitNOFILE=' "$T_CD_UNIT"
check "A3 Delegate=yes" grep -q '^Delegate=yes' "$T_CD_UNIT"
check "A3 KillMode=mixed" grep -q '^KillMode=mixed' "$T_CD_UNIT"
check "A3 OOMScoreAdjust" grep -q '^OOMScoreAdjust=' "$T_CD_UNIT"
check "A3 After=network-online.target" grep -q '^After=network-online.target' "$T_CD_UNIT"
check "A3 WantedBy=multi-user.target" grep -q '^WantedBy=multi-user.target' "$T_CD_UNIT"
check_not "A3 unit 无硬编码默认端口/路径" \
  grep -qE '10250|/run/containerd/containerd.sock' "$T_CD_UNIT"

echo "-- A4 containerd config 模板"
T_CD_CONF="$ROLE_CONTAINERD/templates/config.toml.j2"
# 注：模板必须同时满足 TOML 语法（字符串带引号）与变量化（A2 禁止字面量），
# 因此断言检查「变量 + TOML 引号」；渲染结果由 B3 对真实 config.toml 断言。
check "A4 version 可配（2.x 渲染为 3）" grep -q 'version = {{ containerd_config_version }}' "$T_CD_CONF"
check "A4 SystemdCgroup 可配" grep -q 'SystemdCgroup = {{ containerd_systemd_cgroup }}' "$T_CD_CONF"
check "A4 root 可配" grep -q "root = '{{ containerd_root_dir }}'" "$T_CD_CONF"
check "A4 state 可配" grep -q "state = '{{ containerd_state_dir }}'" "$T_CD_CONF"
check "A4 socket 可配" grep -q "address = '{{ containerd_socket }}'" "$T_CD_CONF"
check "A4 CNI bin_dir 可配" grep -q "bin_dir = '{{ containerd_cni_bin_dir }}'" "$T_CD_CONF"
check "A4 CNI conf_dir 可配" grep -q "conf_dir = '{{ containerd_cni_conf_dir }}'" "$T_CD_CONF"
check "A4 sandbox image 可配" grep -q "sandbox_image = '{{ containerd_sandbox_image }}'" "$T_CD_CONF"
check_not "A4 模板无硬编码默认 socket" \
  grep -q '/run/containerd/containerd.sock' "$T_CD_CONF"

echo "-- A5 kubelet unit / config / facts"
T_KL_UNIT="$ROLE_KUBELET/templates/kubelet.service.j2"
T_KL_CONF="$ROLE_KUBELET/templates/kubelet-config.yaml.j2"
check "A5 ExecStart 使用变量二进制 + 参数列表" \
  grep -q 'ExecStart={{ kubelet_binary }} {{ kubelet_args | join' "$T_KL_UNIT"
check "A5 Restart=always" grep -q '^Restart=always' "$T_KL_UNIT"
check "A5 LimitNOFILE" grep -q '^LimitNOFILE=' "$T_KL_UNIT"
check "A5 After=network-online.target" grep -q '^After=network-online.target' "$T_KL_UNIT"
check "A5 WantedBy=multi-user.target" grep -q '^WantedBy=multi-user.target' "$T_KL_UNIT"
check "A5 config cgroupDriver 可配" grep -q 'cgroupDriver: {{ kubelet_cgroup_driver }}' "$T_KL_CONF"
check "A5 config anonymous 可配（默认 false）" grep -q 'enabled: {{ kubelet_anonymous_auth }}' "$T_KL_CONF"
check "A5 config authorization 可配" grep -q 'mode: {{ kubelet_authorization_mode }}' "$T_KL_CONF"
check "A5 config runtime endpoint 可配" grep -q 'containerRuntimeEndpoint: {{ kubelet_container_runtime_endpoint }}' "$T_KL_CONF"
check "A5 config failSwapOn 可配" grep -q 'failSwapOn: {{ kubelet_fail_swap_on }}' "$T_KL_CONF"
check "A5 config clientCAFile" grep -q 'clientCAFile:' "$T_KL_CONF"
check "A5 config serving 证书可配" \
  bash -c "grep -q 'tlsCertFile:' '$T_KL_CONF' && grep -q 'tlsPrivateKeyFile:' '$T_KL_CONF'"
check "A5 facts 渲染 --config" grep -q -- '--config=' "$ROLE_KUBELET/tasks/facts.yml"
check "A5 facts 渲染 --kubeconfig" grep -q -- '--kubeconfig=' "$ROLE_KUBELET/tasks/facts.yml"
check "A5 facts 渲染 --container-runtime-endpoint" \
  grep -q -- '--container-runtime-endpoint=' "$ROLE_KUBELET/tasks/facts.yml"
check "A5 facts 渲染 --cgroup-driver" grep -q -- '--cgroup-driver=' "$ROLE_KUBELET/tasks/facts.yml"
check "A5 facts 渲染 --root-dir/--cert-dir" \
  bash -c "grep -q -- '--root-dir=' '$ROLE_KUBELET/tasks/facts.yml' && grep -q -- '--cert-dir=' '$ROLE_KUBELET/tasks/facts.yml'"
check "A5 facts 渲染 --hostname-override" \
  grep -q -- '--hostname-override=' "$ROLE_KUBELET/tasks/facts.yml"
check_not "A5 无 --anonymous-auth=true" \
  grep -rq -- '--anonymous-auth=true' "$ROLE_KUBELET"

echo "-- A6 systemd 服务接线"
for pair in "$ROLE_CONTAINERD:containerd" "$ROLE_KUBELET:kubelet"; do
  r="${pair%%:*}"; v="${pair##*:}"
  check "A6 $r service.yml 使用 ansible.builtin.systemd" \
    grep -q 'ansible.builtin.systemd' "$r/tasks/service.yml"
  check "A6 $r service.yml 设置 enabled" grep -q 'enabled:' "$r/tasks/service.yml"
  check "A6 $r service.yml daemon_reload" grep -q 'daemon_reload: true' "$r/tasks/service.yml"
  check "A6 $r defaults manage_service=true" \
    grep -qE "^${v}_manage_service:[[:space:]]*true" "$r/defaults/main.yml"
  check "A6 $r defaults enabled=true" \
    grep -qE "^${v}_service_enabled:[[:space:]]*true" "$r/defaults/main.yml"
  check "A6 $r defaults state=started" \
    grep -qE "^${v}_service_state:[[:space:]]*started" "$r/defaults/main.yml"
  check "A6 $r handler 使用 restarted" grep -q 'state: restarted' "$r/handlers/main.yml"
done

echo "-- A7 安全默认 / 证书"
check "A7 kubelet anonymous_auth 默认 false" \
  grep -qE '^kubelet_anonymous_auth:[[:space:]]*false' "$ROLE_KUBELET/defaults/main.yml"
check "A7 kubelet authorization_mode 默认 Webhook" \
  grep -qE '^kubelet_authorization_mode:[[:space:]]*"Webhook"' "$ROLE_KUBELET/defaults/main.yml"
check "A7 kubelet kubeconfig 0600" \
  grep -qE '^kubelet_kubeconfig_mode:[[:space:]]*"0600"' "$ROLE_KUBELET/defaults/main.yml"
check "A7 kubelet 校验证书身份 system:node:" \
  grep -q 'system:node:' "$ROLE_KUBELET/tasks/validate.yml"
check "A7 kubelet 校验证书组织 system:nodes" \
  grep -q 'system:nodes' "$ROLE_KUBELET/tasks/validate.yml"
check "A7 kubelet kubeconfig 内嵌证书/私钥" \
  bash -c "grep -q 'client-certificate-data' '$ROLE_KUBELET/templates/kubelet.conf.j2' && grep -q 'client-key-data' '$ROLE_KUBELET/templates/kubelet.conf.j2'"
check "A7 containerd cgroup driver 默认 systemd" \
  grep -qE '^containerd_cgroup_driver:.*systemd' "$ROLE_CONTAINERD/defaults/main.yml"
check "A7 kubelet cgroup driver 默认 systemd" \
  grep -qE '^kubelet_cgroup_driver:.*systemd' "$ROLE_KUBELET/defaults/main.yml"

echo "-- A8 范围约束（不接入 site.yml；不改已验收资产）"
check_not "playbooks/site.yml 未引用 containerd/kubelet" \
  grep -qE 'containerd|kubelet' playbooks/site.yml
if git rev-parse --git-dir >/dev/null 2>&1; then
  frozen="tests/skeleton tests/base tests/download tests/pki tests/etcd tests/ha roles/base roles/download roles/pki roles/etcd roles/haproxy roles/keepalived roles/kube-apiserver roles/kube-controller-manager roles/kube-scheduler"
  dirty="$(git status --porcelain -- $frozen | wc -l)"
  check "已 PASS 的 roles/tests 未被改动" test "$dirty" -eq 0
  check_not "工作区无未忽略的密钥/证书/kubeconfig" \
    bash -c "git status --porcelain | grep -qE '\.(key|crt|pem|conf)$'"
fi

echo "-- A9 语法与风格"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_STACK" >/tmp/opencode/t008_syntax_stack.log 2>&1 &&
    "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_APISERVER" >/tmp/opencode/t008_syntax_apiserver.log 2>&1 &&
    "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_CONTAINERD" >/tmp/opencode/t008_syntax_containerd.log 2>&1 &&
    "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_KUBELET" >/tmp/opencode/t008_syntax_kubelet.log 2>&1 &&
    "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_REAL" >/tmp/opencode/t008_syntax_real.log 2>&1; then
    ok "全部 tests/node playbook --syntax-check 通过"
  else
    bad "tests/node playbook --syntax-check 失败（见 /tmp/opencode/t008_syntax_*.log）"
  fi
else
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi
if [[ -x "$YAMLLINT" ]] || command -v "$YAMLLINT" >/dev/null 2>&1; then
  if PYTHONPATH="${USER_SITE:+$USER_SITE}${PYTHONPATH:+:$PYTHONPATH}" "$YAMLLINT" -c .yamllint \
    "$ROLE_CONTAINERD" "$ROLE_KUBELET" tests/node >/tmp/opencode/t008_yamllint.log 2>&1; then
    ok "yamllint（roles/containerd, roles/kubelet, tests/node）无 error"
  else
    bad "yamllint 失败（见 /tmp/opencode/t008_yamllint.log）"
  fi
else
  bad "找不到 yamllint"
fi

echo "-- A10 文档"
for r in "$ROLE_CONTAINERD" "$ROLE_KUBELET"; do
  check "A10 $r README 说明变量与验证方式" \
    bash -c "grep -qi '变量' '$r/README.md' && grep -qi '验证' '$r/README.md'"
  check "A10 $r README 声明 systemd 受限验证" \
    grep -qi 'systemd' "$r/README.md"
done
check "A10 tests/node/README 说明缓存/密闭/受限" \
  bash -c "grep -qi '缓存' tests/node/README.md && grep -qi 'netns' tests/node/README.md"

# ---------------------------------------------------------------------------
if ! have_ansible; then
  bad "找不到 ansible-playbook（跳过全部动态用例）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi
if [[ ! -d "$ROLE_CONTAINERD" || ! -d "$ROLE_KUBELET" ]]; then
  bad "运行时 role 不存在：动态用例无法执行（红阶段）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi
if ! sudo -n true 2>/dev/null; then
  bad "需要免密 sudo：以 root 应用属主模型并从 unit 拉起真实运行时进程"
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
EMPTY_CACHE="$(mktemp -d /tmp/opencode/t008empty.XXXXXX)"
OFF_SB="$(mktemp -d /tmp/opencode/t008off.XXXXXX)"
chmod 0755 "$EMPTY_CACHE" "$OFF_SB"
mkdir -p "$OFF_SB/opt/k8s/artifacts"
for n in "$CONTAINERD_TARBALL" runc.amd64 "$CNI_TARBALL" "$CRICTL_TARBALL"; do
  cp "$CACHE/$n" "$OFF_SB/opt/k8s/artifacts/$n"
done
chmod 0644 "$OFF_SB"/opt/k8s/artifacts/*
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_CONTAINERD" \
  -e "{\"sandbox_root\":\"$OFF_SB\",\"containerd_artifact_dir\":\"$EMPTY_CACHE\",\"containerd_artifact_path\":\"$EMPTY_CACHE/$CONTAINERD_TARBALL\",\"containerd_download_url\":\"http://127.0.0.1:1/$CONTAINERD_TARBALL\",\"containerd_sha256\":\"${ART_SHA[$CONTAINERD_TARBALL]}\",\"containerd_install_crictl\":false}" \
  >/tmp/opencode/t008_b0_empty.log 2>&1 || rc=$?
check "B0 空缓存 + 断网 → containerd role exit≠0" test "$rc" -ne 0
check "B0 空缓存 + 断网 → 错误可定位（download/URL/不可达）" \
  grep -qiE 'download|Failed to|unreachable|Connection refused|Could not resolve|sha256' /tmp/opencode/t008_b0_empty.log

# 缓存命中 + 不可达 URL → 必须成功（证明走 roles/download 缓存）
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_CONTAINERD" \
  -e "{\"sandbox_root\":\"$OFF_SB\",\"containerd_artifact_dir\":\"$OFF_SB/opt/k8s/artifacts\",\"containerd_artifact_path\":\"$OFF_SB/opt/k8s/artifacts/$CONTAINERD_TARBALL\",\"containerd_download_url\":\"http://127.0.0.1:1/$CONTAINERD_TARBALL\",\"containerd_sha256\":\"${ART_SHA[$CONTAINERD_TARBALL]}\",\"runc_download_url\":\"http://127.0.0.1:1/runc.amd64\",\"runc_sha256\":\"${ART_SHA[runc.amd64]}\",\"cni_plugins_download_url\":\"http://127.0.0.1:1/$CNI_TARBALL\",\"cni_plugins_sha256\":\"${ART_SHA[$CNI_TARBALL]}\",\"crictl_download_url\":\"http://127.0.0.1:1/$CRICTL_TARBALL\",\"crictl_sha256\":\"${ART_SHA[$CRICTL_TARBALL]}\"}" \
  >/tmp/opencode/t008_b0_offline.log 2>&1 || rc=$?
check "B0 缓存命中 + 不可达 URL → containerd role exit 0" test "$rc" -eq 0
check "B0 缓存命中 → containerd 二进制存在且可执行" test -x "$OFF_SB/usr/local/bin/containerd"
check "B0 缓存命中 → 未发起外网请求（日志无 download 失败）" \
  bash -c "! grep -qiE 'Could not resolve|Connection refused|Failed to download' /tmp/opencode/t008_b0_offline.log"
sudo -n rm -rf "$EMPTY_CACHE" "$OFF_SB"

# 宿主零污染快照
PRE_HOST_UNITS="$(ls /etc/systemd/system/containerd.service /etc/systemd/system/kubelet.service 2>/dev/null | sort | tr '\n' ' ')"
PRE_ETC_CONTAINERD="$(snapshot_path /etc/containerd)"
PRE_ETC_K8S="$(snapshot_path /etc/kubernetes)"
PRE_VAR_LIB_CONTAINERD="$(sudo -n stat -c '%F %a' /var/lib/containerd 2>/dev/null || echo __MISSING__)"
PRE_RUN_CONTAINERD="$(sudo -n stat -c '%F %a' /run/containerd 2>/dev/null || echo __MISSING__)"
PRE_OPT_CNI="$(snapshot_path /opt/cni/bin)"
PRE_PORTS="$(snapshot_ports)"
# kubelet 启动会写全局 sysctl kernel.panic / kernel.panic_on_oops（非命名空间隔离）；
# 快照并在 trap/B8 恢复，保证宿主零残留（契约 §5 已声明）。
PRE_KERNEL_PANIC="$(cat /proc/sys/kernel/panic 2>/dev/null || echo __MISSING__)"
PRE_KERNEL_PANIC_ON_OOPS="$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null || echo __MISSING__)"
# kubelet（systemd cgroup driver）会通过 systemd 创建 kubepods*.slice（宿主级）；
# 快照并在 trap/B8 清理本次创建的 slice，保证宿主零残留（契约 §5 已声明）。
PRE_KUBEPODS_SLICES="$(systemctl list-units --all 'kubepods*' --no-legend 2>/dev/null \
  | awk '{print $1}' | sort | tr '\n' ' ')"
restore_kernel_tunables() {
  [[ "$PRE_KERNEL_PANIC" == "__MISSING__" ]] || \
    sudo -n sysctl -q -w "kernel.panic=$PRE_KERNEL_PANIC" >/dev/null 2>&1 || true
  [[ "$PRE_KERNEL_PANIC_ON_OOPS" == "__MISSING__" ]] || \
    sudo -n sysctl -q -w "kernel.panic_on_oops=$PRE_KERNEL_PANIC_ON_OOPS" >/dev/null 2>&1 || true
}
cleanup_kubepods_slices() {
  [[ -n "$PRE_KUBEPODS_SLICES" ]] && return 0
  sudo -n systemctl stop kubepods.slice >/dev/null 2>&1 || true
}

SB=""
declare -A PID=()
declare -A WRAPPER=()
KUBECTL=""

stop_proc() {
  local pat="$1" i
  # 先优雅终止（containerd 需在 SIGTERM 时 unlink socket；SIGKILL 会留下 socket 文件）
  sudo -n pkill -TERM -f -- "$pat" 2>/dev/null || true
  for ((i = 0; i < 80; i++)); do
    pgrep -f -- "$pat" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  sudo -n pkill -9 -f -- "$pat" 2>/dev/null || true
  for ((i = 0; i < 40; i++)); do
    pgrep -f -- "$pat" >/dev/null 2>&1 || return 0
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
  stop_proc "$SB/usr/local/bin/kube-apiserver"
  stop_proc "$SB/usr/local/bin/etcd"
  cleanup_kubepods_slices
  sudo -n rm -rf "$SB" 2>/dev/null || true
}
trap cleanup EXIT

port_free() { ! ss -ltn 2>/dev/null | grep -qE ':(16443|20250|20248|12379)[[:space:]]'; }
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

SB="$(mktemp -d /tmp/opencode/t008.XXXXXX)"
chmod 0755 "$SB"
mkdir -p "$SB/opt/k8s/artifacts" "$SB/logs" "$SB/client" "$SB/etc" "$SB/var"
chmod 0755 "$SB/etc" "$SB/var"
for n in "${!ART_SHA[@]}"; do
  cp "$CACHE/$n" "$SB/opt/k8s/artifacts/$n"
done
sudo -n chown -R root:root "$SB/opt/k8s/artifacts"
sudo -n chmod 0644 "$SB"/opt/k8s/artifacts/*
ok "沙箱制品已就绪（$SB）"

ap() {  # ap <playbook> <log> [额外的 -e ...]
  local play="$1" log="$2"
  shift 2
  timeout 900 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" -e "{\"sandbox_root\":\"$SB\"}" "$@" >"$log" 2>&1
}

echo "-- B1 pki + 单成员 TLS etcd 沙箱"
if ap "$PLAY_STACK" /tmp/opencode/t008_stack.log; then
  ok "stack playbook exit 0（kubectl + pki（含 [k8s_node] kubelet 证书）+ etcd 渲染）"
else
  bad "stack playbook 失败（见 /tmp/opencode/t008_stack.log）"
fi
check "B1 pki 产出 kubelet 客户端证书 node1.crt" test -f "$SB/etc/kubernetes/pki/kubelet/node1.crt"
check "B1 pki 产出 kubelet 客户端私钥 node1.key" test -f "$SB/etc/kubernetes/pki/kubelet/node1.key"
check "B1 pki 产出 kubernetes-ca" test -f "$SB/etc/kubernetes/pki/ca.crt"
check "B1 etcd unit 已渲染" test -f "$(unit_path etcd-etcd1)"
check "B1 kubectl 已安装到沙箱" test -x "$SB/usr/local/bin/kubectl"

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
wait_etcd() {
  local i
  for ((i = 0; i < 120; i++)); do etcd_healthy && return 0; sleep 0.5; done
  return 1
}
check "B1 单成员 etcd healthy（真实 TLS）" wait_etcd

echo "-- B2 真实 kube-apiserver（节点注册所需最小控制面）"
if ap "$PLAY_APISERVER" /tmp/opencode/t008_apiserver.log; then
  ok "apiserver playbook exit 0（沙箱渲染）"
else
  bad "apiserver playbook 失败（见 /tmp/opencode/t008_apiserver.log）"
fi
UNIT_API="$(unit_path kube-apiserver)"
check "B2 apiserver unit 已渲染" test -f "$UNIT_API"
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
check "B2 kubectl get --raw /healthz = ok" wait_healthz

echo "-- B3 真实 containerd（role 渲染 → unit ExecStart 拉起）"
if ap "$PLAY_CONTAINERD" /tmp/opencode/t008_containerd_run1.log; then
  ok "containerd playbook 首跑 exit 0"
else
  bad "containerd playbook 首跑失败（见 /tmp/opencode/t008_containerd_run1.log）"
fi
C1="$(changed_of /tmp/opencode/t008_containerd_run1.log)"
check "B3 首跑 changed>0（真实安装/渲染）" test "${C1:-0}" -gt 0
for b in containerd containerd-shim-runc-v2 ctr runc crictl; do
  check "B3 二进制 $b 已安装且可执行" test -x "$SB/usr/local/bin/$b"
done
for p in bridge host-local loopback portmap tuning; do
  check "B3 CNI plugin $p 已安装且可执行" test -x "$SB/opt/cni/bin/$p"
done
check "B3 containerd 版本 = v$CONTAINERD_VERSION" \
  bash -c "'$SB/usr/local/bin/containerd' --version | grep -q 'v$CONTAINERD_VERSION'"
check "B3 runc 版本 = $RUNC_VERSION" \
  bash -c "'$SB/usr/local/bin/runc' --version | head -1 | grep -q '$RUNC_VERSION'"
check "B3 crictl 版本 = v$CRICTL_VERSION" \
  bash -c "'$SB/usr/local/bin/crictl' --version | grep -q 'v$CRICTL_VERSION'"

UNIT_CD="$(unit_path containerd)"
CONF_CD="$SB/etc/containerd/config.toml"
SOCK="$SB/run/containerd/containerd.sock"
check "B3 containerd unit 已渲染" test -f "$UNIT_CD"
check "B3 containerd config 已渲染" test -f "$CONF_CD"
check "B3 config version = 3" grep -q '^version = 3' "$CONF_CD"
check "B3 config SystemdCgroup = true" grep -q 'SystemdCgroup = true' "$CONF_CD"
check "B3 config root 指向沙箱" grep -q "root = '$SB/var/lib/containerd'" "$CONF_CD"
check "B3 config state 指向沙箱" grep -q "state = '$SB/run/containerd'" "$CONF_CD"
check "B3 config socket 指向沙箱" grep -q "address = '$SOCK'" "$CONF_CD"
check "B3 config CNI bin_dir 指向沙箱" grep -q "bin_dir = '$SB/opt/cni/bin'" "$CONF_CD"
check "B3 config CNI conf_dir 指向沙箱" grep -q "conf_dir = '$SB/etc/cni/net.d'" "$CONF_CD"
check "B3 unit ExecStart 使用沙箱二进制 + config" \
  grep -q "^ExecStart=$SB/usr/local/bin/containerd .*--config.*$CONF_CD" "$UNIT_CD"
check "B3 unit Restart=always" grep -q '^Restart=always' "$UNIT_CD"
check "B3 unit LimitNOFILE=1048576" grep -q '^LimitNOFILE=1048576' "$UNIT_CD"
check "B3 unit Delegate=yes" grep -q '^Delegate=yes' "$UNIT_CD"
check "B3 unit KillMode=mixed" grep -q '^KillMode=mixed' "$UNIT_CD"
check "B3 unit After=network-online.target" grep -q '^After=network-online.target' "$UNIT_CD"
check "B3 unit WantedBy=multi-user.target" grep -q '^WantedBy=multi-user.target' "$UNIT_CD"

mapfile -t CD_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_CD")
if [[ ${#CD_ARGS[@]} -gt 0 ]]; then
  ( sudo -n "${CD_ARGS[@]}" </dev/null >>"$SB/logs/containerd.log" 2>&1 ) &
  WRAPPER[containerd]=$!
  for _ in $(seq 1 120); do PID[containerd]="$(proc_pid containerd)"; [[ -n "${PID[containerd]}" ]] && break; sleep 0.1; done
  ok "已从 unit 拉起真实 containerd（PID ${PID[containerd]:-?}）"
else
  bad "无法解析 containerd unit 的 ExecStart"
fi
wait_socket() {
  local i
  for ((i = 0; i < 120; i++)); do [[ -S "$SOCK" ]] && return 0; sleep 0.25; done
  return 1
}
check "B3 containerd CRI socket 已创建（unix socket）" wait_socket
check "B3 containerd 进程存活" test -n "${PID[containerd]:-}"
CRICTL="$SB/usr/local/bin/crictl"
crictl_info() { sudo -n "$CRICTL" --runtime-endpoint "unix://$SOCK" info; }
crictl_version() { sudo -n "$CRICTL" --runtime-endpoint "unix://$SOCK" version; }
if crictl_info >"$SB/client/crictl-info.json" 2>"$SB/client/crictl-info.err"; then
  ok "B3 crictl info exit 0（CRI 端点连通）"
else
  bad "B3 crictl info 失败（见 $SB/client/crictl-info.err）"
fi
check "B3 crictl info status.RuntimeReady=true" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=[x for x in d["status"]["conditions"] if x.get("type")=="RuntimeReady"]; sys.exit(0 if c and c[0].get("status") is True else 1)' "$SB/client/crictl-info.json"
check "B3 crictl info runtimeHandlers 含 runc" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(h.get("name")=="runc" for h in d.get("runtimeHandlers",[])) else 1)' "$SB/client/crictl-info.json"
# 注：containerd 2.x 的 `crictl info` 不再返回顶层 runtimeName/runtimeVersion；
# 运行时名称/版本由 B3 的 `crictl version` 断言（RuntimeName/RuntimeVersion）。
check "B3 crictl info SystemdCgroup=true" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); o=d["config"]["containerd"]["runtimes"]["runc"]["options"]; sys.exit(0 if o.get("SystemdCgroup") is True else 1)' "$SB/client/crictl-info.json"
check "B3 crictl info containerdEndpoint 指向沙箱" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["config"].get("containerdEndpoint")==sys.argv[2] else 1)' "$SB/client/crictl-info.json" "$SOCK"
check "B3 CRI socket 可 dial（AF_UNIX 连接成功）" \
  sudo -n python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1]); s.close()' "$SOCK"
if crictl_version >"$SB/client/crictl-version.txt" 2>&1; then
  ok "B3 crictl version exit 0"
else
  bad "B3 crictl version 失败"
fi
check "B3 crictl version RuntimeName=containerd" \
  grep -q 'RuntimeName:  containerd' "$SB/client/crictl-version.txt"
check "B3 crictl version RuntimeVersion=v$CONTAINERD_VERSION（与 containerd --version 一致）" \
  grep -q "RuntimeVersion:  v$CONTAINERD_VERSION" "$SB/client/crictl-version.txt"

echo "-- B4 真实 kubelet（role 渲染 → unit ExecStart 拉起 → 节点注册）"
if ap "$PLAY_KUBELET" /tmp/opencode/t008_kubelet_run1.log; then
  ok "kubelet playbook 首跑 exit 0"
else
  bad "kubelet playbook 首跑失败（见 /tmp/opencode/t008_kubelet_run1.log）"
fi
K1="$(changed_of /tmp/opencode/t008_kubelet_run1.log)"
check "B4 首跑 changed>0（真实安装/渲染）" test "${K1:-0}" -gt 0
UNIT_KL="$(unit_path kubelet)"
CONF_KL="$SB/var/lib/kubelet/config.yaml"
KC_KL="$SB/var/lib/kubelet/kubelet.conf"
check "B4 kubelet 二进制已安装且可执行" test -x "$SB/usr/local/bin/kubelet"
check "B4 kubelet 版本 = v$VERSION" \
  bash -c "'$SB/usr/local/bin/kubelet' --version | grep -q 'v$VERSION'"
check "B4 kubelet config 已渲染" test -f "$CONF_KL"
check "B4 kubelet.conf 已渲染" test -f "$KC_KL"
check "B4 kubelet.conf 权限 0600 root:root" \
  bash -c "[[ \"\$(sudo -n stat -c '%u:%g %a' '$KC_KL' 2>/dev/null)\" == '0:0 600' ]]"
check "B4 kubelet config cgroupDriver=systemd" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("cgroupDriver")=="systemd" else 1)' "$CONF_KL"
check "B4 kubelet config anonymous.enabled=false" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d["authentication"]["anonymous"]["enabled"] is False else 1)' "$CONF_KL"
check "B4 kubelet config authorization.mode=Webhook" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d["authorization"]["mode"]=="Webhook" else 1)' "$CONF_KL"
check "B4 kubelet config runtime endpoint 指向沙箱 containerd" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("containerRuntimeEndpoint")==sys.argv[2] else 1)' "$CONF_KL" "unix://$SOCK"
check "B4 kubelet config failSwapOn=false（测试显式覆盖）" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("failSwapOn") is False else 1)' "$CONF_KL"
check "B4 kubelet config tlsCertFile = PKI kubelet 证书（serving CA 前置）" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("tlsCertFile")==sys.argv[2] else 1)' "$CONF_KL" "$SB/etc/kubernetes/pki/kubelet/node1.crt"
check "B4 kubelet config tlsPrivateKeyFile = PKI kubelet 私钥" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("tlsPrivateKeyFile")==sys.argv[2] else 1)' "$CONF_KL" "$SB/etc/kubernetes/pki/kubelet/node1.key"
check "B4 kubelet unit ExecStart 使用沙箱二进制" \
  grep -q "^ExecStart=$SB/usr/local/bin/kubelet " "$UNIT_KL"
check "B4 unit --config 指向沙箱" grep -q -- "--config=$CONF_KL" "$UNIT_KL"
check "B4 unit --kubeconfig 指向沙箱" grep -q -- "--kubeconfig=$KC_KL" "$UNIT_KL"
check "B4 unit --container-runtime-endpoint 指向沙箱 containerd" \
  grep -q -- "--container-runtime-endpoint=unix://$SOCK" "$UNIT_KL"
check "B4 unit --cgroup-driver=systemd" grep -q -- '--cgroup-driver=systemd' "$UNIT_KL"
check "B4 unit --root-dir 指向沙箱" grep -q -- "--root-dir=$SB/var/lib/kubelet" "$UNIT_KL"
check "B4 unit --cert-dir 指向沙箱" grep -q -- "--cert-dir=$SB/var/lib/kubelet/pki" "$UNIT_KL"
check "B4 unit --hostname-override=node1" grep -q -- '--hostname-override=node1' "$UNIT_KL"
check "B4 unit Restart=always" grep -q '^Restart=always' "$UNIT_KL"
check "B4 unit LimitNOFILE" grep -q '^LimitNOFILE=' "$UNIT_KL"
check "B4 unit After=network-online.target" grep -q '^After=network-online.target' "$UNIT_KL"
check "B4 unit WantedBy=multi-user.target" grep -q '^WantedBy=multi-user.target' "$UNIT_KL"
check_not "B4 unit 未占用默认 10250/10248" \
  grep -qE '10250|10248' "$UNIT_KL"

# kubeconfig 身份/链/私钥匹配（复用 T007 的解析逻辑）
kc_cert_subject() {
  python3 - "$1" <<'PY'
import base64, subprocess, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
pem = base64.b64decode(cfg["users"][0]["user"]["client-certificate-data"])
p = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
                   input=pem, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
print(p.stdout.decode().strip())
PY
}
kc_server() {
  python3 - "$1" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
print(cfg["clusters"][0]["cluster"]["server"])
PY
}
kc_verified() {
  python3 - "$1" "$2" <<'PY'
import base64, subprocess, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
pem = base64.b64decode(cfg["users"][0]["user"]["client-certificate-data"])
p = subprocess.run(["openssl", "verify", "-CAfile", sys.argv[2]], input=pem,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
sys.exit(p.returncode)
PY
}
kc_key_matches() {
  python3 - "$1" <<'PY'
import base64, subprocess, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
u = cfg["users"][0]["user"]
cert = base64.b64decode(u["client-certificate-data"])
key = base64.b64decode(u["client-key-data"])
cpub = subprocess.run(["openssl", "x509", "-noout", "-pubkey"], input=cert,
                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
kpub = subprocess.run(["openssl", "pkey", "-pubout"], input=key,
                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
sys.exit(0 if cpub.stdout.strip() and cpub.stdout.strip() == kpub.stdout.strip() else 1)
PY
}
kc_server_is() { [[ "$(kc_server "$1")" == "$2" ]]; }
kc_subject_has() { kc_cert_subject "$1" | grep -q -- "$2"; }
node_exists() { kctl get node node1 -o name 2>/dev/null | grep -qx 'node/node1'; }
kubelet_registered() {
  grep -qiE 'Successfully registered node|Registered node' "$SB/logs/kubelet.log" 2>/dev/null || node_exists
}
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$KC_KL" "$SB/client/kubelet.conf"
check "B4 kubelet.conf server = https://127.0.0.1:16443" \
  kc_server_is "$SB/client/kubelet.conf" "https://127.0.0.1:16443"
check "B4 kubelet.conf 身份 CN=system:node:node1" \
  kc_subject_has "$SB/client/kubelet.conf" 'CN=system:node:node1'
check "B4 kubelet.conf 身份 O=system:nodes" \
  kc_subject_has "$SB/client/kubelet.conf" 'O=system:nodes'
check "B4 kubelet 客户端证书由 kubernetes-ca 签发" \
  kc_verified "$SB/client/kubelet.conf" "$SB/client/ca.crt"
check "B4 kubelet.conf 内嵌证书与私钥匹配" \
  kc_key_matches "$SB/client/kubelet.conf"
check "B4 kubelet serving 证书含 serverAuth" \
  bash -c "openssl x509 -in '$SB/etc/kubernetes/pki/kubelet/node1.crt' -noout -text | grep -q 'TLS Web Server Authentication'"
check "B4 kubelet serving 证书 SAN 含 node1 与 127.0.0.1" \
  bash -c "openssl x509 -in '$SB/etc/kubernetes/pki/kubelet/node1.crt' -noout -text | grep -q 'DNS:node1' && openssl x509 -in '$SB/etc/kubernetes/pki/kubelet/node1.crt' -noout -text | grep -q 'IP Address:127.0.0.1'"

mapfile -t KL_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_KL")
if [[ ${#KL_ARGS[@]} -gt 0 ]]; then
  ( sudo -n "${KL_ARGS[@]}" </dev/null >>"$SB/logs/kubelet.log" 2>&1 ) &
  WRAPPER[kubelet]=$!
  for _ in $(seq 1 120); do PID[kubelet]="$(proc_pid kubelet)"; [[ -n "${PID[kubelet]}" ]] && break; sleep 0.1; done
  ok "已从 unit 拉起真实 kubelet（PID ${PID[kubelet]:-?}）"
else
  bad "无法解析 kubelet unit 的 ExecStart"
fi
check "B4 kubelet 进程存活" test -n "${PID[kubelet]:-}"
wait_node() {
  local i
  for ((i = 0; i < 240; i++)); do
    kctl get node node1 -o name 2>/dev/null | grep -qx 'node/node1' && return 0
    sleep 0.5
  done
  return 1
}
check "B4 kubectl get nodes 出现 node1（真实注册）" wait_node
NODE_READY="$(kctl get node node1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
NODE_REASON="$(kctl get node node1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)"
printf '  （节点 node1 Ready=%s reason=%s）\n' "${NODE_READY:-?}" "${NODE_REASON:-?}"
check "B4 节点 Ready 条件存在（True/False）" \
  bash -c "[[ '$NODE_READY' == 'True' || '$NODE_READY' == 'False' ]]"
check "B4 若 NotReady 则 reason 非空（CNI 未就绪可接受）" \
  bash -c "[[ '$NODE_READY' == 'True' || -n '$NODE_REASON' ]]"
check "B4 kubelet 进程参数含 --container-runtime-endpoint" \
  bash -c "tr '\\0' '\\n' <'/proc/${PID[kubelet]:-0}/cmdline' | grep -q -- '--container-runtime-endpoint=unix://$SOCK'"
check "B4 kubelet 进程参数含 --cgroup-driver=systemd" \
  bash -c "tr '\\0' '\\n' <'/proc/${PID[kubelet]:-0}/cmdline' | grep -qx -- '--cgroup-driver=systemd'"
check "B4 kubelet 进程参数含 --hostname-override=node1" \
  bash -c "tr '\\0' '\\n' <'/proc/${PID[kubelet]:-0}/cmdline' | grep -qx -- '--hostname-override=node1'"
check "B4 kubelet 日志显示成功注册节点" kubelet_registered

echo "-- B5 cgroup driver 一致性（containerd ↔ kubelet ↔ 进程参数）"
check "B5 containerd SystemdCgroup=true" grep -q 'SystemdCgroup = true' "$CONF_CD"
check "B5 kubelet config cgroupDriver=systemd" \
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d.get("cgroupDriver")=="systemd" else 1)' "$CONF_KL"
check "B5 kubelet 进程 --cgroup-driver=systemd" \
  bash -c "tr '\\0' '\\n' <'/proc/${PID[kubelet]:-0}/cmdline' | grep -qx -- '--cgroup-driver=systemd'"
check "B5 三者一致（无 cgroupfs 残留）" \
  bash -c "! grep -q 'SystemdCgroup = false' '$CONF_CD' && ! grep -q 'cgroupDriver: cgroupfs' '$CONF_KL'"

echo "-- B6 幂等（运行中重跑：changed=0 / 不通知 handler / PID 不变）"
declare -A ST_BEFORE=()
PIDS_BEFORE=""
for c in containerd kubelet; do
  ST_BEFORE[$c]="$(proc_starttime "${PID[$c]:-0}")"
  PIDS_BEFORE+="${PID[$c]:-0} "
done
HASH_BEFORE="$(sha_of "$CONF_CD") $(sha_of "$UNIT_CD") $(sha_of "$CONF_KL") $(sha_of "$UNIT_KL") $(sha_of "$KC_KL")"
if ap "$PLAY_CONTAINERD" /tmp/opencode/t008_containerd_run2.log; then
  c="$(changed_of /tmp/opencode/t008_containerd_run2.log)"
  check "B6 containerd 第二次运行 changed=0" test "${c:-x}" = "0"
else
  bad "B6 containerd 第二次运行失败（见 /tmp/opencode/t008_containerd_run2.log）"
fi
if ap "$PLAY_KUBELET" /tmp/opencode/t008_kubelet_run2.log; then
  c="$(changed_of /tmp/opencode/t008_kubelet_run2.log)"
  check "B6 kubelet 第二次运行 changed=0" test "${c:-x}" = "0"
else
  bad "B6 kubelet 第二次运行失败（见 /tmp/opencode/t008_kubelet_run2.log）"
fi
check "B6 未通知任何 restart handler" \
  bash -c "! grep -q 'RUNNING HANDLER' /tmp/opencode/t008_containerd_run2.log && ! grep -q 'RUNNING HANDLER' /tmp/opencode/t008_kubelet_run2.log"
PIDS_AFTER=""
for c in containerd kubelet; do PIDS_AFTER+="${PID[$c]:-0} "; done
check "B6 containerd/kubelet PID 未变（未被重启）" test "$PIDS_AFTER" = "$PIDS_BEFORE"
for c in containerd kubelet; do
  check "B6 $c /proc starttime 未变" \
    bash -c "[[ \"\$(awk '{ sub(/^.*\\) /, \"\"); print \$20 }' '/proc/${PID[$c]:-0}/stat' 2>/dev/null)\" == '${ST_BEFORE[$c]}' ]]"
done
check "B6 config/unit/kubeconfig 内容未变" \
  bash -c "[[ \"\$(sha256sum '$CONF_CD' '$UNIT_CD' '$CONF_KL' '$UNIT_KL' '$KC_KL' | awk '{print \$1}' | tr '\\n' ' ')\" == '$(printf '%s ' $HASH_BEFORE)' ]]"
check "B6 crictl info 仍正常" crictl_info
check "B6 节点仍存在" node_exists

echo "-- B7 fail-fast 矩阵（任何失败都不得改动已渲染 unit）"
unit_hash_now() { printf '%s %s' "$(sha_of "$UNIT_CD")" "$(sha_of "$UNIT_KL")"; }
UNIT_HASH_NOW="$(unit_hash_now)"
run_ff() {  # run_ff <play> <log> <extra-json>
  local play="$1" log="$2" extra="$3"
  timeout 600 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" \
    -e "{\"sandbox_root\":\"$SB\"}" -e "$extra" >"$log" 2>&1
}
# ① cgroup driver 不一致
rc=0
run_ff "$PLAY_KUBELET" /tmp/opencode/t008_ff_cgroup.log \
  '{"kubelet_cgroup_driver":"cgroupfs"}' || rc=$?
check "B7 cgroup 不一致 → exit≠0" test "$rc" -ne 0
check "B7 cgroup 不一致 → 错误提及 cgroup/systemd" \
  grep -qiE 'cgroup.*(不一致|mismatch|systemd)|systemd.*cgroup' /tmp/opencode/t008_ff_cgroup.log
check "B7 cgroup 不一致 → unit 未变" test "$(unit_hash_now)" = "$UNIT_HASH_NOW"
# ② 缺 runc
rc=0
run_ff "$PLAY_CONTAINERD" /tmp/opencode/t008_ff_runc.log \
  "{\"containerd_install_runc\":false,\"runc_binary\":\"$SB/missing/runc\"}" || rc=$?
check "B7 缺 runc → exit≠0" test "$rc" -ne 0
check "B7 缺 runc → 错误提及 runc" grep -qi 'runc' /tmp/opencode/t008_ff_runc.log
check "B7 缺 runc → unit 未变" test "$(unit_hash_now)" = "$UNIT_HASH_NOW"
# ③ 缺 CNI plugins
rc=0
run_ff "$PLAY_CONTAINERD" /tmp/opencode/t008_ff_cni.log \
  "{\"containerd_install_cni_plugins\":false,\"containerd_cni_bin_dir\":\"$SB/missing-cni\"}" || rc=$?
check "B7 缺 CNI plugins → exit≠0" test "$rc" -ne 0
check "B7 缺 CNI plugins → 错误提及 CNI" grep -qi 'cni' /tmp/opencode/t008_ff_cni.log
check "B7 缺 CNI plugins → unit 未变" test "$(unit_hash_now)" = "$UNIT_HASH_NOW"
# ④ CRI endpoint 不可用
rc=0
run_ff "$PLAY_KUBELET" /tmp/opencode/t008_ff_endpoint.log \
  "{\"kubelet_container_runtime_endpoint\":\"unix://$SB/run/containerd/missing.sock\"}" || rc=$?
check "B7 CRI endpoint 不可用 → exit≠0" test "$rc" -ne 0
check "B7 CRI endpoint 不可用 → 错误提及 endpoint/CRI" \
  grep -qiE 'cri endpoint|container-runtime-endpoint|runtime endpoint' /tmp/opencode/t008_ff_endpoint.log
check "B7 CRI endpoint 不可用 → unit 未变" test "$(unit_hash_now)" = "$UNIT_HASH_NOW"
# ⑤ 缺 kubelet 证书/CA
rc=0
run_ff "$PLAY_KUBELET" /tmp/opencode/t008_ff_cert.log \
  "{\"kubelet_client_cert_file\":\"$SB/missing/node1.crt\"}" || rc=$?
check "B7 缺 kubelet 证书 → exit≠0" test "$rc" -ne 0
check "B7 缺 kubelet 证书 → 错误提及证书/缺失文件" \
  grep -qiE '证书|client cert|node1.crt|缺少' /tmp/opencode/t008_ff_cert.log
check "B7 缺 kubelet 证书 → unit 未变" test "$(unit_hash_now)" = "$UNIT_HASH_NOW"
# ⑥ kubelet 版本不匹配
rc=0
run_ff "$PLAY_KUBELET" /tmp/opencode/t008_ff_kubelet_version.log \
  "{\"kubelet_version\":\"1.30.0\",\"kubelet_artifact_path\":\"$SB/opt/k8s/artifacts/kubelet\",\"kubelet_download_url\":\"http://127.0.0.1:1/kubelet\",\"kubelet_sha256\":\"${ART_SHA[kubelet]}\"}" || rc=$?
check "B7 kubelet 版本不匹配 → exit≠0" test "$rc" -ne 0
check "B7 kubelet 版本不匹配 → 错误给出实际版本" \
  bash -c "grep -q '版本与 kubelet_version=1.30.0 不一致' /tmp/opencode/t008_ff_kubelet_version.log && grep -q 'v$VERSION' /tmp/opencode/t008_ff_kubelet_version.log"
check "B7 kubelet 版本不匹配 → unit 未变" test "$(unit_hash_now)" = "$UNIT_HASH_NOW"
# ⑦ containerd 版本不匹配
rc=0
run_ff "$PLAY_CONTAINERD" /tmp/opencode/t008_ff_containerd_version.log \
  "{\"containerd_version\":\"1.30.0\",\"containerd_artifact_path\":\"$SB/opt/k8s/artifacts/$CONTAINERD_TARBALL\",\"containerd_download_url\":\"http://127.0.0.1:1/$CONTAINERD_TARBALL\",\"containerd_sha256\":\"${ART_SHA[$CONTAINERD_TARBALL]}\"}" || rc=$?
check "B7 containerd 版本不匹配 → exit≠0" test "$rc" -ne 0
check "B7 containerd 版本不匹配 → 错误给出实际版本" \
  bash -c "grep -q '版本与 containerd_version=1.30.0 不一致' /tmp/opencode/t008_ff_containerd_version.log && grep -q 'v$CONTAINERD_VERSION' /tmp/opencode/t008_ff_containerd_version.log"
check "B7 containerd 版本不匹配 → unit 未变" test "$(unit_hash_now)" = "$UNIT_HASH_NOW"
check "B7 全部 fail-fast 后 containerd/kubelet 仍存活" \
  bash -c "ps -o pid= -p '${PID[containerd]:-0}' >/dev/null 2>&1 && ps -o pid= -p '${PID[kubelet]:-0}' >/dev/null 2>&1"

echo "-- B8 清理与宿主零污染"
stop_proc "$SB/usr/local/bin/kubelet"
stop_proc "$SB/usr/local/bin/containerd"
stop_proc "$SB/usr/local/bin/kube-apiserver"
stop_proc "$SB/usr/local/bin/etcd"
restore_kernel_tunables
cleanup_kubepods_slices
for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
WRAPPER=()
all_stopped() {
  local b
  for b in kubelet containerd kube-apiserver etcd; do
    proc_alive "$SB/usr/local/bin/$b" && return 1
  done
  return 0
}
check "B8 运行时/控制面进程已全部退出" all_stopped
check "B8 高位端口全部释放" wait_ports_free
check "B8 沙箱 CRI socket 已随进程消失" test ! -S "$SOCK"

POST_HOST_UNITS="$(ls /etc/systemd/system/containerd.service /etc/systemd/system/kubelet.service 2>/dev/null | sort | tr '\n' ' ')"
POST_ETC_CONTAINERD="$(snapshot_path /etc/containerd)"
POST_ETC_K8S="$(snapshot_path /etc/kubernetes)"
POST_VAR_LIB_CONTAINERD="$(sudo -n stat -c '%F %a' /var/lib/containerd 2>/dev/null || echo __MISSING__)"
POST_RUN_CONTAINERD="$(sudo -n stat -c '%F %a' /run/containerd 2>/dev/null || echo __MISSING__)"
POST_OPT_CNI="$(snapshot_path /opt/cni/bin)"
POST_PORTS="$(snapshot_ports)"
check "B8 宿主 /etc/systemd/system 未新增 containerd/kubelet unit" test "$PRE_HOST_UNITS" = "$POST_HOST_UNITS"
check "B8 宿主 /etc/containerd 未被创建/改动" test "$PRE_ETC_CONTAINERD" = "$POST_ETC_CONTAINERD"
check "B8 宿主 /etc/kubernetes 未被创建/改动" test "$PRE_ETC_K8S" = "$POST_ETC_K8S"
check "B8 宿主 /var/lib/containerd 未变" test "$PRE_VAR_LIB_CONTAINERD" = "$POST_VAR_LIB_CONTAINERD"
check "B8 宿主 /run/containerd 未变" test "$PRE_RUN_CONTAINERD" = "$POST_RUN_CONTAINERD"
check "B8 宿主 /opt/cni/bin 未变" test "$PRE_OPT_CNI" = "$POST_OPT_CNI"
check "B8 宿主端口快照一致" test "$PRE_PORTS" = "$POST_PORTS"
check "B8 宿主 kernel.panic 已恢复" test "$PRE_KERNEL_PANIC" = "$(cat /proc/sys/kernel/panic 2>/dev/null)"
check "B8 宿主 kernel.panic_on_oops 已恢复" test "$PRE_KERNEL_PANIC_ON_OOPS" = "$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null)"
POST_KUBEPODS_SLICES="$(systemctl list-units --all 'kubepods*' --no-legend 2>/dev/null \
  | awk '{print $1}' | sort | tr '\n' ' ')"
check "B8 宿主 kubepods*.slice 已恢复（无残留 cgroup slice）" \
  test "$PRE_KUBEPODS_SLICES" = "$POST_KUBEPODS_SLICES"

sudo -n rm -rf "$SB"
check "B8 沙箱已清理" test ! -e "$SB"
SB=""

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
