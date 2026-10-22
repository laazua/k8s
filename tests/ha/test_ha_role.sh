#!/usr/bin/env bash
# =============================================================================
# T006 控制面高可用 role（haproxy + keepalived）验收测试（TDD：先红后绿）
#
# 真实执行：
#   1) 用 ansible 在沙箱渲染 haproxy.cfg / keepalived.conf（成员来自 inventory
#      的 [k8s_master]，禁止硬编码）；
#   2) 用 **两个 netns + veth** 造真实 L2，在 netns 内运行 **role 渲染出的**
#      keepalived（优先级 150/100）与 haproxy，后端是真实 TLS mock apiserver；
#   3) 故障注入：停掉持有 VIP 的 keepalived（再停 haproxy）→ VIP 漂移；
#      恢复后按 preempt 回切；杀掉一个后端 → 健康检查摘除，请求仍成功；
#   4) 负载均衡：多次请求应分布到两个后端；
#   5) 幂等：同参数第二次 changed=0，运行中的 PID 不变（未触发重启）。
#
# 宿主零污染：不写 /etc/{haproxy,keepalived}、不 systemctl、不占用宿主 6443/16443
# （所有监听都在 netns 内）。trap 清理 netns/veth/进程/临时目录。
#
# 依赖（缺失时显式 FAIL，不静默 skip）：
#   HAPROXY_BIN / KEEPALIVED_BIN 或 PATH 中的 haproxy/keepalived；
#   解包版需要 LD_LIBRARY_PATH=/tmp/opencode/t006root/usr/lib64:/tmp/opencode/t006root/usr/lib64/mariadb
#   获取方法见 tests/ha/README.md 或 tests/ha/provision_bins.sh
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
mkdir -p /tmp/opencode

pass_count=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# --- Ansible 探测（与 Makefile 一致）----------------------------------------
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook 2>/dev/null || echo "$HOME/ansible/bin/ansible-playbook")}"
if [[ "$ANSIBLE_PLAYBOOK" == */ansible/bin/ansible-playbook ]]; then
  export PYTHONPATH="$(dirname "$(dirname "$ANSIBLE_PLAYBOOK")"):${PYTHONPATH:-}"
fi
have_ansible() { command -v "$ANSIBLE_PLAYBOOK" >/dev/null 2>&1 || [[ -x "$ANSIBLE_PLAYBOOK" ]]; }
YAMLLINT="${YAMLLINT:-yamllint}"

ROLE_HAPROXY=roles/haproxy
ROLE_KEEPALIVED=roles/keepalived
PLAY=tests/ha/sandbox.yml
INV=tests/ha/inventory.ini

# --- 二进制探测（显式失败 + 获取步骤）--------------------------------------
DEFAULT_ROOT=/tmp/opencode/t006root
if [[ -z "${LD_LIBRARY_PATH:-}" && -d "$DEFAULT_ROOT/usr/lib64" ]]; then
  export LD_LIBRARY_PATH="$DEFAULT_ROOT/usr/lib64:$DEFAULT_ROOT/usr/lib64/mariadb"
fi
HAPROXY_BIN="${HAPROXY_BIN:-$DEFAULT_ROOT/usr/sbin/haproxy}"
KEEPALIVED_BIN="${KEEPALIVED_BIN:-$DEFAULT_ROOT/usr/sbin/keepalived}"
if [[ ! -x "$HAPROXY_BIN" ]] && command -v haproxy >/dev/null 2>&1; then
  HAPROXY_BIN="$(command -v haproxy)"
fi
if [[ ! -x "$KEEPALIVED_BIN" ]] && command -v keepalived >/dev/null 2>&1; then
  KEEPALIVED_BIN="$(command -v keepalived)"
fi

echo "== T006 HA role 验收（haproxy + keepalived）=="

echo "-- A1 role / 测试资产结构"
for f in "$ROLE_HAPROXY/defaults/main.yml" "$ROLE_HAPROXY/tasks/main.yml" \
  "$ROLE_HAPROXY/tasks/validate.yml" "$ROLE_HAPROXY/tasks/facts.yml" \
  "$ROLE_HAPROXY/tasks/config.yml" "$ROLE_HAPROXY/tasks/install.yml" \
  "$ROLE_HAPROXY/tasks/service.yml" "$ROLE_HAPROXY/handlers/main.yml" \
  "$ROLE_HAPROXY/templates/haproxy.cfg.j2" \
  "$ROLE_HAPROXY/templates/systemd-dropin.conf.j2" "$ROLE_HAPROXY/meta/main.yml" \
  "$ROLE_HAPROXY/README.md" \
  "$ROLE_KEEPALIVED/defaults/main.yml" "$ROLE_KEEPALIVED/tasks/main.yml" \
  "$ROLE_KEEPALIVED/tasks/validate.yml" "$ROLE_KEEPALIVED/tasks/keepalived.yml" \
  "$ROLE_KEEPALIVED/tasks/kube_vip.yml" "$ROLE_KEEPALIVED/tasks/scripts.yml" \
  "$ROLE_KEEPALIVED/tasks/service.yml" "$ROLE_KEEPALIVED/handlers/main.yml" \
  "$ROLE_KEEPALIVED/templates/keepalived.conf.j2" \
  "$ROLE_KEEPALIVED/templates/systemd-dropin.conf.j2" \
  "$ROLE_KEEPALIVED/templates/chk_haproxy.sh.j2" \
  "$ROLE_KEEPALIVED/templates/notify.sh.j2" \
  "$ROLE_KEEPALIVED/templates/kube-vip.yaml.j2" \
  "$ROLE_KEEPALIVED/meta/main.yml" "$ROLE_KEEPALIVED/README.md"; do
  check "存在 $f" "[[ -f '$f' ]]"
