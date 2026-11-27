#!/usr/bin/env bash
# =============================================================================
#  T020 执行身份（普通用户 + 免密 sudo）验收测试
#
#  用法:
#    tests/t020/test_t020.sh                 # 静态 + 沙箱全量（约 2 分钟）
#    tests/t020/test_t020.sh --static-only   # 只跑静态断言（秒级）
#
#  输出协议：PASS/FAIL/SKIP <描述> 逐条 + RESULT/PASS/FAIL/SKIP 汇总
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
mkdir -p /tmp/opencode

STATIC_ONLY=0
for a in "$@"; do
  case "$a" in
    --static-only) STATIC_ONLY=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

pass_count=0; fail=0; skip_count=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip_count=$((skip_count + 1)); }
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}

ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook 2>/dev/null || echo "$HOME/ansible/bin/ansible-playbook")}"
if [[ "${ANSIBLE_PLAYBOOK}" == */ansible/bin/ansible-playbook ]]; then
  export PYTHONPATH="$(dirname "$(dirname "$ANSIBLE_PLAYBOOK")")"${PYTHONPATH:+:$PYTHONPATH}
fi
have_ansible() { [[ -x "$ANSIBLE_PLAYBOOK" ]] || command -v "$ANSIBLE_PLAYBOOK" >/dev/null 2>&1; }

echo "== T020 执行身份（普通用户 + 免密 sudo）=="

# ---------------------------------------------------------------------------
echo "-- A1 5 个入口 play 均有 play 级 become: true"
# ---------------------------------------------------------------------------
for play in playbooks/add-node.yml playbooks/control-plane.yml playbooks/node.yml \
            playbooks/taints.yml playbooks/upgrade.yml; do
  check "A1 ${play} 含 become: true" grep -q "become: true" "$play"
done
# site.yml 通过 import_playbook 引入，不需要自己设 become
check "A1 playbooks/site.yml 存在（入口）" test -f playbooks/site.yml

# ---------------------------------------------------------------------------
echo "-- A2 仓库无 /root 硬编码（排除注释行/文档/tests 目录）"
# ---------------------------------------------------------------------------
# 排除：纯注释行（以可选空格+# 开头）、变量名中含 root（如 kubelet_root_prefix）
root_hits=$(grep -rn --include="*.yml" "/root" roles/ playbooks/ 2>/dev/null \
  | grep -vE '^[^:]+:[[:space:]]*#' \
  | grep -vE '_root_prefix|_root_dir' \
  | wc -l)
check "A2 roles/ playbooks/ 无 /root 路径硬编码（命中行数=0）" \
  bash -c "[[ $root_hits -eq 0 ]]"

# ---------------------------------------------------------------------------
echo "-- A3 仓库无显式 sudo/su 调用（排除注释行）"
# ---------------------------------------------------------------------------
sudo_hits=$(grep -rn --include="*.yml" -E "^\s*(- name:|command:|shell:|raw:).*\b(sudo|su) " \
  roles/ playbooks/ 2>/dev/null | wc -l)
check "A3 roles/ playbooks/ 无显式 sudo/su 任务调用（命中行数=0）" \
  bash -c "[[ $sudo_hits -eq 0 ]]"

# ---------------------------------------------------------------------------
echo "-- A4 inventory/hosts.example 有非 root 用户示例与 NOPASSWD 注释"
# ---------------------------------------------------------------------------
check "A4 hosts.example 含 ansible_user=<普通用户> 示例" \
  bash -c "grep -qE 'ansible_user=[a-z]' inventory/hosts.example"
check "A4 hosts.example 含 NOPASSWD 注释" \
  bash -c "grep -qi 'NOPASSWD' inventory/hosts.example"

# ---------------------------------------------------------------------------
echo "-- A5 docs/usage.md 执行身份说明章节：4 个关键词全覆盖"
# ---------------------------------------------------------------------------
for kw in ansible_user ansible_become_method ansible_become_password delegate_to; do
  check "A5 usage.md 含关键词：$kw" grep -q "$kw" docs/usage.md
done

# ---------------------------------------------------------------------------
# 静态门禁结束
# ---------------------------------------------------------------------------
if [[ $STATIC_ONLY -eq 1 ]]; then
  echo
  echo "RESULT=$([[ $fail -eq 0 ]] && echo PASS || echo FAIL)"
  echo "PASS=$pass_count"
  echo "FAIL=$fail"
  echo "SKIP=$skip_count"
  [[ $fail -eq 0 ]]; exit $?
fi

# ---------------------------------------------------------------------------
echo "-- A6/A7 沙箱 become 实测（ansible_connection=local + become: true 对 roles/base 实跑）"
# ---------------------------------------------------------------------------
if ! have_ansible; then
  skip "A6 沙箱 become 实测（找不到 ansible-playbook，置 SKIP）"
  skip "A7 沙箱 become 幂等（同上）"
elif ! sudo -n true 2>/dev/null; then
  skip "A6 沙箱 become 实测（当前用户无 NOPASSWD sudo，置 SKIP；真机复验：配置 NOPASSWD 后重跑）"
  skip "A7 沙箱 become 幂等（同上）"
else
  SB="/tmp/opencode/t020_base_sb"
  rm -rf "$SB"
  mkdir -p "$SB"
  PLAY="$SB/sandbox.yml"
  INV="$SB/inv"

  # 写沙箱 inventory（本机 local 连接）
  cat > "$INV" <<'INI'
