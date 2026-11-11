#!/usr/bin/env bash
# =============================================================================
#  T011 cluster-addons 验收（kubeconfig / RBAC / CoreDNS）
#    - 静态：渲染正确性、权限、变量化、无硬编码、幂等/不覆盖语义
#    - 动态：真实 TLS etcd + kube-apiserver → admin/kubelet kubeconfig 认证与 RBAC 正反例
#    - 动态：CoreDNS 官方二进制按渲染 Corefile 真实解析（kubernetes 插件 + 上游转发）
#    - 反证：错误域 → NXDOMAIN；制品空缓存+不可达 → 显式失败
#    - 密闭：自动 unshare -n 自证；宿主零污染
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
check_eq() { local d="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok "$d"; else bad "$d [期望=$want 实际=${got:-<空>}]"; fi; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
changed_of() { awk -F'changed=' '/changed=/{split($2,a," ");s+=a[1]} END{print s+0}' "$1" 2>/dev/null; }

ROLE=roles/cluster-addons
INV=tests/cluster-addons/inventory.ini
PLAY_STACK=tests/cluster-addons/sandbox_stack.yml
PLAY_API=tests/cluster-addons/sandbox_apiserver.yml
PLAY_COREDNS=tests/cluster-addons/sandbox_coredns.yml
PLAY_RENDER=tests/cluster-addons/render.yml
UNIT_EXEC=tests/etcd/unit_exec.py
DNSQ=tests/cluster-addons/dnsq.py
DNSMOCK=tests/cluster-addons/dnsmock.py

VERSION=1.31.0
KP_SHA=9016f6048ff9827ef58934e98f28a8026634c10b4e6fcc1df49451038a23a9aa
KUBECTL_SHA=7c27adc64a84d1c0cc3dcf7bf4b6e916cc00f3f576a2dbac51b318d926032437
ETCD_TARBALL=etcd-v3.5.16-linux-amd64.tar.gz
ETCD_SHA=b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc
CD_VERSION=1.11.3
CD_TARBALL=coredns_${CD_VERSION}_linux_amd64.tgz
CD_SHA=6af4d6a5412734417378f778343c4fba363a61ae027060675123d4296f5a8ee5
CD_URL=https://github.com/coredns/coredns/releases/download/v${CD_VERSION}/${CD_TARBALL}

PORT_API=16443
PORT_ETCD=12379
PORT_DNS=15353
PORT_DNS_METRICS=19153
PORT_DNS_READY=19156
PORT_UPSTREAM=15354
PORT_DNS_BAD=15355
SVC_KUBE=10.96.0.1
DOMAIN=cluster.local

CACHE="${T011_TEST_CACHE:-/tmp/opencode/k8s-cache}"

ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook 2>/dev/null || echo "$HOME/ansible/bin/ansible-playbook")}"
if [[ ! -x "$ANSIBLE_PLAYBOOK" && -n "${SUDO_USER:-}" ]]; then
  _h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  [[ -n "$_h" && -x "$_h/ansible/bin/ansible-playbook" ]] && ANSIBLE_PLAYBOOK="$_h/ansible/bin/ansible-playbook"
fi
if [[ "$ANSIBLE_PLAYBOOK" == */ansible/bin/ansible-playbook ]]; then
  export PYTHONPATH="$(dirname "$(dirname "$ANSIBLE_PLAYBOOK")")${PYTHONPATH:+:$PYTHONPATH}"
fi
USER_SITE="$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null || true)"

ensure_artifact() {  # <name> <url> <sha>
  local n="$1" u="$2" sh="$3" p="$CACHE/$1"
  [[ -f "$p" && "$(sha_of "$p")" == "$sh" ]] && return 0
  printf '  （预取制品 %s）\n' "$n"
  curl -fL --retry 3 --connect-timeout 20 --max-time 900 -o "$p.tmp" "$u" || { rm -f "$p.tmp"; return 1; }
  mv "$p.tmp" "$p"
  [[ "$(sha_of "$p")" == "$sh" ]]
}
ensure_etcd() {
  local p="$CACHE/$ETCD_TARBALL"
  [[ -f "$p" && "$(sha_of "$p")" == "$ETCD_SHA" ]] && return 0
  ensure_artifact "$ETCD_TARBALL" "https://storage.googleapis.com/etcd/v3.5.16/$ETCD_TARBALL" "$ETCD_SHA"
}
prefill() {
  mkdir -p "$CACHE" || return 1
  ensure_artifact kube-apiserver "https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kube-apiserver" "$KP_SHA" || return 1
  ensure_artifact kubectl "https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kubectl" "$KUBECTL_SHA" || return 1
  ensure_etcd || return 1
  ensure_artifact "$CD_TARBALL" "$CD_URL" "$CD_SHA" || return 1
}