done
for f in "$PLAY" "$INV" tests/ha/mock_backend.py tests/ha/provision_bins.sh tests/ha/README.md; do
  check "存在 $f" "[[ -f '$f' ]]"
done
check "mock_backend.py 可执行或可被 python3 解释" "python3 -c 'compile(open(\"tests/ha/mock_backend.py\").read(), \"mock_backend.py\", \"exec\")'"

echo "-- A2 变量化 / 成员来源 = inventory（禁止硬编码）"
HD="$ROLE_HAPROXY/defaults/main.yml"
KD="$ROLE_KEEPALIVED/defaults/main.yml"
check "H defaults 提供成员分组变量且默认 k8s_master" \
  "grep -qE '^haproxy_master_group:.*k8s_master' '$HD'"
check "H defaults 复用全局 apiserver 端口" "grep -qE '^haproxy_lb_port:.*k8s_apiserver_port' '$HD'"
check "H defaults 后端端口独立可配" "grep -qE '^haproxy_backend_port:' '$HD'"
check "H defaults 提供 balance 策略" "grep -qE '^haproxy_balance:[[:space:]]*roundrobin' '$HD'"
check "H defaults bind 复用全局 k8s_lb_bind_address（MINOR-1）" \
  "grep -qE '^haproxy_bind_address:.*k8s_lb_bind_address' '$HD'"
check "H defaults 提供 connect/client/server timeouts" \
  "grep -qE '^haproxy_timeout_connect:' '$HD' && grep -qE '^haproxy_timeout_client:' '$HD' && \
   grep -qE '^haproxy_timeout_server:' '$HD'"
check "H defaults 配置路径可重定向（root_prefix/base_root_prefix）" \
  "grep -qE '^haproxy_root_prefix:.*base_root_prefix' '$HD' && grep -q 'haproxy_base_prefix' '$HD'"
check "H defaults 默认路径 = 发行版/服务约定 /etc/haproxy/haproxy.cfg（可变量覆盖）" \
  "grep -qE '^haproxy_config_file:.*\\{\\{ haproxy_base_prefix \\}\\}/etc/haproxy/haproxy\\.cfg' '$HD'"
check "H defaults 的 systemd drop-in 路径与配置同前缀派生" \
  "grep -qE '^haproxy_systemd_dropin_dir:.*haproxy_service_name' '$HD' && \
   grep -qE '^haproxy_systemd_dropin_file:.*haproxy_systemd_dropin_dir' '$HD'"
check "H defaults 提供 pid 文件（track_script 复用）" "grep -qE '^haproxy_pid_file:' '$HD'"
check "H defaults 提供服务/包安装开关" \
  "grep -qE '^haproxy_manage_service:' '$HD' && grep -qE '^haproxy_manage_package:' '$HD'"
check "H tasks 从 inventory 分组推导成员" \
  "grep -q 'groups\\[haproxy_master_group\\]' '$ROLE_HAPROXY/tasks/facts.yml'"
check "H tasks 无硬编码成员名 ha1/ha2" "! grep -rqE 'ha[12]' $ROLE_HAPROXY/tasks/ $ROLE_HAPROXY/templates/"
check "H tasks/templates 无硬编码 IPv4" \
  "! grep -rqE '([0-9]{1,3}\\.){3}[0-9]{1,3}' $ROLE_HAPROXY/tasks/ $ROLE_HAPROXY/templates/"
check "H tasks/templates 无硬编码 6443" \
  "! grep -rqE '(^|[^0-9])6443([^0-9]|$)' $ROLE_HAPROXY/tasks/ $ROLE_HAPROXY/templates/"
check "H tasks/templates 不硬编码配置路径（唯一来源是 defaults 变量）" \
  "! grep -rqE '/etc/(haproxy|kubernetes)' $ROLE_HAPROXY/tasks/ $ROLE_HAPROXY/templates/"
check "H 使用 FQCN" "grep -rq 'ansible\\.builtin\\.' $ROLE_HAPROXY/tasks/"
check "H 配置变更 notify handler" "grep -rq 'notify:' $ROLE_HAPROXY/tasks/"
check "H service 任务 daemon_reload（drop-in 生效）" \
  "grep -q 'daemon_reload: true' $ROLE_HAPROXY/tasks/service.yml"

check "K defaults 的 ha_mode 复用 k8s_ha_mode" "grep -qE '^ha_mode:.*k8s_ha_mode' '$KD'"
check "K defaults 的 VIP 复用 k8s_vip" "grep -qE '^keepalived_vip:.*k8s_vip' '$KD'"
check "K defaults 的 interface 复用 k8s_vip_interface" \
  "grep -qE '^keepalived_interface:.*k8s_vip_interface' '$KD'"
check "K defaults 提供 virtual_router_id / priority / advert_int" \
  "grep -qE '^keepalived_virtual_router_id:' '$KD' && grep -qE '^keepalived_priority:' '$KD' && \
   grep -qE '^keepalived_advert_int:' '$KD'"
check "K defaults 提供 priority base/step（多 master 可推导）" \
  "grep -qE '^keepalived_priority_base:' '$KD' && grep -qE '^keepalived_priority_step:' '$KD'"
check "K defaults 提供 track_script 与 haproxy pid 文件" \
  "grep -qE '^keepalived_check_script:' '$KD' && grep -qE '^keepalived_haproxy_pid_file:' '$KD'"
check "K defaults 提供 notify 脚本" "grep -qE '^keepalived_notify_script:' '$KD'"
check "K defaults 提供 nopreempt 开关（默认可抢占）" "grep -qE '^keepalived_nopreempt:[[:space:]]*false' '$KD'"
check "K defaults 提供 kube-vip image / manifest 路径" \
  "grep -qE '^kube_vip_image:' '$KD' && grep -qE '^kube_vip_manifest_file:' '$KD'"
