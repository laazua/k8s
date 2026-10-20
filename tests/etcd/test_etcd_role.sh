#!/usr/bin/env bash
# =============================================================================
# T005 etcd 集群 role（etcd）验收测试（TDD：先红后绿）
#  策略：真实启动**单机 3 实例** etcd 集群（高位端口，独立 data-dir / unit / 端口），
#        用真实 etcdctl 断言 endpoint health / member list / leader / 读写 / kill→恢复；
#        TLS 默认开启（复用 T004 pki 证书 + --client-cert-auth），另验 TLS 关闭分支；
#        systemd 副作用受限：只渲染 unit 到沙箱并断言，不碰宿主 /etc/systemd/system。
#  用法: tests/etcd/test_etcd_role.sh
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
mkdir -p /tmp/opencode

pass_count=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# --- Ansible 探测：优先 $ANSIBLE_PLAYBOOK，其次 PATH，最后 $HOME/ansible 本地安装 ---
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook 2>/dev/null || echo "$HOME/ansible/bin/ansible-playbook")}"
if [[ "$ANSIBLE_PLAYBOOK" == */ansible/bin/ansible-playbook ]]; then
  export PYTHONPATH="$(dirname "$(dirname "$ANSIBLE_PLAYBOOK")"):${PYTHONPATH:-}"
fi
have_ansible() { command -v "$ANSIBLE_PLAYBOOK" >/dev/null 2>&1 || [[ -x "$ANSIBLE_PLAYBOOK" ]]; }

ROLE=roles/etcd
PLAY=tests/etcd/sandbox.yml
INV=tests/etcd/inventory.ini
INV_EVEN=tests/etcd/inventory_even.ini
UNIT_EXEC=tests/etcd/unit_exec.py
YAMLLINT="${YAMLLINT:-yamllint}"

# --- 固定制品（版本 / sha256 由测试作为 spec；defaults 必须与之一致）--------
ETCD_VERSION=3.5.16
ETCD_ARCH=amd64
ETCD_TARBALL="etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}.tar.gz"
ETCD_SHA="b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc"
ETCD_URL="https://storage.googleapis.com/etcd/v${ETCD_VERSION}/${ETCD_TARBALL}"
CACHE="${ETCD_TEST_CACHE:-/tmp/opencode/etcd-cache}"
mkdir -p "$CACHE"

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
snapshot_path() {
  local p="$1"
  if [[ -e "$p" ]]; then
    if [[ -f "$p" ]]; then sha_of "$p"; else stat -c '%F %a' "$p"; fi
  else printf '__MISSING__'; fi
}

echo "== T005 etcd role 验收 =="

echo "-- A1 role / 测试资产结构"
for f in "$ROLE/defaults/main.yml" "$ROLE/tasks/main.yml" "$ROLE/tasks/facts.yml" \
  "$ROLE/tasks/validate.yml" "$ROLE/tasks/binary.yml" "$ROLE/tasks/config.yml" \
  "$ROLE/tasks/service.yml" "$ROLE/handlers/main.yml" "$ROLE/meta/main.yml" \
  "$ROLE/templates/etcd.service.j2" "$ROLE/README.md"; do
  check "存在 $f" "[[ -f '$f' ]]"
done
for f in "$PLAY" "$INV" "$INV_EVEN" "$UNIT_EXEC"; do
  check "存在 $f" "[[ -f '$f' ]]"
done
check "unit_exec.py 可执行" "[[ -x '$UNIT_EXEC' ]]"

echo "-- A19 变量化 / 禁止硬编码成员与端口"
DEFAULTS="$ROLE/defaults/main.yml"
check "defaults 提供 etcd_version" "grep -qE '^etcd_version:' '$DEFAULTS'"
check "defaults 的版本为 ${ETCD_VERSION}" "grep -qE '^etcd_version:[[:space:]]*\"?${ETCD_VERSION}\"?' '$DEFAULTS'"
check "defaults 提供 etcd_download_url（含版本/架构变量）" \
  "grep -qE '^etcd_download_url:.*etcd_version' '$DEFAULTS' && grep -q 'etcd_arch' '$DEFAULTS'"
check "defaults 的 sha256 与官方 tarball 实测一致" "grep -q '$ETCD_SHA' '$DEFAULTS'"
check "defaults 复用 k8s_artifact_dir" "grep -q 'k8s_artifact_dir' '$DEFAULTS'"
check "defaults 提供 etcd_inventory_group" "grep -qE '^etcd_inventory_group:' '$DEFAULTS'"
check "defaults 提供 client/peer 端口" \
  "grep -qE '^etcd_port_client:' '$DEFAULTS' && grep -qE '^etcd_port_peer:' '$DEFAULTS'"