if [[ "${T011_IN_NETNS:-0}" != "1" ]]; then
  if ! prefill; then
    printf '  \033[31mFAIL\033[0m 无法预取官方制品（首次运行需要外网）\n'
    echo "== 汇总: PASS=$pass FAIL=$((fail+1)) =="
    exit 1
  fi
  if sudo -n true 2>/dev/null && sudo -n unshare -n bash -c 'ip link set lo up >/dev/null 2>&1; ! ip route show default | grep -q .' >/dev/null 2>&1; then
    exec sudo -n env T011_IN_NETNS=1 PYTHONPATH="${PYTHONPATH:-}" ANSIBLE_PLAYBOOK="$ANSIBLE_PLAYBOOK" \
      T011_TEST_CACHE="$CACHE" unshare -n bash -c 'ip link set lo up; exec "$@"' _ bash "$(readlink -f "$0")"
  fi
fi

echo "== T011 cluster-addons 验收 =="

SB=""
FAILSB=""
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  for p in "${PIDS[@]:-}"; do wait "$p" 2>/dev/null || true; done
  [[ -n "${SB:-}" ]] && rm -rf "$SB" 2>/dev/null || true
  [[ -n "${FAILSB:-}" ]] && rm -rf "$FAILSB" 2>/dev/null || true
}
trap cleanup EXIT

echo "-- A1 role / 测试资产结构"
for f in defaults/main.yml tasks/main.yml tasks/validate.yml tasks/facts.yml tasks/kubeconfigs.yml \
  tasks/manifests.yml tasks/verify.yml meta/main.yml README.md \
  templates/admin.kubeconfig.j2 templates/kubelet.kubeconfig.j2 templates/rbac.yaml.j2 \
  templates/coredns.yaml.j2 templates/Corefile.j2; do
  check "存在 $ROLE/$f" test -f "$ROLE/$f"
done
for f in "$INV" "$PLAY_STACK" "$PLAY_API" "$PLAY_RENDER" "$PLAY_COREDNS" "$DNSQ" "$DNSMOCK"; do
  check "存在 $f" test -f "$f"
done
check_not "role 无被 .gitignore 忽略的文件" \
  bash -c 'find "$1" -type f | git check-ignore --stdin >/dev/null 2>&1' _ "$ROLE"

echo "-- A2 变量化 / 无硬编码"
check "defaults 声明 root_prefix" grep -qE '^cluster_addons_root_prefix:' "$ROLE/defaults/main.yml"
check "defaults 声明 cluster_domain" grep -qE '^cluster_addons_cluster_domain:' "$ROLE/defaults/main.yml"
check "defaults 声明 coredns_version" grep -qE '^cluster_addons_coredns_version:' "$ROLE/defaults/main.yml"
check "defaults 声明 kubeconfig_mode 0600" grep -qE '^cluster_addons_kubeconfig_mode: "0600"' "$ROLE/defaults/main.yml"
check_not "tasks/templates 无硬编码 1.11.3" grep -rq '1\.11\.3' "$ROLE/tasks" "$ROLE/templates"
check_not "tasks/templates 无硬编码 cluster.local" grep -rq 'cluster\.local' "$ROLE/tasks" "$ROLE/templates"
check_not "tasks/templates 无硬编码 /etc/kubernetes" grep -rq '/etc/kubernetes' "$ROLE/tasks" "$ROLE/templates"
check_not "tasks/templates 无硬编码 docker.io" grep -rq 'docker\.io' "$ROLE/tasks" "$ROLE/templates"
check "RBAC 不含 secrets 资源" bash -c '! grep -vE "^[[:space:]]*#" "$1" | grep -q "secrets"' _ "$ROLE/templates/rbac.yaml.j2"
check "kubelet 绑定 Group system:nodes" grep -q 'system:nodes' "$ROLE/templates/rbac.yaml.j2"
check "CoreDNS 使用 ServiceAccount 变量" grep -q 'cluster_addons_coredns_service_account' "$ROLE/templates/coredns.yaml.j2"
check "Corefile 使用 domain 变量" grep -q 'cluster_addons_cluster_domain' "$ROLE/templates/Corefile.j2"