check "K defaults 提供服务/包安装开关" \
  "grep -qE '^keepalived_manage_service:' '$KD' && grep -qE '^keepalived_manage_package:' '$KD'"
check "K defaults 配置路径可重定向（root_prefix/base_root_prefix）" \
  "grep -qE '^keepalived_root_prefix:.*base_root_prefix' '$KD' && grep -q 'keepalived_base_prefix' '$KD'"
check "K defaults 默认路径 = 服务约定 /etc/keepalived/keepalived.conf（可变量覆盖）" \
  "grep -qE '^keepalived_config_file:.*\\{\\{ keepalived_base_prefix \\}\\}/etc/keepalived/keepalived\\.conf' '$KD'"
check "K defaults 的 systemd drop-in 路径与配置同前缀派生" \
  "grep -qE '^keepalived_systemd_dropin_dir:.*keepalived_service_name' '$KD' && \
   grep -qE '^keepalived_systemd_dropin_file:.*keepalived_systemd_dropin_dir' '$KD'"
check "K service 任务 daemon_reload（drop-in 生效）" \
  "grep -q 'daemon_reload: true' $ROLE_KEEPALIVED/tasks/service.yml"
check "K tasks 无硬编码成员名 ha1/ha2" "! grep -rqE 'ha[12]' $ROLE_KEEPALIVED/tasks/ $ROLE_KEEPALIVED/templates/"
check "K tasks/templates 无硬编码 IPv4" \
  "! grep -rqE '([0-9]{1,3}\\.){3}[0-9]{1,3}' $ROLE_KEEPALIVED/tasks/ $ROLE_KEEPALIVED/templates/"
check "K tasks 无硬编码 /etc/keepalived" "! grep -rq '/etc/keepalived' $ROLE_KEEPALIVED/tasks/ $ROLE_KEEPALIVED/templates/"
check "K 使用 FQCN" "grep -rq 'ansible\\.builtin\\.' $ROLE_KEEPALIVED/tasks/"
check "K 配置/脚本变更 notify handler" "grep -rq 'notify:' $ROLE_KEEPALIVED/tasks/"
check "K meta 声明 role 名" "grep -q 'role_name: keepalived' $ROLE_KEEPALIVED/meta/main.yml"
check "H meta 声明 role 名" "grep -q 'role_name: haproxy' $ROLE_HAPROXY/meta/main.yml"

echo "-- A3 语法与风格"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY" >/tmp/opencode/t006_syntax.log 2>&1; then
    ok "$PLAY --syntax-check 通过"
  else
    bad "$PLAY --syntax-check 失败（见 /tmp/opencode/t006_syntax.log）"
  fi
else
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi
if command -v "$YAMLLINT" >/dev/null 2>&1; then
  if "$YAMLLINT" -c .yamllint "$ROLE_HAPROXY" "$ROLE_KEEPALIVED" tests/ha >/tmp/opencode/t006_yamllint.log 2>&1; then
    ok "yamllint（roles/haproxy, roles/keepalived, tests/ha）无 error"
  else
    bad "yamllint 失败（见 /tmp/opencode/t006_yamllint.log）"
  fi
else
  bad "找不到 yamllint"
fi