check "defaults 提供数据目录（可重定向）" "grep -qE '^etcd_data_dir:' '$DEFAULTS'"
check "defaults 提供集群 token" "grep -qE '^etcd_cluster_token:' '$DEFAULTS'"
check "defaults 提供 TLS 开关（默认 true）" "grep -qE '^etcd_tls_enabled:[[:space:]]*true' '$DEFAULTS'"
check "defaults 提供 TLS 证书路径（CA/server/peer）" \
  "grep -qE '^etcd_ca_file:' '$DEFAULTS' && grep -qE '^etcd_cert_file:' '$DEFAULTS' && \
   grep -qE '^etcd_key_file:' '$DEFAULTS' && grep -qE '^etcd_peer_cert_file:' '$DEFAULTS' && \
   grep -qE '^etcd_peer_key_file:' '$DEFAULTS'"
check "defaults 提供 unit 目录（可重定向）" "grep -qE '^etcd_unit_dir:' '$DEFAULTS'"
check "defaults 提供服务管理开关" "grep -qE '^etcd_manage_service:' '$DEFAULTS'"
check "tasks 中无硬编码成员名" "! grep -rqE 'etcd1|etcd2|etcd3' $ROLE/tasks/"
check "tasks 中无硬编码 IPv4" "! grep -rqE '([0-9]{1,3}\\.){3}[0-9]{1,3}' $ROLE/tasks/"
check "tasks 中无硬编码 2379/2380" "! grep -rqE '(^|[^0-9])(2379|2380)([^0-9]|$)' $ROLE/tasks/"
check "tasks 中无硬编码 /etc/systemd/system" "! grep -rq '/etc/systemd/system' $ROLE/tasks/"
check "tasks 中无硬编码下载 URL" "! grep -rqE 'https?://' $ROLE/tasks/"
check "role 使用 FQCN ansible.builtin" "grep -rq 'ansible\\.builtin\\.' $ROLE/tasks/"
check "unit 模板由变量渲染 flags" "grep -q 'etcd_exec_args' $ROLE/templates/etcd.service.j2"
check "unit 模板含 Restart=always" "grep -q '^Restart=always' $ROLE/templates/etcd.service.j2"
check "unit 模板含 LimitNOFILE" "grep -q '^LimitNOFILE=' $ROLE/templates/etcd.service.j2"
check "unit 模板含 WantedBy=multi-user.target" "grep -q '^WantedBy=multi-user.target' $ROLE/templates/etcd.service.j2"
check "unit 模板无硬编码端口" "! grep -qE '2379|2380' $ROLE/templates/etcd.service.j2"

echo "-- A22 范围约束（不接入 site.yml；不改已验收资产）"
check "playbooks/site.yml 未引用 etcd" "! grep -q 'etcd' playbooks/site.yml"
if git rev-parse --git-dir >/dev/null 2>&1; then
  dirty="$(git status --porcelain -- tests/skeleton tests/base tests/download tests/pki roles/base roles/download roles/pki | wc -l)"
  check "tests/{skeleton,base,download,pki}、roles/{base,download,pki} 未被改动" "[[ $dirty -eq 0 ]]"
  check "工作区无未忽略的密钥/证书" "! git status --porcelain | grep -qE '\\.(key|crt|pem)$'"
fi

echo "-- A20 语法与风格"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY" >/tmp/opencode/t005_syntax.log 2>&1; then
    ok "$PLAY --syntax-check 通过"
  else
    bad "$PLAY --syntax-check 失败（见 /tmp/opencode/t005_syntax.log）"
  fi
else
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi
if command -v "$YAMLLINT" >/dev/null 2>&1; then
  if "$YAMLLINT" -c .yamllint "$ROLE" tests/etcd >/tmp/opencode/t005_yamllint.log 2>&1; then
    ok "yamllint（roles/etcd, tests/etcd）无 error"
  else
    bad "yamllint 失败（见 /tmp/opencode/t005_yamllint.log）"
  fi
else
  bad "找不到 yamllint"
fi

# ---------------------------------------------------------------------------
if ! have_ansible; then
  bad "找不到 ansible-playbook（跳过全部动态用例）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi

# 红阶段：role 尚不存在时不做 90s 的健康等待，直接记录并失败（TDD 证据仍完整）
if [[ ! -d "$ROLE" ]]; then
  bad "roles/etcd 不存在：结构/变量/动态用例均无法执行（红阶段）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi

