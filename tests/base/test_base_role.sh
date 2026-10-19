#!/usr/bin/env bash
# T002 主机准备 role（base）验收测试（TDD：先红后绿）
#  策略：沙箱前缀 + 真实执行（真实渲染/落盘/权限/幂等）；
#        主机级效果（modprobe/sysctl/swapoff/hostname）在本环境不可验证，改为 --list-tasks 接线断言。
# 用法: tests/base/test_base_role.sh
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

echo "== T002 base role 验收 =="

echo "-- A1 role 结构完整性"
for f in roles/base/defaults/main.yml roles/base/tasks/main.yml roles/base/tasks/files.yml \
  roles/base/tasks/system.yml roles/base/handlers/main.yml roles/base/meta/main.yml \
  roles/base/templates/sysctl.conf.j2 roles/base/templates/modules-load.conf.j2 \
  roles/base/README.md; do
  check "存在 $f" "[[ -f '$f' ]]"
done

echo "-- 真实执行（沙箱前缀 + 跳过系统级 tag）"
if ! have_ansible; then
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
else
  SB="$(mktemp -d /tmp/opencode/t002.XXXXXX)"
  cleanup() { rm -rf "$SB"; }
  trap cleanup EXIT

  mkdir -p "$SB/etc/sysctl.d" "$SB/etc/modules-load.d"
  printf 'UUID=aaaa-bbbb-cccc / ext4 defaults 0 0\n/dev/vdb1 none swap defaults 0 0\n' > "$SB/etc/fstab"
  printf '127.0.0.1 localhost localhost.localdomain\n' > "$SB/etc/hosts"

  # 记录真实系统路径的执行前状态，用于验证“沙箱隔离”（不污染宿主）
  pre_real_state="$(cat /etc/sysctl.d/99-kubernetes.conf 2>/dev/null || echo '__MISSING__')"

  AP_ARGS=(-i localhost, -c local tests/base/sandbox.yml -e "sandbox_root=$SB" --skip-tags base:system)

  if "$ANSIBLE_PLAYBOOK" "${AP_ARGS[@]}" >/tmp/opencode/t002_run1.log 2>&1; then
    ok "首跑 exit 0（真实执行）"
  else
    bad "首跑失败（见 /tmp/opencode/t002_run1.log）"
  fi

  echo "-- A2 内核模块配置"
  check "modules-load 文件已生成" "[[ -f '$SB/etc/modules-load.d/99-kubernetes.conf' ]]"
  check "含 overlay" "grep -qx 'overlay' '$SB/etc/modules-load.d/99-kubernetes.conf'"
  check "含 br_netfilter" "grep -qx 'br_netfilter' '$SB/etc/modules-load.d/99-kubernetes.conf'"
  check "modules-load 权限 0644" "[[ \$(stat -c '%a' '$SB/etc/modules-load.d/99-kubernetes.conf' 2>/dev/null) == 644 ]]"

  echo "-- A3 sysctl 配置"
  check "sysctl 文件已生成" "[[ -f '$SB/etc/sysctl.d/99-kubernetes.conf' ]]"
  check "含 net.ipv4.ip_forward = 1" "grep -qE '^net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' '$SB/etc/sysctl.d/99-kubernetes.conf'"
  check "含 bridge-nf-call-iptables" "grep -qE '^net\.bridge\.bridge-nf-call-iptables[[:space:]]*=[[:space:]]*1' '$SB/etc/sysctl.d/99-kubernetes.conf'"
  check "sysctl 权限 0644" "[[ \$(stat -c '%a' '$SB/etc/sysctl.d/99-kubernetes.conf' 2>/dev/null) == 644 ]]"
  check "sysctl.d 目录权限 0755" "[[ \$(stat -c '%a' '$SB/etc/sysctl.d' 2>/dev/null) == 755 ]]"

  echo "-- A4 swap 关闭（fstab）"
  check "fstab 中 swap 行已被注释" "grep -q '^#[[:space:]]*/dev/vdb1 none swap' '$SB/etc/fstab'"
  check "fstab 非 swap 行未被误改" "grep -q '^UUID=aaaa-bbbb-cccc / ext4 defaults 0 0$' '$SB/etc/fstab'"

  echo "-- A5 hosts 管理"
  check "hosts 含受管块" "grep -q 'BEGIN ANSIBLE MANAGED BLOCK' '$SB/etc/hosts'"
  check "hosts 保留原有行" "grep -q '^127.0.0.1 localhost localhost.localdomain$' '$SB/etc/hosts'"

  echo "-- A6 幂等（真实复跑，第二次 changed=0）"
  if "$ANSIBLE_PLAYBOOK" "${AP_ARGS[@]}" >/tmp/opencode/t002_run2.log 2>&1; then
    changed="$(grep -oE 'changed=[0-9]+' /tmp/opencode/t002_run2.log | tail -1 | cut -d= -f2)"
    if [[ "${changed:-}" == "0" ]]; then
      ok "第二次执行 changed=0（幂等）"
    else
      bad "第二次执行 changed=${changed:-?}，非幂等（见 /tmp/opencode/t002_run2.log）"
    fi
  else
    bad "第二次执行失败（见 /tmp/opencode/t002_run2.log）"
  fi

  echo "-- A7 系统级任务已接线（本环境无法真机验证，仅断言接线）"
  if "$ANSIBLE_PLAYBOOK" -i localhost, -c local tests/base/sandbox.yml \
    --list-tasks --tags base:system >/tmp/opencode/t002_listtasks.log 2>&1; then
    for t in '加载内核模块' '应用 sysctl' '关闭 swap' '设置主机名'; do
      check "list-tasks 含「$t」" "grep -q '$t' /tmp/opencode/t002_listtasks.log"
    done
  else
    bad "ansible-playbook --list-tasks 失败（见 /tmp/opencode/t002_listtasks.log）"
  fi

  echo "-- A9 系统级任务干跑可求值（--check --diff，跳过需 root 的装包任务）"
  if "$ANSIBLE_PLAYBOOK" -i localhost, -c local tests/base/sandbox.yml -e "sandbox_root=$SB" \
    --check --diff --skip-tags base:system:ntp >/tmp/opencode/t002_check.log 2>&1; then
    ok "--check 干跑 exit 0（系统级任务可正确求值）"
  else
    bad "--check 干跑失败（见 /tmp/opencode/t002_check.log）"
  fi

  echo "-- A8 playbook 语法"
  if "$ANSIBLE_PLAYBOOK" -i localhost, -c local --syntax-check tests/base/sandbox.yml >/tmp/opencode/t002_syntax.log 2>&1; then
    ok "sandbox.yml --syntax-check 通过"
  else
    bad "sandbox.yml --syntax-check 失败（见 /tmp/opencode/t002_syntax.log）"
  fi

  echo "-- 隔离性：宿主真实系统路径未被改动"
  post_real_state="$(cat /etc/sysctl.d/99-kubernetes.conf 2>/dev/null || echo '__MISSING__')"
  if [[ "$pre_real_state" == "$post_real_state" ]]; then
    ok "宿主 /etc/sysctl.d/99-kubernetes.conf 状态未变化（沙箱隔离生效）"
  else
    bad "宿主真实系统路径被污染！"
  fi
fi

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