# --- 运行前置：缺依赖时明确失败并给出获取步骤（禁止静默 skip）---------------
missing=0
[[ -x "$HAPROXY_BIN" ]] || { bad "找不到可执行的 haproxy：设置 HAPROXY_BIN 或运行 tests/ha/provision_bins.sh"; missing=1; }
[[ -x "$KEEPALIVED_BIN" ]] || { bad "找不到可执行的 keepalived：设置 KEEPALIVED_BIN 或运行 tests/ha/provision_bins.sh"; missing=1; }
have_ansible || { bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"; missing=1; }
if ! sudo -n true 2>/dev/null; then bad "需要免密 sudo：创建 netns/veth 并以 root 运行 keepalived"; missing=1; fi
if ! sudo -n ip netns list >/dev/null 2>&1; then bad "ip netns 不可用（需要 iproute2 + CAP_SYS_ADMIN）"; missing=1; fi
if [[ $missing -ne 0 ]]; then
  cat >&2 <<'EOF'

获取测试二进制（不安装进系统）：
  tests/ha/provision_bins.sh
  export HAPROXY_BIN=/tmp/opencode/t006root/usr/sbin/haproxy
  export KEEPALIVED_BIN=/tmp/opencode/t006root/usr/sbin/keepalived
  export LD_LIBRARY_PATH=/tmp/opencode/t006root/usr/lib64:/tmp/opencode/t006root/usr/lib64/mariadb
详见 tests/ha/README.md。
EOF
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi
ok "haproxy 可执行：$HAPROXY_BIN（$("$HAPROXY_BIN" -v 2>&1 | head -1)）"
ok "keepalived 可执行：$KEEPALIVED_BIN（$("$KEEPALIVED_BIN" --version 2>&1 | head -1)）"
check "ldd keepalived 无缺失库" "! ldd '$KEEPALIVED_BIN' | grep -q 'not found'"

# --- 沙箱与清理 -------------------------------------------------------------
SB="$(mktemp -d /tmp/opencode/t006.XXXXXX)"
# keepalived enable_script_security：脚本必须 root 拥有且父目录不可被组/其他写。
# /tmp 是 1777，故脚本放 root:root 0700 的 /run 子目录。
SAFE_ROOT="/run/t006-$$"
sudo -n rm -rf "$SAFE_ROOT"
sudo -n mkdir -p "$SAFE_ROOT"
sudo -n chmod 0755 "$SAFE_ROOT"
NS1=t006ha1
NS2=t006ha2
VETH1=veth-ha1
VETH2=veth-ha2
VIP=10.99.0.100
PORT_PRE="$(ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -E ':(80|443|6443|16443)$' | sort || true)"
MOCK_PIDS=()
HAPROXY_PIDS=()
KEEPALIVED_PIDS=()
CLEANED=0

cleanup() {
  local p
  set +e
  for p in "${KEEPALIVED_PIDS[@]}" "${HAPROXY_PIDS[@]}" "${MOCK_PIDS[@]}"; do
    sudo -n kill "$p" 2>/dev/null || true
  done
  sleep 0.3
  for p in "${KEEPALIVED_PIDS[@]}" "${HAPROXY_PIDS[@]}" "${MOCK_PIDS[@]}"; do
    sudo -n kill -9 "$p" 2>/dev/null || true
  done
  sudo -n pkill -9 -f "$SB/" 2>/dev/null || true
  sudo -n ip netns del "$NS1" 2>/dev/null || true
  sudo -n ip netns del "$NS2" 2>/dev/null || true
  sudo -n ip link del "$VETH1" 2>/dev/null || true
  sudo -n ip link del "$VETH2" 2>/dev/null || true
  sudo -n rm -f /run/vrrp.pid /run/checkers.pid /run/keepalived.pid 2>/dev/null || true
  CLEANED=1
}
trap 'cleanup 2>/dev/null; sudo -n rm -rf "${SB:-}" "${SAFE_ROOT:-}"' EXIT

changed_of() { grep -oE 'changed=[0-9]+' "$1" 2>/dev/null | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
ap() {
  local inv="$1" log="$2"
  shift 2
  timeout 300 "$ANSIBLE_PLAYBOOK" -i "$inv" "$PLAY" -e "sandbox_root=$SB" \
    -e "haproxy_binary=$HAPROXY_BIN" -e "keepalived_binary=$KEEPALIVED_BIN" \
    -e "keepalived_safe_root=$SAFE_ROOT" "$@" >"$log" 2>&1
}
expect_fail() {  # expect_fail <名称> <日志> <错误片段> [额外 -e ...]
  local name="$1" log="$2" pattern="$3"
  shift 3
  if ap "$INV" "$log" "$@" ; then
    bad "$name（预期失败却成功）"
  elif grep -qE "$pattern" "$log"; then
    ok "$name（fail-fast，错误信息明确）"
  else
    bad "$name（失败但错误信息未匹配：$pattern，见 $log）"
  fi
}

echo "-- A4 fail-fast（无成员 / VIP 缺失 / vrid 非法 / ha_mode 非法）"
FSB="$SB/fail"
mkdir -p "$FSB"
expect_fail "无 master 成员时失败" /tmp/opencode/t006_ff_members.log '成员为空|k8s_master' \
  -e 'haproxy_master_group=no_such_group' -e "haproxy_root_prefix=$FSB/x" -e "keepalived_root_prefix=$FSB/x"
expect_fail "VIP 为空时失败" /tmp/opencode/t006_ff_vip.log 'VIP|vip' \
  -e 'keepalived_vip=' -e "haproxy_root_prefix=$FSB/vip" -e "keepalived_root_prefix=$FSB/vip"
expect_fail "k8s_vip 为空时失败" /tmp/opencode/t006_ff_k8svip.log 'VIP|vip' \
  -e 'k8s_vip=' -e "haproxy_root_prefix=$FSB/vip2" -e "keepalived_root_prefix=$FSB/vip2"
expect_fail "virtual_router_id=300 失败" /tmp/opencode/t006_ff_vrid300.log 'virtual_router_id|1.?255|虚拟路由' \
  -e 'keepalived_virtual_router_id=300' -e "haproxy_root_prefix=$FSB/v300" -e "keepalived_root_prefix=$FSB/v300"
expect_fail "virtual_router_id=0 失败" /tmp/opencode/t006_ff_vrid0.log 'virtual_router_id|1.?255|虚拟路由' \
  -e 'keepalived_virtual_router_id=0' -e "haproxy_root_prefix=$FSB/v0" -e "keepalived_root_prefix=$FSB/v0"
expect_fail "ha_mode 非法时失败" /tmp/opencode/t006_ff_mode.log 'ha_mode|keepalived|kube-vip' \
  -e 'ha_mode=bogus' -e "haproxy_root_prefix=$FSB/mode" -e "keepalived_root_prefix=$FSB/mode"
expect_fail "interface 为空时失败" /tmp/opencode/t006_ff_iface.log 'interface|网卡' \
  -e 'keepalived_interface=' -e "haproxy_root_prefix=$FSB/iface" -e "keepalived_root_prefix=$FSB/iface"
check "fail-fast 未渲染 keepalived 配置" "[[ ! -f '$FSB/vip/etc/keepalived/keepalived.conf' ]]"
check "fail-fast 未渲染 haproxy 配置" "[[ ! -f '$FSB/x/etc/haproxy/haproxy.cfg' ]]"

echo "-- A5 配置渲染（成员来自 inventory）"
C1=0
if ap "$INV" /tmp/opencode/t006_run1.log; then
  ok "首跑渲染 exit 0"
  C1="$(changed_of /tmp/opencode/t006_run1.log)"
  check "首跑 changed>0" "[[ ${C1:-0} -gt 0 ]]"
else
  bad "首跑渲染失败（见 /tmp/opencode/t006_run1.log）"
fi
H1="$SB/ha1/etc/haproxy/haproxy.cfg"
H2="$SB/ha2/etc/haproxy/haproxy.cfg"
K1="$SB/ha1/etc/keepalived/keepalived.conf"
K2="$SB/ha2/etc/keepalived/keepalived.conf"
HD1="$SB/ha1/etc/systemd/system/haproxy.service.d/10-role-config.conf"
KD1="$SB/ha1/etc/systemd/system/keepalived.service.d/10-role-config.conf"
for f in "$H1" "$H2" "$K1" "$K2" "$HD1" "$KD1"; do check "渲染产物 $f" "[[ -f '$f' ]]"; done
check "H haproxy.cfg defaults mode tcp" "grep -qE '^defaults' '$H1' && sed -n '/^defaults/,/^[a-z]/p' '$H1' | grep -q 'mode tcp'"
check "H backend 为 tcp 且 balance 来自变量" \
  "grep -q 'balance roundrobin' '$H1' && grep -q 'mode tcp' '$H1'"
check "H frontend 监听 0.0.0.0:6443（VIP 所在 L2）" "grep -qE 'bind 0\\.0\\.0\\.0:6443' '$H1'"
check "H default_backend 指向 apiserver backend" \
  "grep -qE '^frontend k8s_apiserver' '$H1' && grep -q 'default_backend k8s_apiserver' '$H1'"
check "H backend 名 k8s_apiserver" "grep -qE '^backend k8s_apiserver' '$H1'"
check "H 后端 ha1 来自 inventory（10.99.0.1:16443 check）" \
  "grep -qE '^[[:space:]]+server ha1 10\\.99\\.0\\.1:16443 check' '$H1'"
check "H 后端 ha2 来自 inventory（10.99.0.2:16443 check）" \
  "grep -qE '^[[:space:]]+server ha2 10\\.99\\.0\\.2:16443 check' '$H1'"
check "H 健康检查参数来自变量（inter/fall/rise）" \
  "grep -q 'check inter 500ms fall 2 rise 1' '$H1'"
check "H timeout connect 渲染" "grep -qE 'timeout connect 5s' '$H1'"
check "H timeout client/server 渲染" \
  "grep -qE 'timeout client 1h' '$H1' && grep -qE 'timeout server 1h' '$H1'"
check "H ha2 配置同样含两个后端（非本机硬编码）" \
  "grep -q 'server ha1 10.99.0.1:16443 check' '$H2' && grep -q 'server ha2 10.99.0.2:16443 check' '$H2'"
check "H haproxy -c 配置校验通过" "'$HAPROXY_BIN' -c -f '$H1'"

check "K vrrp_instance 名称" "grep -qE '^vrrp_instance k8s_apiserver' '$K1'"
check "K state 存在" "grep -qE '^[[:space:]]+state BACKUP' '$K1'"
check "K ha1 priority=150（来自 host var）" "grep -qE '^[[:space:]]+priority 150' '$K1'"
check "K ha2 priority=100（来自 host var）" "grep -qE '^[[:space:]]+priority 100' '$K2'"
check "K virtual_router_id=51" "grep -qE '^[[:space:]]+virtual_router_id 51' '$K1'"
check "K interface=ha1 的 veth-ha1" "grep -qE '^[[:space:]]+interface veth-ha1' '$K1'"
check "K interface=ha2 的 veth-ha2" "grep -qE '^[[:space:]]+interface veth-ha2' '$K2'"
check "K virtual_ipaddress = 10.99.0.100/32" "grep -qE '10\\.99\\.0\\.100/32' '$K1'"
check "K advert_int 来自变量" "grep -qE '^[[:space:]]+advert_int 1' '$K1'"
check "K track_script 引用 chk_haproxy" \
  "grep -qE '^vrrp_script chk_haproxy' '$K1' && grep -qE '^[[:space:]]+track_script' '$K1' && grep -q 'chk_haproxy' '$K1'"
check "K notify_master/backup/fault 存在" \
  "grep -q 'notify_master' '$K1' && grep -q 'notify_backup' '$K1' && grep -q 'notify_fault' '$K1'"
check "K auth_type PASS" "grep -qE '^[[:space:]]+auth_type PASS' '$K1'"
KSCRIPT1="$SAFE_ROOT/ha1/scripts/chk_haproxy.sh"
KSCRIPT2="$SAFE_ROOT/ha2/scripts/chk_haproxy.sh"
check "K chk_haproxy.sh 可执行（root:root 安全目录）" "[[ -x '$KSCRIPT1' ]]"
check "K chk_haproxy.sh 检查本机 haproxy pid 文件" \
  "grep -q '$SB/ha1/run/haproxy.pid' '$KSCRIPT1'"
check "K chk_haproxy.sh 按主机隔离（ha2 指向自己的 pid）" \
  "grep -q '$SB/ha2/run/haproxy.pid' '$KSCRIPT2'"
check "K notify.sh 可执行" "[[ -x '$SAFE_ROOT/ha1/scripts/notify.sh' ]]"
check "K 脚本目录 root 拥有（enable_script_security 前提）" \
  "[[ \"\$(sudo -n stat -c '%u:%g %a' '$SAFE_ROOT/ha1/scripts')\" == '0:0 755' ]]"

echo "-- A5b systemd 路径一致性（渲染路径 == unit 引用路径 == 服务约定路径）"
hp_unit_path="$(sed -nE 's/^ExecStart=.* -f ([^ ]+).*/\1/p' "$HD1" | head -1)"
hp_env_path="$(sed -nE 's/^Environment=.*CONFIG=([^" ]+)".*/\1/p' "$HD1" | head -1)"
check "H drop-in ExecStart 显式 -f 渲染路径（同一变量）" \
  "[[ -n '$hp_unit_path' && '$hp_unit_path' == '$H1' ]]"