# 首次运行把官方 tarball 缓存到 /tmp/opencode（之后全离线）
ensure_artifact() {
  local p="$CACHE/$ETCD_TARBALL"
  if [[ -f "$p" && "$(sha_of "$p")" == "$ETCD_SHA" ]]; then return 0; fi
  printf '  （首次运行：缓存 etcd 官方制品 %s）\n' "$ETCD_TARBALL"
  curl -fL --retry 3 --connect-timeout 15 -o "$p.tmp" "$ETCD_URL" || return 1
  mv "$p.tmp" "$p"
  [[ "$(sha_of "$p")" == "$ETCD_SHA" ]]
}
if ! ensure_artifact; then
  bad "无法获取/校验 etcd 官方制品（$ETCD_URL）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi
ok "etcd 官方制品缓存可用（sha256 与 defaults 一致）"

# 宿主零污染快照（A21）
PRE_UNITS="$(find /etc/systemd/system -maxdepth 1 -type f -name 'etcd*.service' -printf '%f\n' 2>/dev/null | sort)"
PRE_VARLIB="$(snapshot_path /var/lib/etcd)"
PRE_ETCD_BIN="$(snapshot_path /usr/local/bin/etcd)"
PRE_ETCDCTL_BIN="$(snapshot_path /usr/local/bin/etcdctl)"

declare -A PID=()
SB=""; SB2=""; SB3=""; SB4=""

stop_all() {
  local n i alive
  for n in "${!PID[@]}"; do kill "${PID[$n]}" 2>/dev/null || true; done
  for ((i = 0; i < 20; i++)); do
    alive=0
    for n in "${!PID[@]}"; do kill -0 "${PID[$n]}" 2>/dev/null && alive=1; done
    [[ $alive -eq 0 ]] && break
    sleep 0.5
  done
  for n in "${!PID[@]}"; do kill -9 "${PID[$n]}" 2>/dev/null || true; done
  for n in "${!PID[@]}"; do wait "${PID[$n]}" 2>/dev/null || true; done
  PID=()
}