echo "-- B1 沙箱 stack（真实 pki + etcd unit + kubectl + CoreDNS 制品）"
SB="$(mktemp -d /tmp/opencode/t011.XXXXXX)"; chmod 0755 "$SB"
mkdir -p "$SB/opt/k8s/artifacts" "$SB/logs" "$SB/client" "$SB/usr/local/bin"
for n in kube-apiserver kubectl; do cp "$CACHE/$n" "$SB/opt/k8s/artifacts/$n"; done
cp "$CACHE/$ETCD_TARBALL" "$SB/opt/k8s/artifacts/"
cp "$CACHE/$CD_TARBALL" "$SB/opt/k8s/artifacts/"
tar -xzf "$SB/opt/k8s/artifacts/$ETCD_TARBALL" -C "$SB/usr/local/bin" --strip-components=1 \
  "etcd-v3.5.16-linux-amd64/etcd" "etcd-v3.5.16-linux-amd64/etcdctl" 2>/dev/null
tar -xzf "$SB/opt/k8s/artifacts/$CD_TARBALL" -C "$SB/usr/local/bin" coredns 2>/dev/null
chmod 0755 "$SB/usr/local/bin/"* 2>/dev/null
check "etcd/etcdctl 已解包" test -x "$SB/usr/local/bin/etcd"
check "coredns 已解包" test -x "$SB/usr/local/bin/coredns"
check "coredns -version" bash -c '"$1" -version 2>&1 | grep -q "CoreDNS-1.11.3"' _ "$SB/usr/local/bin/coredns"