check "H drop-in Environment CONFIG == 渲染路径（同一变量）" \
  "[[ -n '$hp_env_path' && '$hp_env_path' == '$H1' ]]"
check "H 渲染路径以约定 /etc/haproxy/haproxy.cfg 结尾（生产默认）" \
  "[[ '$H1' == */etc/haproxy/haproxy.cfg ]]"
check "H drop-in 不再引用 \$CFGDIR（只加载 role 渲染文件）" "! grep -q 'CFGDIR' '$HD1'"
k_unit_path="$(sed -nE 's/^ExecStart=.* -f ([^ ]+).*/\1/p' "$KD1" | head -1)"
check "K drop-in ExecStart 显式 -f 渲染路径（同一变量）" \
  "[[ -n '$k_unit_path' && '$k_unit_path' == '$K1' ]]"
check "K 渲染路径以约定 /etc/keepalived/keepalived.conf 结尾（生产默认）" \
  "[[ '$K1' == */etc/keepalived/keepalived.conf ]]"
check "K 渲染路径与 H 使用同一 base_root_prefix 重定向" \
  "[[ '$H1' == '$SB/ha1/etc/haproxy/haproxy.cfg' && '$K1' == '$SB/ha1/etc/keepalived/keepalived.conf' ]]"

echo "-- A6 kube-vip 分支（仅配置渲染 + 前置校验；真实漂移未验证，见契约）"
KVS="$SB/kubevip"
if ap "$INV" /tmp/opencode/t006_kubevip.log -e 'ha_mode=kube-vip' -e "sandbox_root=$KVS"; then
  ok "kube-vip 渲染（sandbox_root=$KVS）exit 0"