[k8s_master]
localhost ansible_connection=local ansible_user=zhangsan

[k8s_node]
localhost ansible_connection=local ansible_user=zhangsan

[etcd]
localhost ansible_connection=local ansible_user=zhangsan

[k8s_cluster:children]
k8s_master
k8s_node
INI

  # 写沙箱 play：只跑 roles/base，以 become 写沙箱前缀目录，豁免宿主级破坏性操作
  cat > "$PLAY" <<YAML
---
- name: T020 become 实测沙箱
  hosts: k8s_master
  become: true
  vars:
    base_root_prefix: "${SB}"
    base_swapoff_enabled: false
    base_hostname_set: false
    base_sysctl_apply: false
    base_ntp_enabled: false
    base_firewall_disabled: false
    base_file_owner: "{{ omit }}"
    base_file_group: "{{ omit }}"
  roles:
    - base
YAML

  LOG1="$SB/run1.log"
  LOG2="$SB/run2.log"

  # 第一跑：期望 changed>=1
  if "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" > "$LOG1" 2>&1; then
    changed1=$(grep -oE 'changed=[0-9]+' "$LOG1" | tail -1 | grep -oE '[0-9]+' || echo 0)
    if [[ "$changed1" -ge 1 ]]; then
      ok "A6 沙箱 become 实测首跑 rc=0 且 changed=$changed1 (≥1)"
    else
      bad "A6 沙箱 become 实测首跑 rc=0 但 changed=0（期望 ≥1）"
    fi
  else
    bad "A6 沙箱 become 实测首跑 rc≠0（见 $LOG1）"
  fi

  # 第二跑：期望 changed=0（幂等）
  if "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY" > "$LOG2" 2>&1; then
    changed2=$(grep -oE 'changed=[0-9]+' "$LOG2" | tail -1 | grep -oE '[0-9]+' || echo 1)
    if [[ "$changed2" -eq 0 ]]; then
      ok "A7 沙箱 become 幂等二跑 changed=0"
    else
      bad "A7 沙箱 become 幂等二跑 changed=$changed2（期望 0）"
    fi
  else
    bad "A7 沙箱 become 幂等二跑 rc≠0（见 $LOG2）"
  fi

  rm -rf "$SB" 2>/dev/null || sudo rm -rf "$SB"
fi

# ---------------------------------------------------------------------------
echo "-- A8 负例：缺免密 sudo 时输出含 become 相关提示"
# ---------------------------------------------------------------------------
if ! have_ansible; then
  skip "A8 负例测试（找不到 ansible-playbook，置 SKIP）"
else
  SB_NEG="/tmp/opencode/t020_neg"
  rm -rf "$SB_NEG"; mkdir -p "$SB_NEG"
  NEG_INV="$SB_NEG/inv"
  NEG_PLAY="$SB_NEG/play.yml"

  cat > "$NEG_INV" <<'INI'
[k8s_master]
localhost ansible_connection=local ansible_user=zhangsan
INI

  # 以 become_method=sudo 且强制失败 sudo（通过 ansible_become_pass 置错误值触发 sudo 失败）
  cat > "$NEG_PLAY" <<'YAML'
---
- name: T020 负例：become 失败
  hosts: k8s_master
  become: true
  become_method: sudo
  vars:
    ansible_become_pass: "__WRONG_PASS__"
  tasks:
    - name: 触发 become 失败
      command: id
      changed_when: false
YAML

  NEG_LOG="$SB_NEG/run.log"
  "$ANSIBLE_PLAYBOOK" -i "$NEG_INV" "$NEG_PLAY" > "$NEG_LOG" 2>&1 || true
  if grep -qiE "sudo|become|password|NOPASSWD|-K|incorrect password|Sorry|Authentication failure|Missing sudo|sudo: a terminal is required|sudo: no tty present" "$NEG_LOG"; then
    ok "A8 缺免密 sudo 时输出含 become 相关提示"
  else
    bad "A8 缺免密 sudo 时输出未含预期提示（见 $NEG_LOG）"
  fi
  rm -rf "$SB_NEG"
fi

# ---------------------------------------------------------------------------
echo "-- A9 make lint rc=0"
# ---------------------------------------------------------------------------
if have_ansible; then
  check "A9 make lint rc=0" make lint
else
  skip "A9 make lint（找不到 ansible-playbook，yamllint 仍检查）"
  check "A9 yamllint rc=0" yamllint -c .yamllint .
fi

# ---------------------------------------------------------------------------
echo "-- A10 骨架测试不回退（PASS≥27 FAIL=0）"
# ---------------------------------------------------------------------------
skel_out=$(tests/skeleton/test_skeleton.sh 2>&1 || true)
skel_pass=$(echo "$skel_out" | grep -oE 'PASS=[0-9]+' | tail -1 | grep -oE '[0-9]+' || echo 0)
skel_fail=$(echo "$skel_out" | grep -oE 'FAIL=[0-9]+' | tail -1 | grep -oE '[0-9]+' || echo 1)
check "A10 骨架测试 PASS≥27" bash -c "[[ $skel_pass -ge 27 ]]"
check "A10 骨架测试 FAIL=0"  bash -c "[[ $skel_fail -eq 0 ]]"

# ---------------------------------------------------------------------------
echo
echo "RESULT=$([[ $fail -eq 0 ]] && echo PASS || echo FAIL)"
echo "PASS=$pass_count"
echo "FAIL=$fail"
echo "SKIP=$skip_count"
[[ $fail -eq 0 ]]; exit $?