cleanup() {
  local p
  stop_all 2>/dev/null || true
  # 仅在沙箱路径非空时按路径回收，避免 SB 为空时 pgrep 匹配到宿主 etcd 误杀
  if [[ -n "${SB:-}" ]]; then
    for p in $(pgrep -f "$SB/usr/local/bin/etcd" 2>/dev/null); do kill -9 "$p" 2>/dev/null || true; done
  fi
  if [[ -n "${SB2:-}" ]]; then
    for p in $(pgrep -f "$SB2/usr/local/bin/etcd" 2>/dev/null); do kill -9 "$p" 2>/dev/null || true; done
  fi
  if [[ ${fail:-0} -ne 0 && -n "${SB:-}" ]]; then
    local f
    for f in "$SB"/logs/*.log; do
      [[ -f "$f" ]] && cp -f "$f" "/tmp/opencode/t005_$(basename "$f")" 2>/dev/null || true
    done
  fi
  rm -rf "${SB:-}" "${SB2:-}" "${SB3:-}" "${SB4:-}"
}
trap cleanup EXIT

# 多 play / serial 会产生多条 PLAY RECAP；汇总全部 changed 才是本次运行的真实变更数
changed_of() { grep -oE 'changed=[0-9]+' "$1" 2>/dev/null | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
unit_path() { printf '%s/etc/systemd/system/etcd-%s.service' "$1" "$2"; }
unit_manifest() { local n; for n in etcd1 etcd2 etcd3; do sha256sum "$(unit_path "$1" "$n")" 2>/dev/null; done; }
seed_artifacts() {
  mkdir -p "$1/opt/k8s/artifacts"
  cp "$CACHE/$ETCD_TARBALL" "$1/opt/k8s/artifacts/$ETCD_TARBALL"
}
ap() {  # ap <inventory> <log> [额外参数...]
  local inv="$1" log="$2"
  shift 2
  "$ANSIBLE_PLAYBOOK" -i "$inv" "$PLAY" "$@" >"$log" 2>&1
}
port_free() {
  ! ss -ltn 2>/dev/null | grep -qE ":(12379|22379|32379|12380|22380|32380)[[:space:]]"
}
wait_ports_free() {
  local i
  for ((i = 0; i < 60; i++)); do port_free && return 0; sleep 0.5; done
  return 1
}

SB="$(mktemp -d /tmp/opencode/t005.XXXXXX)"
seed_artifacts "$SB"
mkdir -p "$SB/logs"

echo "-- A2 首跑：真实安装二进制 + 渲染 3 份 unit（沙箱）"
if ap "$INV" /tmp/opencode/t005_run1.log -e "{\"sandbox_root\":\"$SB\"}"; then
  ok "首跑 exit 0"
else
  bad "首跑失败（见 /tmp/opencode/t005_run1.log）"
fi
C1="$(changed_of /tmp/opencode/t005_run1.log)"
check "首跑 changed>0（真实安装/渲染）" "[[ ${C1:-0} -gt 0 ]]"
check "etcd 二进制已安装且可执行" "[[ -x '$SB/usr/local/bin/etcd' ]]"
check "etcdctl 二进制已安装且可执行" "[[ -x '$SB/usr/local/bin/etcdctl' ]]"
check "etcd 版本 = ${ETCD_VERSION}" "'$SB/usr/local/bin/etcd' --version 2>/dev/null | grep -q 'etcd Version: ${ETCD_VERSION}'"
check "etcdctl 版本 = ${ETCD_VERSION}" "'$SB/usr/local/bin/etcdctl' version 2>/dev/null | grep -q 'etcdctl version: ${ETCD_VERSION}'"
check "etcd 二进制权限 0755" "[[ \$(stat -c '%a' '$SB/usr/local/bin/etcd' 2>/dev/null) == 755 ]]"

U1="$(unit_path "$SB" etcd1)"
U2="$(unit_path "$SB" etcd2)"
U3="$(unit_path "$SB" etcd3)"
for n in etcd1 etcd2 etcd3; do
  U="$(unit_path "$SB" "$n")"
  check "存在 unit $n" "[[ -f '$U' ]]"
  check "unit $n 权限 0644" "[[ \$(stat -c '%a' '$U' 2>/dev/null) == 644 ]]"
done

echo "-- A3/A4 unit 内容（成员/端口/数据目录/集群/重启策略）"
check "A4 unit etcd1 --name 来自 inventory" "grep -q -- '--name=etcd1' '$U1'"
check "A4 unit etcd2 --name 来自 inventory" "grep -q -- '--name=etcd2' '$U2'"
check "A4 unit etcd3 --name 来自 inventory" "grep -q -- '--name=etcd3' '$U3'"
check "A4 etcd1 client URL（高位端口）" "grep -q -- '--listen-client-urls=https://127.0.0.1:12379' '$U1'"
check "A4 etcd2 client URL（高位端口）" "grep -q -- '--listen-client-urls=https://127.0.0.1:22379' '$U2'"
check "A4 etcd1 peer URL（高位端口）" "grep -q -- '--listen-peer-urls=https://127.0.0.1:12380' '$U1'"
check "A4 initial-advertise-peer-urls 正确" "grep -q -- '--initial-advertise-peer-urls=https://127.0.0.1:12380' '$U1'"
check "A4 initial-cluster 恰为 3 成员" \
  "grep -q -- '--initial-cluster=etcd1=https://127.0.0.1:12380,etcd2=https://127.0.0.1:22380,etcd3=https://127.0.0.1:32380' '$U1'"
check "A4 集群 token 来自变量" "grep -q -- '--initial-cluster-token=k8s-etcd-cluster' '$U1'"
check "A4 数据目录按成员隔离（etcd1）" "grep -q -- '--data-dir=$SB/var/lib/etcd/etcd1' '$U1'"
check "A4 数据目录按成员隔离（etcd2）" "grep -q -- '--data-dir=$SB/var/lib/etcd/etcd2' '$U2'"
check "A4 数据目录按成员隔离（etcd3）" "grep -q -- '--data-dir=$SB/var/lib/etcd/etcd3' '$U3'"
check "A4 数据目录已创建且 0700" \
  "[[ -d '$SB/var/lib/etcd/etcd1' && \$(stat -c '%a' '$SB/var/lib/etcd/etcd1') == 700 ]]"
check "A4 unit 含 Restart=always" "grep -q '^Restart=always' '$U1'"
check "A4 unit 含 RestartSec" "grep -q '^RestartSec=' '$U1'"
check "A4 unit 含 LimitNOFILE" "grep -q '^LimitNOFILE=' '$U1'"
check "A4 unit 含 User=etcd" "grep -q '^User=etcd' '$U1'"
check "A4 unit 含 Type=notify" "grep -q '^Type=notify' '$U1'"
check "A4 unit 含 WantedBy=multi-user.target" "grep -q '^WantedBy=multi-user.target' '$U1'"

echo "-- A5 TLS 默认开启（真实 pki 证书 + 双向认证 flag）"
PKI="$SB/etc/kubernetes/pki/etcd"
check "A5 pki 产出 etcd CA" "[[ -f '$PKI/ca.crt' ]]"
check "A5 pki 产出 server 证书/私钥" "[[ -f '$PKI/server.crt' && -f '$PKI/server.key' ]]"
check "A5 pki 产出 peer 证书/私钥" "[[ -f '$PKI/peer.crt' && -f '$PKI/peer.key' ]]"
check "A5 pki 产出 apiserver-etcd-client 证书" "[[ -f '$SB/etc/kubernetes/pki/apiserver-etcd-client.crt' ]]"
check "A5 unit 含 --cert-file/--key-file" \
  "grep -q -- '--cert-file=$PKI/server.crt' '$U1' && grep -q -- '--key-file=$PKI/server.key' '$U1'"
check "A5 unit 含 --trusted-ca-file" "grep -q -- '--trusted-ca-file=$PKI/ca.crt' '$U1'"
check "A5 unit 含 --client-cert-auth" "grep -q -- '--client-cert-auth' '$U1'"
check "A5 unit 含 peer cert/CA" \
  "grep -q -- '--peer-cert-file=$PKI/peer.crt' '$U1' && grep -q -- '--peer-key-file=$PKI/peer.key' '$U1' && \
   grep -q -- '--peer-trusted-ca-file=$PKI/ca.crt' '$U1'"
check "A5 unit 含 --peer-client-cert-auth" "grep -q -- '--peer-client-cert-auth' '$U1'"

echo "-- A14 幂等：同参数第二次 changed=0 且 unit/二进制不变"
BIN_HASH="$(sha_of "$SB/usr/local/bin/etcd")"
UNIT_HASH="$(unit_manifest "$SB")"
if ap "$INV" /tmp/opencode/t005_run2.log -e "{\"sandbox_root\":\"$SB\"}"; then
  c="$(changed_of /tmp/opencode/t005_run2.log)"
  check "A14 第二次执行 changed=0（幂等）" "[[ '${c:-x}' == '0' ]]"
else
  bad "A14 第二次执行失败（见 /tmp/opencode/t005_run2.log）"
fi
check "A14 unit 内容逐一不变" "[[ \"\$(unit_manifest '$SB')\" == '$UNIT_HASH' ]]"
check "A14 etcd 二进制 sha256 不变" "[[ \"\$(sha_of '$SB/usr/local/bin/etcd')\" == '$BIN_HASH' ]]"

echo "-- A17 离线缓存命中：URL 不可达仍成功且 changed=0"
if ap "$INV" /tmp/opencode/t005_cache.log \
  -e "{\"sandbox_root\":\"$SB\",\"etcd_download_url\":\"http://127.0.0.1:1/$ETCD_TARBALL\"}"; then
  c="$(changed_of /tmp/opencode/t005_cache.log)"
  check "A17 缓存命中（未重新下载）changed=0" "[[ '${c:-x}' == '0' ]]"
else
  bad "A17 已有合格制品但 URL 不可达时失败（缓存未生效，见 /tmp/opencode/t005_cache.log）"
fi
check "A17 离线运行后 unit 不变" "[[ \"\$(unit_manifest '$SB')\" == '$UNIT_HASH' ]]"

# ---------------------------------------------------------------------------
echo "-- 启动真实 TLS 3 成员集群（从渲染出的 unit ExecStart 拉起）"
ETCDCTL="$SB/usr/local/bin/etcdctl"
EP1=https://127.0.0.1:12379
EP2=https://127.0.0.1:22379
EP3=https://127.0.0.1:32379
EPS="$EP1,$EP2,$EP3"
TLS_ARGS=(--cacert "$PKI/ca.crt" --cert "$SB/etc/kubernetes/pki/apiserver-etcd-client.crt" --key "$SB/etc/kubernetes/pki/apiserver-etcd-client.key")

etcdctl_one() {
  local ep="$1"
  shift
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ep" --dial-timeout=1s --command-timeout=2s "${TLS_ARGS[@]}" "$@"
}
etcdctl_all() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$EPS" --dial-timeout=1s --command-timeout=2s "${TLS_ARGS[@]}" "$@"
}
healthy_count() {
  local n=0 ep
  for ep in "$EP1" "$EP2" "$EP3"; do etcdctl_one "$ep" endpoint health >/dev/null 2>&1 && n=$((n + 1)); done
  echo "$n"
}
wait_healthy() {
  local want="${1:-3}" timeout="${2:-60}" i
  for ((i = 0; i < timeout * 2; i++)); do
    [[ "$(healthy_count)" -eq "$want" ]] && return 0
    sleep 0.5
  done
  return 1
}
member_count() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$1" --dial-timeout=1s --command-timeout=2s "${TLS_ARGS[@]}" member list -w json 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["members"]))' 2>/dev/null
}
member_names() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$1" --dial-timeout=1s --command-timeout=2s "${TLS_ARGS[@]}" member list -w json 2>/dev/null \
    | python3 -c 'import json,sys; print(" ".join(sorted(m["name"] for m in json.load(sys.stdin)["members"])))' 2>/dev/null
}
leader_ok() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$EPS" --dial-timeout=1s --command-timeout=2s "${TLS_ARGS[@]}" endpoint status -w json 2>/dev/null \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if len(data) != 3:
    sys.exit(1)
leaders = {str(e["Status"]["leader"]) for e in data}
ids = {str(e["Status"]["header"]["member_id"]) for e in data}
sys.exit(0 if len(leaders) == 1 and leaders <= ids else 1)
'
}
retry_put() {
  local k="$1" v="$2" i
  for ((i = 0; i < 30; i++)); do
    etcdctl_one "$EP1" put "$k" "$v" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
start_member() {
  local n="$1" sb="$2" unit
  local -a _args=()
  unit="$(unit_path "$sb" "$n")"
  mapfile -t _args < <(python3 "$UNIT_EXEC" "$unit")
  [[ ${#_args[@]} -gt 0 ]] || return 1
  mkdir -p "$sb/logs"
  "${_args[@]}" >>"$sb/logs/$n.log" 2>&1 &
  PID[$n]=$!
}

for n in etcd1 etcd2 etcd3; do
  if start_member "$n" "$SB"; then ok "已从 unit 启动 $n（PID ${PID[$n]}）"; else bad "无法解析/启动 $n 的 ExecStart"; fi
done
check "A6 3 成员 endpoint 全部 healthy" "wait_healthy 3 90"
check "A6 endpoint health --cluster 输出 3 条 healthy" \
  "[[ \$(etcdctl_all endpoint health --cluster 2>/dev/null | grep -c 'is healthy') -eq 3 ]]"
check "A7 member list = 3" "[[ \$(member_count '$EP1') == 3 ]]"
check "A7 成员名为 etcd1/etcd2/etcd3" "[[ \"\$(member_names '$EP1')\" == 'etcd1 etcd2 etcd3' ]]"
check "A8 leader 唯一且属于成员集" "leader_ok"
check "A9 集群可写（put）" "retry_put 't005:key' 'before-fault'"
check "A9 集群可读（get 值一致）" \
  "[[ \"\$(etcdctl_one '$EP1' get 't005:key' --print-value-only 2>/dev/null)\" == 'before-fault' ]]"

echo "-- A15 已运行集群：配置未变重跑 role 不得改动/重启"
PIDS_BEFORE="$(for n in etcd1 etcd2 etcd3; do printf '%s ' "${PID[$n]:-0}"; done)"
if ap "$INV" /tmp/opencode/t005_run_while_up.log -e "{\"sandbox_root\":\"$SB\"}"; then
  c="$(changed_of /tmp/opencode/t005_run_while_up.log)"
  check "A15 运行中重跑 changed=0" "[[ '${c:-x}' == '0' ]]"
else
  bad "A15 运行中重跑失败（见 /tmp/opencode/t005_run_while_up.log）"
fi
PIDS_AFTER="$(for n in etcd1 etcd2 etcd3; do printf '%s ' "${PID[$n]:-0}"; done)"
check "A15 未通知重启 handler" "! grep -q 'RUNNING HANDLER' /tmp/opencode/t005_run_while_up.log"
check "A15 进程 PID 未变（未被重启）" "[[ '$PIDS_AFTER' == '$PIDS_BEFORE' ]]"
check "A15 集群仍 healthy" "[[ \$(healthy_count) -eq 3 ]]"

echo "-- A10 故障：kill -9 etcd2 → 2/3 仍有 quorum"
VICTIM=etcd2
KILLED_PID="${PID[$VICTIM]:-0}"
if [[ "$KILLED_PID" -gt 0 ]]; then
  kill -9 "$KILLED_PID" 2>/dev/null || true
  wait "$KILLED_PID" 2>/dev/null || true
fi
check "A10 被 kill 成员进程已退出" "[[ '$KILLED_PID' -gt 0 ]] && ! kill -0 '$KILLED_PID' 2>/dev/null"
check "A10 剩余 2/3 仍可写（quorum 存活）" "retry_put 't005:fault' 'after-kill'"
check "A10 member list 仍为 3（成员注册未丢）" "[[ \$(member_count '$EP1') == 3 ]]"

echo "-- A11 重启该成员 → 集群恢复 healthy"
if start_member "$VICTIM" "$SB"; then ok "已重新拉起 $VICTIM（PID ${PID[$VICTIM]}）"; else bad "无法重新拉起 $VICTIM"; fi
NEW_PID="${PID[$VICTIM]:-0}"
check "A11 重启后 3 端点恢复 healthy" "wait_healthy 3 90"
check "A11 原 key 仍可读（数据持久化）" \
  "[[ \"\$(etcdctl_one '$EP1' get 't005:key' --print-value-only 2>/dev/null)\" == 'before-fault' ]]"
check "A11 故障期间写入的 key 可读" \
  "[[ \"\$(etcdctl_one '$EP1' get 't005:fault' --print-value-only 2>/dev/null)\" == 'after-kill' ]]"
check "A11 leader 仍唯一" "leader_ok"
check "A11 进程 PID 已变化（确实重启）" "[[ '$NEW_PID' -gt 0 && '$NEW_PID' -ne '$KILLED_PID' ]]"

echo "-- 停止集群（端口释放）"
stop_all
check "TLS 集群停止后高位端口释放" "wait_ports_free"

echo "-- A16 配置变更才触发重启 handler"
UH1="$(sha_of "$U1")"
if ap "$INV" /tmp/opencode/t005_cfg_change.log \
  -e "{\"sandbox_root\":\"$SB\",\"etcd_heartbeat_interval\":150}"; then
  ok "A16 配置变更重跑 exit 0"
else
  bad "A16 配置变更重跑失败（见 /tmp/opencode/t005_cfg_change.log）"
fi
c="$(changed_of /tmp/opencode/t005_cfg_change.log)"
check "A16 配置变更 changed>=1" "[[ ${c:-0} -ge 1 ]]"
check "A16 unit 内容确实变化" "[[ \"\$(sha_of '$U1')\" != '$UH1' ]]"
check "A16 unit 含新 heartbeat-interval" "grep -q -- '--heartbeat-interval=150' '$U1'"
check "A16 通知了重启 handler（受限：systemd 动作被 skip）" \
  "grep -q 'RUNNING HANDLER' /tmp/opencode/t005_cfg_change.log && grep -q 'etcd:restart' /tmp/opencode/t005_cfg_change.log"
if ap "$INV" /tmp/opencode/t005_cfg_same.log \
  -e "{\"sandbox_root\":\"$SB\",\"etcd_heartbeat_interval\":150}"; then
  c="$(changed_of /tmp/opencode/t005_cfg_same.log)"
  check "A16 同配置再跑 changed=0" "[[ '${c:-x}' == '0' ]]"
  check "A16 同配置再跑不通知 handler" "! grep -q 'RUNNING HANDLER' /tmp/opencode/t005_cfg_same.log"
else
  bad "A16 同配置再跑失败（见 /tmp/opencode/t005_cfg_same.log）"
fi

# ---------------------------------------------------------------------------
echo "-- A18 TLS 可关闭：渲染 + 真实 3 成员 HTTP 集群"
SB2="$(mktemp -d /tmp/opencode/t005tls.XXXXXX)"
seed_artifacts "$SB2"
cat >"$SB2/vars.json" <<EOF
{"sandbox_root": "$SB2", "etcd_tls_enabled": false}
EOF
if "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" -e "@$SB2/vars.json" >/tmp/opencode/t005_tls_off.log 2>&1; then
  ok "A18 TLS off 首跑 exit 0"
else
  bad "A18 TLS off 首跑失败（见 /tmp/opencode/t005_tls_off.log）"
fi
U1B="$(unit_path "$SB2" etcd1)"
check "A18 TLS off unit 无 --cert-file" "! grep -q -- '--cert-file' '$U1B'"
check "A18 TLS off unit 无 --client-cert-auth" "! grep -q -- '--client-cert-auth' '$U1B'"
check "A18 TLS off unit 无 --peer-cert-file" "! grep -q -- '--peer-cert-file' '$U1B'"
check "A18 TLS off client URL 为 http" "grep -q -- '--listen-client-urls=http://127.0.0.1:12379' '$U1B'"
check "A18 TLS off peer URL 为 http" "grep -q -- '--listen-peer-urls=http://127.0.0.1:12380' '$U1B'"
check "A18 TLS off 未生成 pki etcd 证书" "[[ ! -e '$SB2/etc/kubernetes/pki/etcd/ca.crt' ]]"

ETCDCTL="$SB2/usr/local/bin/etcdctl"
TLS_ARGS=()
EP1=http://127.0.0.1:12379
EP2=http://127.0.0.1:22379
EP3=http://127.0.0.1:32379
EPS="$EP1,$EP2,$EP3"
for n in etcd1 etcd2 etcd3; do
  if start_member "$n" "$SB2"; then
    ok "A18 已从 unit 启动 $n（TLS off，PID ${PID[$n]}）"
  else
    bad "A18 无法从 unit 启动 $n（TLS off）"
  fi
done
check "A18 TLS off 3 成员 healthy" "wait_healthy 3 60"
check "A18 TLS off member list = 3" "[[ \$(member_count '$EP1') == 3 ]]"
stop_all
check "A18 TLS off 集群停止后端口释放" "wait_ports_free"

# ---------------------------------------------------------------------------
echo "-- A12 偶数成员 fail-fast"
SB3="$(mktemp -d /tmp/opencode/t005even.XXXXXX)"
cat >"$SB3/vars.json" <<EOF
{"sandbox_root": "$SB3", "etcd_tls_enabled": false}
EOF
rc=0
"$ANSIBLE_PLAYBOOK" -i "$INV_EVEN" "$PLAY" -e "@$SB3/vars.json" >/tmp/opencode/t005_even.log 2>&1 || rc=$?
check "A12 偶数成员 role 失败（exit≠0）" "[[ $rc -ne 0 ]]"
check "A12 报错明确提及「奇数」" "grep -q '奇数' /tmp/opencode/t005_even.log"
check "A12 报错给出当前成员数 2" "grep -qE '(当前|成员数)[^0-9]*2|（2）|2 个' /tmp/opencode/t005_even.log"
check "A12 未渲染任何 unit" "! ls '$SB3'/etc/systemd/system/etcd*.service 2>/dev/null"
check "A12 未创建数据目录" "[[ ! -e '$SB3/var/lib/etcd' ]]"

echo "-- A13 TLS 证书缺失 fail-fast"
SB4="$(mktemp -d /tmp/opencode/t005nocert.XXXXXX)"
cat >"$SB4/vars.json" <<EOF
{
  "sandbox_root": "$SB4",
  "etcd_tls_enabled": true,
  "etcd_ca_file": "$SB4/missing/ca.crt",
  "etcd_cert_file": "$SB4/missing/server.crt",
  "etcd_key_file": "$SB4/missing/server.key",
  "etcd_peer_cert_file": "$SB4/missing/peer.crt",
  "etcd_peer_key_file": "$SB4/missing/peer.key"
}
EOF
rc=0
"$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" -e "@$SB4/vars.json" >/tmp/opencode/t005_nocert.log 2>&1 || rc=$?
check "A13 TLS 证书缺失 role 失败（exit≠0）" "[[ $rc -ne 0 ]]"
check "A13 报错明确提及证书" "grep -q '证书' /tmp/opencode/t005_nocert.log"
check "A13 未渲染任何 unit" "! ls '$SB4'/etc/systemd/system/etcd*.service 2>/dev/null"

# ---------------------------------------------------------------------------
echo "-- A21 宿主零污染 / 无残留"
POST_UNITS="$(find /etc/systemd/system -maxdepth 1 -type f -name 'etcd*.service' -printf '%f\n' 2>/dev/null | sort)"
check "宿主 /etc/systemd/system 的 etcd 单元清单未变化/未新增" "[[ '$PRE_UNITS' == '$POST_UNITS' ]]"
check "宿主 /var/lib/etcd 未创建/未改动" "[[ \"\$(snapshot_path /var/lib/etcd)\" == '$PRE_VARLIB' ]]"
check "宿主 /usr/local/bin/etcd 未创建/未改动" "[[ \"\$(snapshot_path /usr/local/bin/etcd)\" == '$PRE_ETCD_BIN' ]]"
check "宿主 /usr/local/bin/etcdctl 未创建/未改动" "[[ \"\$(snapshot_path /usr/local/bin/etcdctl)\" == '$PRE_ETCDCTL_BIN' ]]"
check "无残留 etcd 进程（沙箱路径）" "! pgrep -f '$SB/usr/local/bin/etcd' >/dev/null 2>&1"
check "无残留 etcd 进程（TLS off 沙箱）" "! pgrep -f '$SB2/usr/local/bin/etcd' >/dev/null 2>&1"
check "高位端口全部释放" "port_free"

# 显式清理并断言（trap 仍会兜底）
stop_all
rm -rf "$SB" "$SB2" "$SB3" "$SB4"
check "沙箱临时目录已清理" "[[ ! -e '$SB' && ! -e '$SB2' && ! -e '$SB3' && ! -e '$SB4' ]]"
SB=""; SB2=""; SB3=""; SB4=""

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