else
  bad "kube-vip 渲染失败（见 /tmp/opencode/t006_kubevip.log）"
fi
KV1="$KVS/ha1/etc/kubernetes/manifests/kube-vip.yaml"
check "KV 渲染 kube-vip manifest" "[[ -f '$KV1' ]]"
check "KV manifest 含 image（变量）" "grep -qE 'image: .*kube-vip' '$KV1'"
check "KV manifest 含 manager 子命令（command/args）" \
  "grep -qE '^[[:space:]]+command:' '$KV1' && grep -q '/kube-vip' '$KV1' && \
   grep -qE '^[[:space:]]+- manager' '$KV1'"
check "KV manifest hostNetwork: true" "grep -qE '^[[:space:]]+hostNetwork: true' '$KV1'"
check "KV manifest priorityClassName: system-node-critical" \
  "grep -qE '^[[:space:]]+priorityClassName: system-node-critical' '$KV1'"
check "KV manifest capabilities NET_ADMIN + NET_RAW" \
  "grep -q 'securityContext' '$KV1' && grep -q 'NET_ADMIN' '$KV1' && grep -q 'NET_RAW' '$KV1'"
check "KV manifest 挂载 kubeconfig hostPath" \
  "grep -qE '^[[:space:]]+hostPath:' '$KV1' && grep -q '/etc/kubernetes/admin.conf' '$KV1'"
check "KV manifest kubeconfig volumeMount" \
  "grep -qE 'mountPath: /etc/kubernetes/admin.conf' '$KV1' && grep -qE '^[[:space:]]+volumes:' '$KV1'"
check "KV manifest vip_nodename 来自 downward API（选主必需）" \
  "grep -q 'vip_nodename' '$KV1' && grep -q 'spec.nodeName' '$KV1'"
check "KV manifest 含 vip_address = 10.99.0.100" "grep -qE 'vip_address' '$KV1' && grep -q '10\\.99\\.0\\.100' '$KV1'"
check "KV manifest 含 vip_interface = veth-ha1" "grep -qE 'vip_interface' '$KV1' && grep -q 'veth-ha1' '$KV1'"
check "KV manifest 含 port 6443" "grep -qE 'name: port' '$KV1' && grep -q '6443' '$KV1'"
check "KV 模式不渲染 keepalived.conf" "[[ ! -f '$KVS/ha1/etc/keepalived/keepalived.conf' ]]"
expect_fail "kube-vip 模式 VIP 为空时失败" /tmp/opencode/t006_kv_novip.log 'VIP|vip' \
  -e 'ha_mode=kube-vip' -e 'keepalived_vip=' -e "sandbox_root=$SB/kvnovip"

