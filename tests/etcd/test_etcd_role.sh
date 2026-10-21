#!/usr/bin/env bash
# =============================================================================
# T005 etcd 集群 role（etcd）验收测试（TDD：先红后绿）
#  策略：真实启动**单机 3 实例** etcd 集群（高位端口，独立 data-dir / unit / 端口），
#        且**以非 root 服务用户（uid 65534）真实启动**，验证生产权限模型：
#          - 系统目录/unit/二进制 root:root（服务用户不得拥有）；
#          - 数据目录 <服务用户>:<组> 0700；
#          - 证书分发目录 root:<服务组> 0750、私钥 0640、证书 0644。
#        用真实 etcdctl 断言 endpoint health / member list / leader / 读写 / kill→恢复；
#        配置变更时验证**逐个重启 + 每个成员等 health + quorum 保护**。
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

# --- 测试用非 root 服务身份（真实存在：nobody/nogroup）-----------------------
ETCD_UID="${ETCD_TEST_UID:-65534}"
ETCD_GID="${ETCD_TEST_GID:-65534}"

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
INV_EVEN4=tests/etcd/inventory_even4.ini
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
owner_mode() { stat -c '%u:%g %a' "$1" 2>/dev/null || printf '__MISSING__'; }
# 沙箱内 0700/0750 的属主断言需 root 观察（被测权限模型本身不允许普通用户进入）
r_owner_mode() { sudo -n stat -c '%u:%g %a' "$1" 2>/dev/null || printf '__MISSING__'; }
r_file() { sudo -n test -f "$1"; }
proc_starttime() { awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/${1}/stat" 2>/dev/null; }

echo "== T005 etcd role 验收 =="

echo "-- A1 role / 测试资产结构"
for f in "$ROLE/defaults/main.yml" "$ROLE/tasks/main.yml" "$ROLE/tasks/facts.yml" \
  "$ROLE/tasks/validate.yml" "$ROLE/tasks/binary.yml" "$ROLE/tasks/certs.yml" \
  "$ROLE/tasks/config.yml" "$ROLE/tasks/service.yml" "$ROLE/tasks/rolling_restart.yml" \
  "$ROLE/tasks/wait_member_healthy.yml" "$ROLE/handlers/main.yml" "$ROLE/meta/main.yml" \
  "$ROLE/templates/etcd.service.j2" "$ROLE/README.md"; do
  check "存在 $f" "[[ -f '$f' ]]"
done
for f in "$PLAY" "$INV" "$INV_EVEN" "$INV_EVEN4" "$UNIT_EXEC"; do
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
check "defaults 默认服务用户为 etcd（生产）" "grep -qE '^etcd_user:[[:space:]]*etcd' '$DEFAULTS'"
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

echo "-- B1/B2 权限模型（静态：属主拆分 / 证书分发 / 滚动重启）"
check "B1 defaults 提供证书分发目录" "grep -qE '^etcd_pki_share_dir:' '$DEFAULTS'"
check "B1 私钥模式 0640（组可读、无 world 权限）" "grep -qE '^etcd_cert_key_mode:[[:space:]]*\"0640\"' '$DEFAULTS'"
check "B1 证书分发目录 0750" "grep -qE '^etcd_cert_dir_mode:[[:space:]]*\"0750\"' '$DEFAULTS'"
check "B1 证书属主 root + 服务组" \
  "grep -qE '^etcd_cert_owner:[[:space:]]*root' '$DEFAULTS' && grep -qE '^etcd_cert_group:' '$DEFAULTS'"
check "B1 执行参数使用分发目录（非 pki 源 0600 私钥）" \
  "grep -q 'etcd_runtime_key_file' '$ROLE/tasks/facts.yml' && grep -q 'etcd_runtime_peer_key_file' '$ROLE/tasks/facts.yml'"
check "B1 unit 模板含 SupplementaryGroups（组权限兜底）" \
  "grep -q 'SupplementaryGroups' $ROLE/templates/etcd.service.j2"
check "B2 defaults 区分 root / data / cert 属主" \
  "grep -qE '^etcd_root_owner:' '$DEFAULTS' && grep -qE '^etcd_data_owner:' '$DEFAULTS' && \
   grep -qE '^etcd_cert_owner:' '$DEFAULTS'"
check "B2 不再使用单一 etcd_file_owner 控制所有落盘属主" "! grep -rq 'etcd_file_owner' '$ROLE'"
check "B2 二进制/unit 目录使用 root 属主" \
  "grep -q 'etcd_root_owner' '$ROLE/tasks/binary.yml' && grep -q 'etcd_root_owner' '$ROLE/tasks/config.yml'"
check "B2 数据目录使用服务用户属主" "grep -q 'etcd_data_owner' '$ROLE/tasks/config.yml'"
check "D3 handler 调用滚动重启任务" "grep -q 'rolling_restart.yml' '$ROLE/handlers/main.yml'"
check "D3 重启任务 throttle=1（跨主机串行）" \
  "[[ \$(grep -c 'throttle: 1' '$ROLE/tasks/rolling_restart.yml') -ge 1 ]]"
check "D3 重启后等待本成员 healthy（until + retries）" \
  "grep -q 'until:' '$ROLE/tasks/wait_member_healthy.yml' && grep -q 'retries:' '$ROLE/tasks/wait_member_healthy.yml'"
check "D3 等待逻辑校验集群多数派（quorum）" \
  "grep -q 'etcd_quorum' '$ROLE/tasks/wait_member_healthy.yml'"

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

# 生产权限模型需要 root 应用属主 + 非 root 服务用户真实启动；无免密 sudo 则无法验证
if ! sudo -n true 2>/dev/null; then
  bad "需要免密 sudo：以 root 应用生产属主模型，并以非 root 服务用户（uid $ETCD_UID）启动 etcd"
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

# 宿主零污染快照（A21）：不只比较文件名，还比较属主/权限（B2：绝不能被 chown）
PRE_UNITS="$(find /etc/systemd/system -maxdepth 1 -type f -name 'etcd*.service' -printf '%f\n' 2>/dev/null | sort)"
PRE_VARLIB="$(snapshot_path /var/lib/etcd)"
PRE_ETCD_BIN="$(snapshot_path /usr/local/bin/etcd)"
PRE_ETCDCTL_BIN="$(snapshot_path /usr/local/bin/etcdctl)"
PRE_SYSD_OWNER="$(owner_mode /etc/systemd/system)"
PRE_BINDIR_OWNER="$(owner_mode /usr/local/bin)"

declare -A PID=()
declare -A WRAPPER=()
SB=""; SB2=""; SB3=""; SB4=""; SB5=""
SAMPLER_PID=""; SAMPLER_STOP=""

stop_sampler() {
  [[ -n "${SAMPLER_PID:-}" ]] || return 0
  [[ -n "${SAMPLER_STOP:-}" ]] && touch "$SAMPLER_STOP" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=""
}

stop_all() {
  local n i alive
  for n in "${!PID[@]}"; do sudo -n kill "${PID[$n]}" 2>/dev/null || true; done
  for ((i = 0; i < 40; i++)); do
    alive=0
    for n in "${!PID[@]}"; do sudo -n kill -0 "${PID[$n]}" 2>/dev/null && alive=1; done
    [[ $alive -eq 0 ]] && break
    sleep 0.25
  done
  for n in "${!PID[@]}"; do sudo -n kill -9 "${PID[$n]}" 2>/dev/null || true; done
  for n in "${!WRAPPER[@]}"; do
    sudo -n kill -9 "${WRAPPER[$n]}" 2>/dev/null || true
    wait "${WRAPPER[$n]}" 2>/dev/null || true
  done
  PID=()
  WRAPPER=()
}

cleanup() {
  local sb f
  stop_sampler 2>/dev/null || true
  stop_all 2>/dev/null || true
  for sb in "${SB:-}" "${SB2:-}" "${SB3:-}" "${SB4:-}" "${SB5:-}"; do
    [[ -n "$sb" ]] || continue
    sudo -n pkill -9 -f "$sb/usr/local/bin/etcd" 2>/dev/null || true
  done
  if [[ ${fail:-0} -ne 0 && -n "${SB:-}" ]]; then
    for f in "$SB"/logs/*.log; do
      [[ -f "$f" ]] && cp -f "$f" "/tmp/opencode/t005_$(basename "$f")" 2>/dev/null || true
    done
  fi
  for sb in "${SB:-}" "${SB2:-}" "${SB3:-}" "${SB4:-}" "${SB5:-}"; do
    [[ -n "$sb" ]] && sudo -n rm -rf "$sb" 2>/dev/null || true
  done
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
ap() {  # ap <inventory> <log> [额外参数...]（单次运行 600s 上限，避免卡死拖垮整个门禁）
  local inv="$1" log="$2"
  shift 2
  timeout 600 "$ANSIBLE_PLAYBOOK" -i "$inv" "$PLAY" "$@" >"$log" 2>&1
}
port_free() {
  ! ss -ltn 2>/dev/null | grep -qE ":(12379|22379|32379|42379|12380|22380|32380|42380)[[:space:]]"
}
wait_ports_free() {
  local i
  for ((i = 0; i < 60; i++)); do port_free && return 0; sleep 0.5; done
  return 1
}
etcd_version_ok() {
  local i
  for ((i = 0; i < 10; i++)); do
    "$SB/usr/local/bin/etcd" --version 2>/dev/null | grep -q "etcd Version: ${ETCD_VERSION}" && return 0
    sleep 0.3
  done
  return 1
}
etcdctl_version_ok() {
  local i
  for ((i = 0; i < 10; i++)); do
    "$SB/usr/local/bin/etcdctl" version 2>/dev/null | grep -q "etcdctl version: ${ETCD_VERSION}" && return 0
    sleep 0.3
  done
  return 1
}
# 以非 root 服务用户（uid/gid 65534）判断文件可读/可写（真实 setpriv 身份切换）
svc_readable() { sudo -n setpriv --reuid "$ETCD_UID" --regid "$ETCD_GID" --clear-groups test -r "$1"; }
svc_writable() { sudo -n setpriv --reuid "$ETCD_UID" --regid "$ETCD_GID" --clear-groups test -w "$1"; }

SB="$(mktemp -d /tmp/opencode/t005.XXXXXX)"
chmod 0755 "$SB"   # 允许非 root 服务用户遍历沙箱（生产为 0755 的 /）
seed_artifacts "$SB"
mkdir -p "$SB/logs"

echo "-- A2 首跑（root 应用生产属主模型）+ B2 系统文件属主"
if ap "$INV" /tmp/opencode/t005_run1.log -e "{\"sandbox_root\":\"$SB\"}"; then
  ok "首跑 exit 0"
else
  bad "首跑失败（见 /tmp/opencode/t005_run1.log）"
fi
sudo -n chmod 0755 "$SB/etc"   # pki 以 0700 创建沙箱中间目录；生产 /etc 为 0755（仅归一化父目录，不动 pki 叶子）
sudo -n chmod 0755 "$SB/var"   # pki 构建目录（/var/cache）在沙箱建出 0700 的 /var；生产 /var 为 0755
C1="$(changed_of /tmp/opencode/t005_run1.log)"
check "首跑 changed>0（真实安装/渲染）" "[[ ${C1:-0} -gt 0 ]]"
check "etcd 二进制已安装且可执行" "[[ -x '$SB/usr/local/bin/etcd' ]]"
check "etcd 版本 = ${ETCD_VERSION}" "etcd_version_ok"
check "etcdctl 版本 = ${ETCD_VERSION}" "etcdctl_version_ok"
for b in etcd etcdctl etcdutl; do
  check "B2/D7 二进制 $b 属主 root:root 0755" \
    "[[ \"\$(owner_mode '$SB/usr/local/bin/$b')\" == '0:0 755' ]]"
done
check "B2 二进制目录 /usr/local/bin 属主 root:root 0755" "[[ \"\$(owner_mode '$SB/usr/local/bin')\" == '0:0 755' ]]"
check "B2 systemd unit 目录属主 root:root 0755" \
  "[[ \"\$(owner_mode '$SB/etc/systemd/system')\" == '0:0 755' ]]"
check "B2 制品/解包目录属主 root:root" \
  "[[ \"\$(owner_mode '$SB/opt/k8s/artifacts')\" == '0:0 755' && \"\$(owner_mode '$SB/opt/k8s/etcd')\" == '0:0 755' ]]"

U1="$(unit_path "$SB" etcd1)"
U2="$(unit_path "$SB" etcd2)"
U3="$(unit_path "$SB" etcd3)"
for n in etcd1 etcd2 etcd3; do
  U="$(unit_path "$SB" "$n")"
  check "存在 unit $n" "[[ -f '$U' ]]"
  check "B2 unit $n 属主 root:root 0644（服务用户不可改写）" \
    "[[ \"\$(owner_mode '$U')\" == '0:0 644' ]]"
  check "B2 unit $n 对服务用户不可写" "! svc_writable '$U'"
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
for n in etcd1 etcd2 etcd3; do
  check "B2 数据目录 $n 属主 ${ETCD_UID}:${ETCD_GID} 0700" \
    "[[ \"\$(r_owner_mode '$SB/var/lib/etcd/$n')\" == '${ETCD_UID}:${ETCD_GID} 700' ]]"
  check "B1 服务用户可写数据目录 $n" "svc_writable '$SB/var/lib/etcd/$n'"
done
check "A4 unit 含 Restart=always" "grep -q '^Restart=always' '$U1'"
check "A4 unit 含 RestartSec" "grep -q '^RestartSec=' '$U1'"
check "A4 unit 含 LimitNOFILE" "grep -q '^LimitNOFILE=' '$U1'"
check "A4 unit 含 User=${ETCD_UID}（服务用户）" "grep -q '^User=${ETCD_UID}\$' '$U1'"
check "B1 unit 含 SupplementaryGroups=${ETCD_GID}" "grep -q '^SupplementaryGroups=${ETCD_GID}\$' '$U1'"
check "A4 unit 含 Type=notify" "grep -q '^Type=notify' '$U1'"
check "A4 unit 含 WantedBy=multi-user.target" "grep -q '^WantedBy=multi-user.target' '$U1'"

echo "-- A5 TLS 默认开启（真实 pki 证书 + 双向认证 flag）"
PKI="$SB/etc/kubernetes/pki/etcd"
SHARE="$SB/etc/etcd/pki"
check "A5 pki 产出 etcd CA" "r_file '$PKI/ca.crt'"
check "A5 pki 产出 server 证书/私钥" "r_file '$PKI/server.crt' && r_file '$PKI/server.key'"
check "A5 pki 产出 peer 证书/私钥" "r_file '$PKI/peer.crt' && r_file '$PKI/peer.key'"
check "A5 pki 产出 apiserver-etcd-client 证书" "r_file '$SB/etc/kubernetes/pki/apiserver-etcd-client.crt'"
check "A5 unit 含 --cert-file/--key-file（分发目录）" \
  "grep -q -- '--cert-file=$SHARE/server.crt' '$U1' && grep -q -- '--key-file=$SHARE/server.key' '$U1'"
check "A5 unit 含 --trusted-ca-file" "grep -q -- '--trusted-ca-file=$SHARE/ca.crt' '$U1'"
check "A5 unit 含 --client-cert-auth" "grep -q -- '--client-cert-auth' '$U1'"
check "A5 unit 含 peer cert/CA" \
  "grep -q -- '--peer-cert-file=$SHARE/peer.crt' '$U1' && grep -q -- '--peer-key-file=$SHARE/peer.key' '$U1' && \
   grep -q -- '--peer-trusted-ca-file=$SHARE/ca.crt' '$U1'"
check "A5 unit 含 --peer-client-cert-auth" "grep -q -- '--peer-client-cert-auth' '$U1'"

echo "-- B1 证书权限模型（root:<etcd 组> 0640 / 目录 0750；pki 源不被放宽）"
check "B1 证书分发目录属主 root:${ETCD_GID} 0750" "[[ \"\$(r_owner_mode '$SHARE')\" == '0:${ETCD_GID} 750' ]]"
check "B1 server.crt 属主 root:${ETCD_GID} 0644" "[[ \"\$(r_owner_mode '$SHARE/server.crt')\" == '0:${ETCD_GID} 644' ]]"
check "B1 peer.crt 属主 root:${ETCD_GID} 0644" "[[ \"\$(r_owner_mode '$SHARE/peer.crt')\" == '0:${ETCD_GID} 644' ]]"
check "B1 ca.crt 属主 root:${ETCD_GID} 0644" "[[ \"\$(r_owner_mode '$SHARE/ca.crt')\" == '0:${ETCD_GID} 644' ]]"
check "B1 server.key 属主 root:${ETCD_GID} 0640" "[[ \"\$(r_owner_mode '$SHARE/server.key')\" == '0:${ETCD_GID} 640' ]]"
check "B1 peer.key 属主 root:${ETCD_GID} 0640" "[[ \"\$(r_owner_mode '$SHARE/peer.key')\" == '0:${ETCD_GID} 640' ]]"
check "B1 服务用户可读 server.key（真实 uid 切换）" "svc_readable '$SHARE/server.key'"
check "B1 服务用户可读 peer.key（真实 uid 切换）" "svc_readable '$SHARE/peer.key'"
check "B1 pki 源私钥仍为 root:root 0600（未被放宽）" "[[ \"\$(r_owner_mode '$PKI/server.key')\" == '0:0 600' ]]"
check "B1 pki 源目录仍为 root:root 0700" "[[ \"\$(r_owner_mode '$PKI')\" == '0:0 700' ]]"
check "B1 pki 源私钥对服务用户不可读（不靠放宽源目录掩盖）" "! svc_readable '$PKI/server.key'"

# etcdctl 客户端证书（apiserver-etcd-client）由 root 签发且 0600，测试以当前用户复制一份 0600 使用
CLIENT="$SB/client"
sudo -n install -d -m 0700 -o "$(id -u)" -g "$(id -g)" "$CLIENT"
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/pki/apiserver-etcd-client.key" "$CLIENT/client.key"
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$PKI/ca.crt" "$CLIENT/ca.crt"
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/pki/apiserver-etcd-client.crt" "$CLIENT/client.crt"

echo "-- A14 幂等：同参数第二次 changed=0 且 unit/二进制不变"
BIN_HASH="$(sha_of "$SB/usr/local/bin/etcd")"
UNIT_HASH="$(unit_manifest "$SB")"
if ap "$INV" /tmp/opencode/t005_run2.log -e "{\"sandbox_root\":\"$SB\",\"pki_sandbox_enabled\":false}"; then
  c="$(changed_of /tmp/opencode/t005_run2.log)"
  check "A14 第二次执行 changed=0（幂等）" "[[ '${c:-x}' == '0' ]]"
else
  bad "A14 第二次执行失败（见 /tmp/opencode/t005_run2.log）"
fi
check "A14 unit 内容逐一不变" "[[ \"\$(unit_manifest '$SB')\" == '$UNIT_HASH' ]]"
check "A14 etcd 二进制 sha256 不变" "[[ \"\$(sha_of '$SB/usr/local/bin/etcd')\" == '$BIN_HASH' ]]"

echo "-- A17 离线缓存命中：URL 不可达仍成功且 changed=0"
if ap "$INV" /tmp/opencode/t005_cache.log \
  -e "{\"sandbox_root\":\"$SB\",\"etcd_download_url\":\"http://127.0.0.1:1/$ETCD_TARBALL\",\"pki_sandbox_enabled\":false}"; then
  c="$(changed_of /tmp/opencode/t005_cache.log)"
  check "A17 缓存命中（未重新下载）changed=0" "[[ '${c:-x}' == '0' ]]"
else
  bad "A17 已有合格制品但 URL 不可达时失败（缓存未生效，见 /tmp/opencode/t005_cache.log）"
fi
check "A17 离线运行后 unit 不变" "[[ \"\$(unit_manifest '$SB')\" == '$UNIT_HASH' ]]"

# ---------------------------------------------------------------------------
echo "-- 启动真实 TLS 3 成员集群（非 root 服务用户 uid=${ETCD_UID}，从 unit ExecStart 拉起）"
ETCDCTL="$SB/usr/local/bin/etcdctl"
EP1=https://127.0.0.1:12379
EP2=https://127.0.0.1:22379
EP3=https://127.0.0.1:32379
EPS="$EP1,$EP2,$EP3"
TLS_ARGS=(--cacert "$CLIENT/ca.crt" --cert "$CLIENT/client.crt" --key "$CLIENT/client.key")

etcdctl_one() {
  local ep="$1"
  shift
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ep" --dial-timeout=300ms --command-timeout=1s "${TLS_ARGS[@]}" "$@"
}
etcdctl_all() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$EPS" --dial-timeout=300ms --command-timeout=1s "${TLS_ARGS[@]}" "$@"
}
healthy_count() {
  local n=0 ep
  for ep in "$EP1" "$EP2" "$EP3"; do etcdctl_one "$ep" endpoint health >/dev/null 2>&1 && n=$((n + 1)); done
  echo "$n"
}
wait_healthy() {
  local want="${1:-3}" timeout="${2:-60}" i
  for ((i = 0; i < timeout; i++)); do
    [[ "$(healthy_count)" -eq "$want" ]] && return 0
    sleep 0.5
  done
  return 1
}
member_count() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$1" --dial-timeout=300ms --command-timeout=1s "${TLS_ARGS[@]}" member list -w json 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["members"]))' 2>/dev/null
}
member_names() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$1" --dial-timeout=300ms --command-timeout=1s "${TLS_ARGS[@]}" member list -w json 2>/dev/null \
    | python3 -c 'import json,sys; print(" ".join(sorted(m["name"] for m in json.load(sys.stdin)["members"])))' 2>/dev/null
}
leader_ok() {
  ETCDCTL_API=3 "$ETCDCTL" --endpoints="$EPS" --dial-timeout=300ms --command-timeout=1s "${TLS_ARGS[@]}" endpoint status -w json 2>/dev/null \
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
member_pid() {  # 以 uid + 完整命令前缀定位真实 etcd 进程（非 sudo 包装进程）
  pgrep -u "$ETCD_UID" -f -- "$2/usr/local/bin/etcd --name=$1 " 2>/dev/null | head -1
}
start_member() {
  local n="$1" sb="$2" unit i pid
  local -a _args=()
  unit="$(unit_path "$sb" "$n")"
  mapfile -t _args < <(python3 "$UNIT_EXEC" "$unit")
  [[ ${#_args[@]} -gt 0 ]] || return 1
  mkdir -p "$sb/logs"
  # 真实以非 root 服务用户启动（绕过 systemd 的受限；User= 与 unit 一致）
  sudo -n setpriv --reuid "$ETCD_UID" --regid "$ETCD_GID" --clear-groups \
    "${_args[@]}" </dev/null >>"$sb/logs/$n.log" 2>&1 &
  WRAPPER[$n]=$!
  for ((i = 0; i < 100; i++)); do
    pid="$(member_pid "$n" "$sb")"
    if [[ -n "$pid" ]]; then PID[$n]="$pid"; return 0; fi
    sleep 0.1
  done
  return 1
}

for n in etcd1 etcd2 etcd3; do
  if start_member "$n" "$SB"; then ok "已以 uid ${ETCD_UID} 从 unit 启动 $n（PID ${PID[$n]}）"; else bad "无法解析/启动 $n 的 ExecStart"; fi
done
for n in etcd1 etcd2 etcd3; do
  check "B1 $n 进程以非 root 服务用户运行（uid=${ETCD_UID}）" \
    "[[ \"\$(ps -o uid= -p '${PID[$n]:-0}' 2>/dev/null | tr -d ' ')\" == '$ETCD_UID' ]]"
done
check "A6 3 成员 endpoint 全部 healthy" "wait_healthy 3 60"
check "A6 endpoint health --cluster 输出 3 条 healthy" \
  "[[ \$(etcdctl_all endpoint health --cluster 2>/dev/null | grep -c 'is healthy') -eq 3 ]]"
check "A7 member list = 3" "[[ \$(member_count '$EP1') == 3 ]]"
check "A7 成员名为 etcd1/etcd2/etcd3" "[[ \"\$(member_names '$EP1')\" == 'etcd1 etcd2 etcd3' ]]"
check "A8 leader 唯一且属于成员集" "leader_ok"
check "A9 集群可写（put）" "retry_put 't005:key' 'before-fault'"
check "A9 集群可读（get 值一致）" \
  "[[ \"\$(etcdctl_one '$EP1' get 't005:key' --print-value-only 2>/dev/null)\" == 'before-fault' ]]"

echo "-- A15 已运行集群：配置未变重跑 role 不得改动/重启（/proc starttime 判据）"
declare -A ST_BEFORE=()
for n in etcd1 etcd2 etcd3; do
  ST_BEFORE[$n]="$(proc_starttime "${PID[$n]:-0}")"
done
PIDS_BEFORE="$(for n in etcd1 etcd2 etcd3; do printf '%s ' "${PID[$n]:-0}"; done)"
for n in etcd1 etcd2 etcd3; do
  check "D4 读取到 $n 的真实 /proc/<pid>/stat starttime" "[[ -n '${ST_BEFORE[$n]}' ]]"
done
if ap "$INV" /tmp/opencode/t005_run_while_up.log -e "{\"sandbox_root\":\"$SB\",\"pki_sandbox_enabled\":false}"; then
  c="$(changed_of /tmp/opencode/t005_run_while_up.log)"
  check "A15 运行中重跑 changed=0" "[[ '${c:-x}' == '0' ]]"
else
  bad "A15 运行中重跑失败（见 /tmp/opencode/t005_run_while_up.log）"
fi
PIDS_AFTER="$(for n in etcd1 etcd2 etcd3; do printf '%s ' "${PID[$n]:-0}"; done)"
check "A15 未通知重启 handler" "! grep -q 'RUNNING HANDLER' /tmp/opencode/t005_run_while_up.log"
check "A15 进程 PID 未变（未被重启）" "[[ '$PIDS_AFTER' == '$PIDS_BEFORE' ]]"
for n in etcd1 etcd2 etcd3; do
  check "D4 A15 $n 的 /proc starttime 未变（真实未被重启）" \
    "[[ \"\$(proc_starttime '${PID[$n]:-0}')\" == '${ST_BEFORE[$n]}' ]]"
done
check "A15 集群仍 healthy" "[[ \$(healthy_count) -eq 3 ]]"

echo "-- A10 故障：kill -9 etcd2 → 2/3 仍有 quorum"
VICTIM=etcd2
KILLED_PID="${PID[$VICTIM]:-0}"
if [[ "$KILLED_PID" -gt 0 ]]; then
  sudo -n kill -9 "$KILLED_PID" 2>/dev/null || true
  wait "${WRAPPER[$VICTIM]:-0}" 2>/dev/null || true
fi
check "A10 被 kill 成员进程已退出" "[[ -z \"\$(member_pid '$VICTIM' '$SB')\" ]]"
check "A10 剩余 2/3 仍可写（quorum 存活）" "retry_put 't005:fault' 'after-kill'"
check "A10 member list 仍为 3（成员注册未丢）" "[[ \$(member_count '$EP1') == 3 ]]"

echo "-- A11 重启该成员 → 集群恢复 healthy"
if start_member "$VICTIM" "$SB"; then ok "已重新拉起 $VICTIM（PID ${PID[$VICTIM]}）"; else bad "无法重新拉起 $VICTIM"; fi
NEW_PID="${PID[$VICTIM]:-0}"
check "A11 重启后 3 端点恢复 healthy" "wait_healthy 3 60"
check "A11 原 key 仍可读（数据持久化）" \
  "[[ \"\$(etcdctl_one '$EP1' get 't005:key' --print-value-only 2>/dev/null)\" == 'before-fault' ]]"
check "A11 故障期间写入的 key 可读" \
  "[[ \"\$(etcdctl_one '$EP1' get 't005:fault' --print-value-only 2>/dev/null)\" == 'after-kill' ]]"
check "A11 leader 仍唯一" "leader_ok"
check "A11 进程 PID 已变化（确实重启）" "[[ '$NEW_PID' -gt 0 && '$NEW_PID' -ne '$KILLED_PID' ]]"

echo "-- A16/D3 配置变更：逐个重启 + 每个成员等 health + quorum 保护（真实执行）"
cat >"$SB/restart-member.sh" <<'EOS'
#!/usr/bin/env bash
# 测试专用重启钩子：按 unit 的 ExecStart 以非 root 服务用户重启单个成员。
set -euo pipefail
name="$1"; unit="$2"; sb="$3"; uid="$4"; gid="$5"; unit_exec="$6"
bin="$sb/usr/local/bin/etcd"
for p in $(pgrep -u "$uid" -f -- "$bin --name=$name " || true); do kill -9 "$p" || true; done
for _ in $(seq 1 50); do pgrep -u "$uid" -f -- "$bin --name=$name " >/dev/null || break; sleep 0.1; done
mapfile -t args < <(python3 "$unit_exec" "$unit")
mkdir -p "$sb/logs"
nohup setpriv --reuid "$uid" --regid "$gid" --clear-groups "${args[@]}" >>"$sb/logs/$name.log" 2>&1 </dev/null &
EOS
chmod 0755 "$SB/restart-member.sh"
RESTART_UNIT_EXEC="$(cd "$(dirname "$UNIT_EXEC")" && pwd)/$(basename "$UNIT_EXEC")"

SAMPLES="$SB/quorum_samples.txt"
SAMPLER_STOP="$SB/stop_sampler"
: >"$SAMPLES"
(
  while [[ ! -f "$SAMPLER_STOP" ]]; do
    healthy_count >>"$SAMPLES"
    sleep 0.25
  done
) &
SAMPLER_PID=$!

UH1="$(sha_of "$U1")"
if ap "$INV" /tmp/opencode/t005_cfg_change.log -e \
  "{\"sandbox_root\":\"$SB\",\"pki_sandbox_enabled\":false,\"etcd_heartbeat_interval\":150,\"restart_hook_script\":\"$SB/restart-member.sh\",\"restart_unit_exec\":\"$RESTART_UNIT_EXEC\"}"; then
  ok "A16 配置变更 + 滚动重启 exit 0"
else
  bad "A16 配置变更/滚动重启失败（见 /tmp/opencode/t005_cfg_change.log）"
fi
stop_sampler
c="$(changed_of /tmp/opencode/t005_cfg_change.log)"
check "A16 配置变更 changed>=1" "[[ ${c:-0} -ge 1 ]]"
check "A16 unit 内容确实变化" "[[ \"\$(sha_of '$U1')\" != '$UH1' ]]"
check "A16 unit 含新 heartbeat-interval" "grep -q -- '--heartbeat-interval=150' '$U1'"
check "D3 handler 被通知（RUNNING HANDLER）" \
  "grep -q 'RUNNING HANDLER' /tmp/opencode/t005_cfg_change.log"
check "D3 三个成员逐个重启（3 次重启钩子执行）" \
  "[[ \$(grep -c 'etcd:restart | 逐个重启：本成员自定义重启命令' /tmp/opencode/t005_cfg_change.log) -eq 3 ]]"
for _n in etcd1 etcd2 etcd3; do
  check "D3 $_n 重启后等待本成员 health 恢复" \
    "grep -q \"etcd:restart | 等待 $_n endpoint 恢复 healthy\" /tmp/opencode/t005_cfg_change.log"
done
check "D3 每个成员重启后都校验集群多数派（3 次）" \
  "[[ \$(grep -c 'etcd:restart | 校验集群多数派仍健康' /tmp/opencode/t005_cfg_change.log) -eq 3 ]]"
check "D3 滚动重启期间集群始终保有 quorum（采样 min>=2）" \
  "[[ -s '$SAMPLES' && \$(wc -l <'$SAMPLES') -ge 10 && \$(sort -n '$SAMPLES' | head -1) -ge 2 ]]"
check "D3 滚动重启后集群 3/3 healthy" "wait_healthy 3 30"
check "D3 滚动重启后 member list = 3" "[[ \$(member_count '$EP1') == 3 ]]"
check "D3 滚动重启后数据不丢（t005:key）" \
  "[[ \"\$(etcdctl_one '$EP1' get 't005:key' --print-value-only 2>/dev/null)\" == 'before-fault' ]]"
check "D3 滚动重启后 leader 唯一" "leader_ok"
for n in etcd1 etcd2 etcd3; do
  OLD_PID="${PID[$n]:-0}"
  NEW_PID_A16="$(member_pid "$n" "$SB")"
  PID[$n]="$NEW_PID_A16"
  check "D3 $n 已真实重启（PID 变化）且仍以非 root 运行" \
    "[[ -n '$NEW_PID_A16' && '$NEW_PID_A16' != '$OLD_PID' && \"\$(ps -o uid= -p '$NEW_PID_A16' | tr -d ' ')\" == '$ETCD_UID' ]]"
done
if ap "$INV" /tmp/opencode/t005_cfg_same.log \
  -e "{\"sandbox_root\":\"$SB\",\"etcd_heartbeat_interval\":150,\"pki_sandbox_enabled\":false}"; then
  c="$(changed_of /tmp/opencode/t005_cfg_same.log)"
  check "A16 同配置再跑 changed=0" "[[ '${c:-x}' == '0' ]]"
  check "A16 同配置再跑不通知 handler" "! grep -q 'RUNNING HANDLER' /tmp/opencode/t005_cfg_same.log"
else
  bad "A16 同配置再跑失败（见 /tmp/opencode/t005_cfg_same.log）"
fi

echo "-- 停止集群（端口释放）"
stop_all
check "TLS 集群停止后高位端口释放" "wait_ports_free"

# ---------------------------------------------------------------------------
echo "-- A18 TLS 可关闭：渲染 + 真实 3 成员 HTTP 集群（非 root 服务用户）"
SB2="$(mktemp -d /tmp/opencode/t005tls.XXXXXX)"
chmod 0755 "$SB2"
seed_artifacts "$SB2"
cat >"$SB2/vars.json" <<EOF
{"sandbox_root": "$SB2", "etcd_tls_enabled": false, "pki_sandbox_enabled": false}
EOF
if timeout 600 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" -e "@$SB2/vars.json" >/tmp/opencode/t005_tls_off.log 2>&1; then
  sudo -n chmod 0755 "$SB2/var" 2>/dev/null || true
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
check "B2 TLS off 数据目录仍属服务用户 0700" \
  "[[ \"\$(r_owner_mode '$SB2/var/lib/etcd/etcd1')\" == '${ETCD_UID}:${ETCD_GID} 700' ]]"

ETCDCTL="$SB2/usr/local/bin/etcdctl"
TLS_ARGS=()
EP1=http://127.0.0.1:12379
EP2=http://127.0.0.1:22379
EP3=http://127.0.0.1:32379
EPS="$EP1,$EP2,$EP3"
for n in etcd1 etcd2 etcd3; do
  if start_member "$n" "$SB2"; then
    ok "A18 已以 uid ${ETCD_UID} 从 unit 启动 $n（TLS off，PID ${PID[$n]}）"
  else
    bad "A18 无法从 unit 启动 $n（TLS off）"
  fi
done
check "A18 TLS off 3 成员 healthy" "wait_healthy 3 30"
check "A18 TLS off member list = 3" "[[ \$(member_count '$EP1') == 3 ]]"
stop_all
check "A18 TLS off 集群停止后端口释放" "wait_ports_free"

# ---------------------------------------------------------------------------
echo "-- A12 偶数成员 fail-fast（etcd_min_members=1，单独锁定奇数校验）"
run_even_case() {  # run_even_case <sandbox> <inventory> <members> <log> <label>
  local sb="$1" inv="$2" want="$3" log="$4" label="$5" rc=0
  cat >"$sb/vars.json" <<EOF
{"sandbox_root": "$sb", "etcd_tls_enabled": false, "etcd_min_members": 1, "pki_sandbox_enabled": false}
EOF
  timeout 600 "$ANSIBLE_PLAYBOOK" -i "$inv" "$PLAY" -e "@$sb/vars.json" >"$log" 2>&1 || rc=$?
  check "$label role 失败（exit≠0）" "[[ $rc -ne 0 ]]"
  check "$label 报错明确提及「奇数」" "grep -q '奇数' '$log'"
  check "$label 报错给出当前成员数 $want" "grep -qE '(当前|成员数)[^0-9]*${want}|（${want}）|${want} 个' '$log'"
  check "$label 未渲染任何 unit" "! ls '$sb'/etc/systemd/system/etcd*.service 2>/dev/null"
  check "$label 未创建数据目录" "[[ ! -e '$sb/var/lib/etcd' ]]"
}
SB3="$(mktemp -d /tmp/opencode/t005even.XXXXXX)"
run_even_case "$SB3" "$INV_EVEN" 2 /tmp/opencode/t005_even.log "A12 [2 成员]"
SB4="$(mktemp -d /tmp/opencode/t005even4.XXXXXX)"
run_even_case "$SB4" "$INV_EVEN4" 4 /tmp/opencode/t005_even4.log "A12 [4 成员]"

echo "-- A13 TLS 证书缺失 fail-fast"
SB5="$(mktemp -d /tmp/opencode/t005nocert.XXXXXX)"
cat >"$SB5/vars.json" <<EOF
{
  "sandbox_root": "$SB5",
  "etcd_tls_enabled": true,
  "pki_sandbox_enabled": false,
  "etcd_ca_file": "$SB5/missing/ca.crt",
  "etcd_cert_file": "$SB5/missing/server.crt",
  "etcd_key_file": "$SB5/missing/server.key",
  "etcd_peer_cert_file": "$SB5/missing/peer.crt",
  "etcd_peer_key_file": "$SB5/missing/peer.key"
}
EOF
rc=0
timeout 600 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" -e "@$SB5/vars.json" >/tmp/opencode/t005_nocert.log 2>&1 || rc=$?
check "A13 TLS 证书缺失 role 失败（exit≠0）" "[[ $rc -ne 0 ]]"
check "A13 报错明确提及证书" "grep -q '证书' /tmp/opencode/t005_nocert.log"
check "A13 未渲染任何 unit" "! ls '$SB5'/etc/systemd/system/etcd*.service 2>/dev/null"

# ---------------------------------------------------------------------------
echo "-- A21 宿主零污染 / 无残留 / 系统目录属主未被改动（B2）"
POST_UNITS="$(find /etc/systemd/system -maxdepth 1 -type f -name 'etcd*.service' -printf '%f\n' 2>/dev/null | sort)"
check "宿主 /etc/systemd/system 的 etcd 单元清单未变化/未新增" "[[ '$PRE_UNITS' == '$POST_UNITS' ]]"
check "宿主 /var/lib/etcd 未创建/未改动" "[[ \"\$(snapshot_path /var/lib/etcd)\" == '$PRE_VARLIB' ]]"
check "宿主 /usr/local/bin/etcd 未创建/未改动" "[[ \"\$(snapshot_path /usr/local/bin/etcd)\" == '$PRE_ETCD_BIN' ]]"
check "宿主 /usr/local/bin/etcdctl 未创建/未改动" "[[ \"\$(snapshot_path /usr/local/bin/etcdctl)\" == '$PRE_ETCDCTL_BIN' ]]"
check "B2 宿主 /etc/systemd/system 属主/权限未被 chown（仍为 root:root 0755）" \
  "[[ \"\$(owner_mode /etc/systemd/system)\" == '$PRE_SYSD_OWNER' && \"\$(owner_mode /etc/systemd/system)\" == '0:0 755' ]]"
check "B2 宿主 /usr/local/bin 属主/权限未被 chown（仍为 root:root 0755）" \
  "[[ \"\$(owner_mode /usr/local/bin)\" == '$PRE_BINDIR_OWNER' && \"\$(owner_mode /usr/local/bin)\" == '0:0 755' ]]"
check "无残留 etcd 进程（沙箱路径）" "! pgrep -f '$SB/usr/local/bin/etcd' >/dev/null 2>&1"
check "无残留 etcd 进程（TLS off 沙箱）" "! pgrep -f '$SB2/usr/local/bin/etcd' >/dev/null 2>&1"
check "高位端口全部释放" "port_free"

# 显式清理并断言（trap 仍会兜底）
stop_sampler
stop_all
sudo -n rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5"
check "沙箱临时目录已清理" "[[ ! -e '$SB' && ! -e '$SB2' && ! -e '$SB3' && ! -e '$SB4' && ! -e '$SB5' ]]"
SB=""; SB2=""; SB3=""; SB4=""; SB5=""

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