ap() { local play="$1" log="$2"; shift 2
  timeout 900 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" -e "{\"sandbox_root\":\"$SB\"}" "$@" >"$log" 2>&1; }
check "stack playbook exit 0" ap "$PLAY_STACK" "$SB/logs/stack.log"
check "产出 kubernetes-ca" test -f "$SB/etc/kubernetes/pki/ca.crt"
check "产出 node1 kubelet 证书" test -f "$SB/etc/kubernetes/pki/kubelet/node1.crt"
check "产出 etcd unit" test -f "$SB/etc/systemd/system/etcd-etcd1.service"

echo "-- B2 渲染 kubeconfig / RBAC / CoreDNS（首跑）"
check "render 首跑 exit 0" ap "$PLAY_RENDER" "$SB/logs/render1.log"
check "首跑 changed>0" bash -c '[ "$1" -gt 0 ]' _ "$(changed_of "$SB/logs/render1.log")"
ADMIN="$SB/etc/kubernetes/admin.conf"
KUBELET="$SB/etc/kubernetes/kubelet.conf"
MAN="$SB/etc/kubernetes/addons/manifests"
check "admin.conf 存在" test -f "$ADMIN"
check "kubelet.conf 存在" test -f "$KUBELET"
check "admin.conf 0600 root:root" bash -c '[ "$(stat -c "%a %U %G" "$1")" = "600 root root" ]' _ "$ADMIN"
check "kubelet.conf 0600 root:root" bash -c '[ "$(stat -c "%a %U %G" "$1")" = "600 root root" ]' _ "$KUBELET"
check "admin.conf apiVersion/kind" bash -c 'grep -qx "apiVersion: v1" "$1" && grep -qx "kind: Config" "$1"' _ "$ADMIN"
check "admin.conf server 变量生效" grep -q 'server: https://127.0.0.1:16443' "$ADMIN"
check "admin.conf CA 内嵌非空" bash -c 'grep -q "certificate-authority-data: LS0t" "$1"' _ "$ADMIN"
check "admin.conf client cert/key 内嵌" bash -c 'grep -q "client-certificate-data: LS0t" "$1" && grep -q "client-key-data: LS0t" "$1"' _ "$ADMIN"
check "admin.conf 用户 kubernetes-admin" grep -q 'name: kubernetes-admin' "$ADMIN"
check "kubelet.conf 用户 system:node:node1" grep -q 'name: system:node:node1' "$KUBELET"
check_not "admin.conf 不含明文私钥 PEM" grep -q 'BEGIN .*PRIVATE KEY' "$ADMIN"

for f in rbac.yaml coredns.yaml Corefile; do
  check "清单存在 $f" test -f "$MAN/$f"
done
check "rbac 含 kubelet ClusterRole" grep -q 'name: kubelet-api-access' "$MAN/rbac.yaml"
check "rbac 含 coredns ClusterRole" grep -q 'name: coredns' "$MAN/rbac.yaml"
check "rbac kubelet 可 create events" bash -c 'grep -A6 "resources: \[\"events\"\]" "$1" | grep -q create' _ "$MAN/rbac.yaml"
check_not "rbac 无 secrets" bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -q "secrets"' _ "$MAN/rbac.yaml"
check "coredns Deployment replicas=2" grep -q 'replicas: 2' "$MAN/coredns.yaml"
check "coredns 镜像含版本变量结果" grep -q 'docker.io/coredns/coredns:1.11.3' "$MAN/coredns.yaml"
check "coredns Service 端口 53" bash -c 'grep -q "port: 53" "$1"' _ "$MAN/coredns.yaml"
check "Corefile kubernetes 插件域" grep -q 'kubernetes cluster.local in-addr.arpa ip6.arpa' "$MAN/Corefile"
check "Corefile 含 ready/health/cache/forward" bash -c 'grep -q ready "$1" && grep -q health "$1" && grep -q "cache 30" "$1" && grep -q "forward . /etc/resolv.conf" "$1"' _ "$MAN/Corefile"
check "Corefile 含 loop/reload/loadbalance" bash -c 'grep -q loop "$1" && grep -q reload "$1" && grep -q loadbalance "$1"' _ "$MAN/Corefile"

echo "-- B3 幂等 / 不覆盖语义"
H_ADMIN="$(sha_of "$ADMIN")"; H_KUBELET="$(sha_of "$KUBELET")"; H_RBAC="$(sha_of "$MAN/rbac.yaml")"
check "render 第二跑 exit 0" ap "$PLAY_RENDER" "$SB/logs/render2.log"
check "第二跑 changed=0" bash -c '[ "$1" -eq 0 ]' _ "$(changed_of "$SB/logs/render2.log")"
check "admin.conf 哈希不变" test "$(sha_of "$ADMIN")" = "$H_ADMIN"
check "kubelet.conf 哈希不变" test "$(sha_of "$KUBELET")" = "$H_KUBELET"
check "rbac.yaml 哈希不变" test "$(sha_of "$MAN/rbac.yaml")" = "$H_RBAC"
printf '# MARKER-KEEP\n' >>"$ADMIN"
ap "$PLAY_RENDER" "$SB/logs/render3.log"
check "marker 保留（rotate=false 不覆盖）" grep -q 'MARKER-KEEP' "$ADMIN"
ap "$PLAY_RENDER" "$SB/logs/render4.log" -e '{"cluster_addons_rotate_kubeconfigs":true}'
check_not "rotate=true 后 marker 消失" grep -q 'MARKER-KEEP' "$ADMIN"
check "rotate 后 admin.conf 仍 0600" bash -c '[ "$(stat -c %a "$1")" = "600" ]' _ "$ADMIN"

echo "-- B4 fail-fast 矩阵（失败不得落盘/不改已渲染文件）"
FFRUN=0
ff_case() {  # <label> <json> [nocert]
  local label="$1" js="$2" mode="${3:-cert}" FF rc=0
  FF="$(mktemp -d /tmp/opencode/t011ff.XXXXXX)"; chmod 0755 "$FF"
  if [[ "$mode" == cert ]]; then
    mkdir -p "$FF/etc/kubernetes"
    cp -a "$SB/etc/kubernetes/pki" "$FF/etc/kubernetes/pki"
  fi
  timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_RENDER" \
    -e "{\"sandbox_root\":\"$FF\"}" -e "$js" >"$SB/logs/ff_${label}.log" 2>&1 || rc=$?
  check "B4 $label → exit≠0" test "$rc" -ne 0
  check "B4 $label → 不落盘清单" test ! -e "$FF/etc/kubernetes/addons/manifests/coredns.yaml"
  rm -rf "$FF"
}
ff_case node_bad  '{"cluster_addons_kubelet_node":"Bad_Node"}'
ff_case domain_bad '{"cluster_addons_cluster_domain":"bad_domain!"}'
ff_case server_bad '{"cluster_addons_server":"ftp://x"}'
ff_case ca_missing '{}' nocert
ff_case ver_bad   '{"cluster_addons_coredns_version":"latest"}'
ff_case up_bad    '{"cluster_addons_coredns_upstream":"bad upstream"}'
ff_case port_bad  '{"cluster_addons_coredns_listen_port":70000}'
ff_case kubelet_missing '{"cluster_addons_kubelet_node":"ghost"}'
FF="$(mktemp -d /tmp/opencode/t011ff.XXXXXX)"; chmod 0755 "$FF"; mkdir -p "$FF/etc/kubernetes"
cp -a "$SB/etc/kubernetes/pki" "$FF/etc/kubernetes/pki"
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_RENDER" -e "{\"sandbox_root\":\"$FF\",\"cluster_addons_admin_cert\":\"$SB/etc/kubernetes/pki/etcd/server.crt\"}" >"$SB/logs/ff_chain.log" 2>&1 || rc=$?
check "B4 证书与 CA 不匹配 → exit≠0" test "$rc" -ne 0
check "B4 证书与 CA 不匹配 → 不落盘" test ! -e "$FF/etc/kubernetes/addons/manifests/coredns.yaml"
rm -rf "$FF"

H_RBAC2="$(sha_of "$MAN/rbac.yaml")"; H_CD2="$(sha_of "$MAN/coredns.yaml")"
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_RENDER" -e "{\"sandbox_root\":\"$SB\",\"cluster_addons_cluster_domain\":\"bad_domain!\"}" >"$SB/logs/ff_same.log" 2>&1 || rc=$?
check "B4 失败不改已渲染清单（rbac）" test "$(sha_of "$MAN/rbac.yaml")" = "$H_RBAC2"
check "B4 失败不改已渲染清单（coredns）" test "$(sha_of "$MAN/coredns.yaml")" = "$H_CD2"

echo "-- C1 真实 etcd + kube-apiserver（沙箱 TLS）"
PRE_ETC_K8S="$(test -e /etc/kubernetes && echo exists || echo absent)"
PRE_ROUTES="$(ip route show | grep -c '10.96.0.0/12' || true)"
PRE_NETNS="$(ip netns list 2>/dev/null | wc -l)"

UNIT_ETCD="$SB/etc/systemd/system/etcd-etcd1.service"
check "etcd unit 已渲染" test -f "$UNIT_ETCD"
mapfile -t ETCD_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_ETCD")
if [[ ${#ETCD_ARGS[@]} -gt 0 ]]; then
  ( "${ETCD_ARGS[@]}" </dev/null >>"$SB/logs/etcd.log" 2>&1 ) &
  PIDS+=($!); ok "已从 unit 拉起单成员 TLS etcd"
else bad "无法解析 etcd ExecStart"; fi
ETCD_PKI="$SB/etc/kubernetes/pki/etcd"
install -m 0600 "$ETCD_PKI/ca.crt" "$SB/client/etcd-ca.crt"
install -m 0600 "$SB/etc/kubernetes/pki/apiserver-etcd-client.crt" "$SB/client/etcd-client.crt"
install -m 0600 "$SB/etc/kubernetes/pki/apiserver-etcd-client.key" "$SB/client/etcd-client.key"
etcd_ok() { ETCDCTL_API=3 "$SB/usr/local/bin/etcdctl" --endpoints="https://127.0.0.1:$PORT_ETCD" \
  --cacert "$SB/client/etcd-ca.crt" --cert "$SB/client/etcd-client.crt" --key "$SB/client/etcd-client.key" \
  --command-timeout=2s endpoint health >/dev/null 2>&1; }
w=0; while ((w<120)) && ! etcd_ok; do sleep 0.5; w=$((w+1)); done
check "单成员 etcd healthy" etcd_ok

check "apiserver playbook exit 0" ap "$PLAY_API" "$SB/logs/apiserver.log"
UNIT_API="$SB/etc/systemd/system/kube-apiserver.service"
check "apiserver unit 已渲染" test -f "$UNIT_API"
mapfile -t API_ARGS < <(python3 "$UNIT_EXEC" "$UNIT_API")
if [[ ${#API_ARGS[@]} -gt 0 ]]; then
  ( "${API_ARGS[@]}" </dev/null >>"$SB/logs/apiserver-run.log" 2>&1 ) &
  PIDS+=($!); ok "已从 unit 拉起 kube-apiserver"
else bad "无法解析 apiserver ExecStart"; fi

KUBECTL="$SB/usr/local/bin/kubectl"
kadmin() { "$KUBECTL" --kubeconfig "$ADMIN" --cache-dir "$SB/client/kc-admin" --request-timeout=10s "$@"; }
kkubelet() { "$KUBECTL" --kubeconfig "$KUBELET" --cache-dir "$SB/client/kc-kubelet" --request-timeout=10s "$@"; }
w=0; while ((w<180)) && [[ "$(kadmin get --raw /healthz 2>/dev/null)" != "ok" ]]; do sleep 0.5; w=$((w+1)); done
check "admin kubeconfig → /healthz = ok" bash -c '[ "$1" = "ok" ]' _ "$(kadmin get --raw /healthz 2>/dev/null)"
check_eq "admin 是 cluster-admin（can-i '*' '*'）" yes "$(kadmin auth can-i '*' '*' 2>/dev/null | tr -d '\r')"
check_eq "kubelet.conf 身份 = system:node:node1" "system:node:node1" "$(kkubelet auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)"
check_eq "kubernetes Service IP = $SVC_KUBE" "$SVC_KUBE" "$(kadmin get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"

echo "-- C2 RBAC 正反例（kubelet kubeconfig 真实认证）"
check "apply rbac 清单" kadmin apply -f "$MAN/rbac.yaml"
check_eq "kubelet can-i get nodes = yes" yes "$(kkubelet auth can-i get nodes 2>/dev/null | tr -d '\r')"
check_eq "kubelet can-i create events = yes" yes "$(kkubelet auth can-i create events 2>/dev/null | tr -d '\r')"
check_eq "kubelet can-i patch nodes/status = yes" yes "$(kkubelet auth can-i patch nodes/status 2>/dev/null | tr -d '\r')"
check_eq "kubelet can-i list secrets = no" no "$(kkubelet auth can-i list secrets -n default 2>/dev/null | tr -d '\r')"
check_eq "kubelet can-i create pods = no" no "$(kkubelet auth can-i create pods -n default 2>/dev/null | tr -d '\r')"
check_eq "kubelet can-i delete nodes = no" no "$(kkubelet auth can-i delete nodes 2>/dev/null | tr -d '\r')"

echo "-- D1 CoreDNS 官方二进制按渲染 Corefile 真实解析"
DEMO_IP="$(kadmin create service clusterip demo --tcp=80:8080 -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
check "已创建 demo Service 且分配 ClusterIP" bash -c '[ -n "$1" ]' _ "$DEMO_IP"
CDIR="$SB/coredns-test/manifests"
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_RENDER" -e "{\"sandbox_root\":\"$SB\",\"cluster_addons_manifest_dir\":\"$CDIR\",\"cluster_addons_coredns_listen_port\":$PORT_DNS,\"cluster_addons_coredns_metrics_port\":$PORT_DNS_METRICS,\"cluster_addons_coredns_ready_port\":$PORT_DNS_READY,\"cluster_addons_coredns_upstream\":\"127.0.0.1:$PORT_UPSTREAM\",\"cluster_addons_coredns_kubernetes_endpoint\":\"https://127.0.0.1:$PORT_API\",\"cluster_addons_coredns_tls_cert\":\"$SB/etc/kubernetes/pki/admin.crt\",\"cluster_addons_coredns_tls_key\":\"$SB/etc/kubernetes/pki/admin.key\",\"cluster_addons_coredns_tls_ca\":\"$SB/etc/kubernetes/pki/ca.crt\"}" >"$SB/logs/render-dns.log" 2>&1 || rc=$?
check "D1 测试用 Corefile 渲染 exit 0" test "$rc" -eq 0
check "D1 Corefile 含 endpoint" grep -q "endpoint https://127.0.0.1:$PORT_API" "$CDIR/Corefile"
check "D1 Corefile 含 tls" grep -q '^        tls ' "$CDIR/Corefile"
check "D1 Corefile 监听高位端口" grep -q "^.:$PORT_DNS {" "$CDIR/Corefile"

(python3 "$DNSMOCK" "$PORT_UPSTREAM" 203.0.113.9 >"$SB/logs/dnsmock.log" 2>&1) & PIDS+=($!)
("$SB/usr/local/bin/coredns" -conf "$CDIR/Corefile" >"$SB/logs/coredns.log" 2>&1) & CD_PID=$!; PIDS+=($CD_PID)
dns_rc() { python3 "$DNSQ" 127.0.0.1 "$1" "$2" 2>/dev/null | awk -F= '/^RCODE=/{print $2}'; }
dns_a()  { python3 "$DNSQ" 127.0.0.1 "$1" "$2" 2>/dev/null | awk -F= '/^A=/{print $2}'; }
w=0; while ((w<60)) && [[ "$(dns_rc "$PORT_DNS" "kubernetes.default.svc.$DOMAIN")" != "0" ]]; do sleep 0.5; w=$((w+1)); done
check "D1 CoreDNS RCODE=0（kubernetes.default）" bash -c '[ "$1" = "0" ]' _ "$(dns_rc "$PORT_DNS" "kubernetes.default.svc.$DOMAIN")"
check "D1 kubernetes.default → $SVC_KUBE" bash -c '[ "$1" = "$2" ]' _ "$(dns_a "$PORT_DNS" "kubernetes.default.svc.$DOMAIN")" "$SVC_KUBE"
check "D1 demo.default → 分配的 ClusterIP" bash -c '[ "$1" = "$2" ]' _ "$(dns_a "$PORT_DNS" "demo.default.svc.$DOMAIN")" "$DEMO_IP"
check "D1 上游转发 upstream.test → 203.0.113.9" bash -c '[ "$1" = "203.0.113.9" ]' _ "$(dns_a "$PORT_DNS" "upstream.test")"
w=0; READY_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT_DNS_READY/ready")"
while ((w<60)) && [[ "$READY_CODE" != "200" ]]; do sleep 0.5; w=$((w+1)); READY_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT_DNS_READY/ready")"; done
check_eq "D1 ready 端点 200（ready 插件独立端口）" 200 "$READY_CODE"

echo "-- D2 反证：域变量真实生效（新域可解析、旧域 NXDOMAIN）"
BDIR="$SB/coredns-bad/manifests"
rc=0
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_RENDER" -e "{\"sandbox_root\":\"$SB\",\"cluster_addons_manifest_dir\":\"$BDIR\",\"cluster_addons_cluster_domain\":\"bogus.local\",\"cluster_addons_coredns_listen_port\":$PORT_DNS_BAD,\"cluster_addons_coredns_metrics_port\":19154,\"cluster_addons_coredns_upstream\":\"127.0.0.1:$PORT_UPSTREAM\",\"cluster_addons_coredns_kubernetes_endpoint\":\"https://127.0.0.1:$PORT_API\",\"cluster_addons_coredns_tls_cert\":\"$SB/etc/kubernetes/pki/admin.crt\",\"cluster_addons_coredns_tls_key\":\"$SB/etc/kubernetes/pki/admin.key\",\"cluster_addons_coredns_tls_ca\":\"$SB/etc/kubernetes/pki/ca.crt\"}" >"$SB/logs/render-bad.log" 2>&1 || rc=$?
check "D2 错误域渲染 exit 0" test "$rc" -eq 0
("$SB/usr/local/bin/coredns" -conf "$BDIR/Corefile" >"$SB/logs/coredns-bad.log" 2>&1) & PIDS+=($!)
w=0; while ((w<60)) && [[ "$(dns_rc "$PORT_DNS_BAD" "upstream.test")" != "0" ]]; do sleep 0.5; w=$((w+1)); done
w=0; A_BOGUS="$(dns_a "$PORT_DNS_BAD" "demo.default.svc.bogus.local")"
while ((w<60)) && [[ "$A_BOGUS" != "$DEMO_IP" ]]; do sleep 0.5; w=$((w+1)); A_BOGUS="$(dns_a "$PORT_DNS_BAD" "demo.default.svc.bogus.local")"; done
check_eq "D2 错误域实例按 bogus.local 解析 demo → ClusterIP" "$DEMO_IP" "$A_BOGUS"
w=0; RC_OLD="$(dns_rc "$PORT_DNS_BAD" "demo.default.svc.$DOMAIN")"
while ((w<60)) && [[ "$RC_OLD" == "" ]]; do sleep 0.5; w=$((w+1)); RC_OLD="$(dns_rc "$PORT_DNS_BAD" "demo.default.svc.$DOMAIN")"; done
check_eq "D2 错误域实例拒绝旧域 cluster.local（NXDOMAIN）" 3 "$RC_OLD"

echo "-- E1 密闭性（unshare -n / 空缓存+不可达 / --check 不写）"
check "套件运行在独立 netns（无默认路由）" bash -c '! ip route show default | grep -q .'
EMPTY="$(mktemp -d /tmp/opencode/t011empty.XXXXXX)"; chmod 0755 "$EMPTY"
rc=0
timeout 180 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_COREDNS" -e "{\"sandbox_root\":\"$EMPTY\",\"download_cache_dir_override\":\"$EMPTY/art\",\"coredns_version\":\"$CD_VERSION\",\"coredns_url\":\"http://127.0.0.1:1/nope.tgz\",\"coredns_sha256\":\"$CD_SHA\"}" >"$SB/logs/empty-cache.log" 2>&1 || rc=$?
check "空缓存+不可达 URL → 显式失败" test "$rc" -ne 0
check "失败不留下制品" test ! -e "$EMPTY/art/$CD_TARBALL"
rm -rf "$EMPTY"
CK="$(mktemp -d /tmp/opencode/t011ck.XXXXXX)"; chmod 0755 "$CK"; mkdir -p "$CK/etc/kubernetes"
cp -a "$SB/etc/kubernetes/pki" "$CK/etc/kubernetes/pki"
timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_RENDER" -e "{\"sandbox_root\":\"$CK\"}" --check >"$SB/logs/check.log" 2>&1 || true
check "--check 不写 kubeconfig" test ! -e "$CK/etc/kubernetes/admin.conf"
check "--check 不写清单" test ! -e "$CK/etc/kubernetes/addons/manifests/coredns.yaml"
rm -rf "$CK"

echo "-- E2 宿主零污染 / 收尾"
for i in "${!PIDS[@]}"; do kill "${PIDS[$i]}" 2>/dev/null || true; done
for i in "${!PIDS[@]}"; do wait "${PIDS[$i]}" 2>/dev/null || true; done
PIDS=()
check_not "沙箱进程已全部退出" pgrep -f "^$SB/"
check "宿主未新增 /etc/kubernetes" bash -c '[ "$1" = "$2" ]' _ "$(test -e /etc/kubernetes && echo exists || echo absent)" "$PRE_ETC_K8S"
check "宿主无 10.96.0.0/12 路由残留" bash -c '[ "$1" = "$2" ]' _ "$(ip route show | grep -c "10.96.0.0/12" || true)" "$PRE_ROUTES"
check "无残留 netns" bash -c '[ "$1" = "$2" ]' _ "$(ip netns list 2>/dev/null | wc -l)" "$PRE_NETNS"
rm -rf "$SB"; SB=""
check "沙箱目录已清理" test ! -d "$SB"

echo "== 汇总: PASS=$pass FAIL=$fail =="
[[ "$fail" -eq 0 ]]