# ---------------------------------------------------------------------------
echo "-- 启动真实 netns L2（ha1=10.99.0.1 / ha2=10.99.0.2，VIP=$VIP）"
cleanup
sudo -n ip netns add "$NS1"
sudo -n ip netns add "$NS2"
sudo -n ip link add "$VETH1" type veth peer name "$VETH2"
sudo -n ip link set "$VETH1" netns "$NS1"
sudo -n ip link set "$VETH2" netns "$NS2"
for n in "$NS1" "$NS2"; do sudo -n ip netns exec "$n" ip link set lo up; done
sudo -n ip netns exec "$NS1" ip addr add 10.99.0.1/24 dev "$VETH1"
sudo -n ip netns exec "$NS1" ip link set "$VETH1" up
sudo -n ip netns exec "$NS2" ip addr add 10.99.0.2/24 dev "$VETH2"
sudo -n ip netns exec "$NS2" ip link set "$VETH2" up
check "netns ha1 地址就绪" "sudo -n ip netns exec '$NS1' ip -4 addr show dev '$VETH1' | grep -q '10.99.0.1/24'"
check "netns ha2 地址就绪" "sudo -n ip netns exec '$NS2' ip -4 addr show dev '$VETH2' | grep -q '10.99.0.2/24'"
keepalived_conf_ok() { sudo -n env LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" ip netns exec "$NS1" "$KEEPALIVED_BIN" -t -f "$K1" >/dev/null 2>&1; }
check "K keepalived -t 配置校验通过（真实 netns 网卡存在时）" "keepalived_conf_ok"

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -subj '/CN=k8s-vip' -keyout "$SB/key.pem" -out "$SB/cert.pem" \
  -addext "subjectAltName=IP:10.99.0.1,IP:10.99.0.2,IP:$VIP,IP:127.0.0.1" \
  >/dev/null 2>&1
check "测试 TLS 证书已生成" "[[ -s '$SB/cert.pem' && -s '$SB/key.pem' ]]"

start_mock() {
  local ns="$1" dir="$2" ip="$3" id="$4" i
  mkdir -p "$dir"
  sudo -n ip netns exec "$ns" python3 "$PWD/tests/ha/mock_backend.py" \
    --bind "$ip" --port 16443 --cert "$SB/cert.pem" --key "$SB/key.pem" \
    --id "$id" --pid-file "$dir/mock.pid" >"$dir/mock.log" 2>&1 &
  for ((i = 0; i < 50; i++)); do [[ -s "$dir/mock.pid" ]] && break; sleep 0.1; done
  [[ -s "$dir/mock.pid" ]] || return 1
  MOCK_PIDS+=("$(cat "$dir/mock.pid")")
}
start_haproxy() {
  local ns="$1" dir="$2" i cfg
  cfg="$(sed -nE 's/^ExecStart=.* -f ([^ ]+).*/\1/p' \
    "$dir/etc/systemd/system/haproxy.service.d/10-role-config.conf" 2>/dev/null | head -1)"
  [[ -n "$cfg" && -f "$cfg" ]] || return 1
  sudo -n mkdir -p "$dir/run"
  sudo -n env LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" ip netns exec "$ns" \
    "$HAPROXY_BIN" -D -f "$cfg" -p "$dir/run/haproxy.pid"
  for ((i = 0; i < 50; i++)); do [[ -s "$dir/run/haproxy.pid" ]] && break; sleep 0.1; done
  [[ -s "$dir/run/haproxy.pid" ]] || return 1
  sudo -n chmod 0644 "$dir/run/haproxy.pid" 2>/dev/null || true
  HAPROXY_PIDS+=("$(cat "$dir/run/haproxy.pid")")
}
start_keepalived() {
  local ns="$1" dir="$2" i cfg
  local log="$SB/logs/$(basename "$dir")/keepalived.log"
  cfg="$(sed -nE 's/^ExecStart=.* -f ([^ ]+).*/\1/p' \
    "$dir/etc/systemd/system/keepalived.service.d/10-role-config.conf" 2>/dev/null | head -1)"
  [[ -n "$cfg" && -f "$cfg" ]] || return 1
  sudo -n mkdir -p "$dir/run"
  mkdir -p "$(dirname "$log")"
  sudo -n env LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" ip netns exec "$ns" \
    "$KEEPALIVED_BIN" -P -n -l -G -D \
    -f "$cfg" \
    -p "$dir/run/keepalived.pid" -r "$dir/run/vrrp.pid" \
    >"$log" 2>&1 &
  for ((i = 0; i < 50; i++)); do [[ -s "$dir/run/keepalived.pid" ]] && break; sleep 0.1; done
  [[ -s "$dir/run/keepalived.pid" ]] || return 1
  sudo -n chmod 0644 "$dir/run/keepalived.pid" 2>/dev/null || true
  KEEPALIVED_PIDS+=("$(cat "$dir/run/keepalived.pid")")
}
has_vip() { sudo -n ip netns exec "$1" ip -4 addr show dev "$2" 2>/dev/null | grep -q "$VIP"; }
wait_vip() {
  local ns="$1" dev="$2" tries="${3:-40}" i
  for ((i = 0; i < tries; i++)); do has_vip "$ns" "$dev" && return 0; sleep 0.5; done
  return 1
}
curl_vip() { sudo -n ip netns exec "$NS2" curl -sk --max-time 5 "https://$VIP:6443/healthz"; }
wait_backend_only() {
  local want="$1" tries="${2:-40}" i out stable=0 other=ha1
  [[ "$want" == ha1 ]] && other=ha2
  for ((i = 0; i < tries; i++)); do
    out="$(curl_vip 2>/dev/null || true)"
    if [[ "$out" == *"backend=$want"* && "$out" != *"backend=$other"* ]]; then
      stable=$((stable + 1))
      [[ $stable -ge 5 ]] && return 0
    else
      stable=0
    fi
    sleep 0.5
  done
  return 1
}

mkdir -p "$SB/mock/ha1" "$SB/mock/ha2" "$SB/logs/ha1" "$SB/logs/ha2"
check "启动 mock 后端 ha1" "start_mock '$NS1' '$SB/mock/ha1' 10.99.0.1 ha1"
check "启动 mock 后端 ha2" "start_mock '$NS2' '$SB/mock/ha2' 10.99.0.2 ha2"
check "在 netns 中启动 role 渲染的 haproxy（ha1）" "start_haproxy '$NS1' '$SB/ha1'"
check "在 netns 中启动 role 渲染的 haproxy（ha2）" "start_haproxy '$NS2' '$SB/ha2'"
check "在 netns 中启动 role 渲染的 keepalived（ha1=150）" "start_keepalived '$NS1' '$SB/ha1'"
check "在 netns 中启动 role 渲染的 keepalived（ha2=100）" "start_keepalived '$NS2' '$SB/ha2'"

check "VIP 初始在 ha1（priority 150）" "wait_vip '$NS1' '$VETH1' 40"
check "VIP 初始不在 ha2" "! has_vip '$NS2' '$VETH2'"
check "https://VIP:6443/healthz 返回 ok（经 haproxy）" "curl_vip 2>/dev/null | grep -q '^ok'"

echo "-- A7 幂等：第二次 changed=0，运行中不重启（PID 不变）"
HPID1="$(cat "$SB/ha1/run/haproxy.pid")"
KPID1="$(cat "$SB/ha1/run/keepalived.pid")"
HASH_BEFORE="$(sha256sum "$H1" "$K1" "$KSCRIPT1" 2>/dev/null)"
if ap "$INV" /tmp/opencode/t006_run2.log; then
  C2="$(changed_of /tmp/opencode/t006_run2.log)"
  check "第二次执行 changed=0（幂等）" "[[ '${C2:-x}' == '0' ]]"
  check "第二次执行未触发 handler 重启" "! grep -q 'RUNNING HANDLER' /tmp/opencode/t006_run2.log"
else
  bad "第二次执行失败（见 /tmp/opencode/t006_run2.log）"
fi
check "运行中的 haproxy PID 不变" "[[ \"\$(cat '$SB/ha1/run/haproxy.pid' 2>/dev/null)\" == '$HPID1' ]]"
check "运行中的 keepalived PID 不变" "[[ \"\$(cat '$SB/ha1/run/keepalived.pid' 2>/dev/null)\" == '$KPID1' ]]"
check "配置文件内容未变" "[[ \"\$(sha256sum '$H1' '$K1' '$KSCRIPT1' 2>/dev/null)\" == \"$HASH_BEFORE\" ]]"

echo "-- A8 真实负载均衡（两个后端都被命中）"
LB="$SB/lb1.txt"
: >"$LB"
for _ in $(seq 1 12); do curl_vip >>"$LB" 2>/dev/null || true; done
check "多次请求分布到 ha1" "grep -q 'backend=ha1' '$LB'"
check "多次请求分布到 ha2" "grep -q 'backend=ha2' '$LB'"
check "所有 LB 响应均为 ok" "[[ \$(grep -c '^ok' '$LB') -ge 10 ]]"

echo "-- A9 后端故障：杀掉 ha1 mock → 健康检查摘除，请求只落 ha2"
M1="$(cat "$SB/mock/ha1/mock.pid")"
sudo -n kill "$M1" 2>/dev/null || true
check "ha1 后端故障后仅 ha2 提供服务（curl 持续成功）" "wait_backend_only ha2 40"
OUT="$SB/lb2.txt"
: >"$OUT"
for _ in $(seq 1 8); do curl_vip >>"$OUT" 2>/dev/null || true; done
check "后端摘除后 8/8 请求成功" "[[ \$(grep -c '^ok' '$OUT') -eq 8 ]]"
check "后端摘除后不再命中 ha1" "! grep -q 'backend=ha1' '$OUT'"

echo "-- A10 故障漂移：停掉持有 VIP 的 ha1 keepalived"
sudo -n kill "$(cat "$SB/ha1/run/keepalived.pid")" 2>/dev/null || true
check "VIP 漂移到 ha2" "wait_vip '$NS2' '$VETH2' 40"
check "ha1 已释放 VIP" "! has_vip '$NS1' '$VETH1'"
check "漂移后 https://VIP:6443/healthz 仍返回 ok" "curl_vip 2>/dev/null | grep -q '^ok'"

echo "-- A11 整机故障：再停 ha1 haproxy；恢复 ha1 后按 preempt 回切"
sudo -n kill "$(cat "$SB/ha1/run/haproxy.pid")" 2>/dev/null || true
check "ha1 整机故障后请求仍只落 ha2" "wait_backend_only ha2 40"
check "整机故障期间 curl 持续成功" "curl_vip 2>/dev/null | grep -q '^ok'"
# 恢复 ha1 的 haproxy 与 keepalived
check "恢复 ha1 haproxy" "start_haproxy '$NS1' '$SB/ha1'"
check "恢复 ha1 keepalived（150 > 100，preempt）" "start_keepalived '$NS1' '$SB/ha1'"
check "VIP 按 preempt 回切到 ha1" "wait_vip '$NS1' '$VETH1' 60"
check "回切后 ha2 释放 VIP" "! has_vip '$NS2' '$VETH2'"
check "回切后 https://VIP:6443/healthz 返回 ok" "curl_vip 2>/dev/null | grep -q '^ok'"

echo "-- A12 收尾：trap 清理 netns/veth/进程，宿主端口无残留"
cleanup
check "netns 已删除" "! sudo -n ip netns list | grep -qE '(^| )t006ha[12]( |$)'"
PORT_POST="$(ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -E ':(80|443|6443|16443)$' | sort || true)"
check "宿主 80/443/6443/16443 监听状态与测试前一致（零占用）" "[[ \"$PORT_POST\" == \"$PORT_PRE\" ]]"
check "无遗留 mock/haproxy/keepalived 进程（沙箱路径）" "! pgrep -af '$SB/' >/dev/null"
check "无 host 级 /run/vrrp.pid 残留" "[[ ! -e /run/vrrp.pid ]]"
check "未写宿主 /etc/haproxy" "[[ ! -e /etc/haproxy ]]"
check "未写宿主 /etc/keepalived" "[[ ! -e /etc/keepalived ]]"
sudo -n rm -rf "$SB" "$SAFE_ROOT"

# ---------------------------------------------------------------------------
echo
if [[ $fail -eq 0 ]]; then
  printf '== 汇总: PASS=%d FAIL=%d ==\n' "$pass_count" "$fail"
  exit 0
else
  printf '== 汇总: PASS=%d FAIL=%d ==\n' "$pass_count" "$fail"
  exit 1
fi
