#!/usr/bin/env bash
# T001 骨架验收测试（TDD：先红后绿）
# 用法: tests/skeleton/test_skeleton.sh
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
YAMLLINT="${YAMLLINT:-yamllint}"
have_ansible() { command -v "$ANSIBLE_PLAYBOOK" >/dev/null 2>&1 || [[ -x "$ANSIBLE_PLAYBOOK" ]]; }

echo "== T001 骨架验收 =="

echo "-- 文件齐全性"
for f in ansible.cfg .yamllint .gitignore Makefile \
  inventory/hosts.example \
  group_vars/all/main.yml group_vars/k8s_master/main.yml \
  group_vars/k8s_node/main.yml group_vars/etcd/main.yml \
  playbooks/site.yml playbooks/control-plane.yml playbooks/node.yml \
  playbooks/add-node.yml playbooks/upgrade.yml; do
  check "存在 $f" "[[ -f '$f' ]]"
done
check "存在目录 roles/" "[[ -d roles ]]"

echo "-- 内容约定"
check "ansible.cfg 设置 roles_path" "grep -q '^roles_path' ansible.cfg"
check "inventory 含 k8s_master 分组" "grep -q '^\[k8s_master\]' inventory/hosts.example"
check "inventory 含 etcd 分组" "grep -q '^\[etcd\]' inventory/hosts.example"
check "inventory 含 k8s_node 分组" "grep -q '^\[k8s_node\]' inventory/hosts.example"
check "site.yml 通过 import_playbook 引入 control-plane" "grep -q 'control-plane.yml' playbooks/site.yml"
check "site.yml 通过 import_playbook 引入 node" "grep -q 'node.yml' playbooks/site.yml"

echo "-- 语法检查"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i inventory/hosts.example --syntax-check playbooks/site.yml \
    >/tmp/opencode/t001_syntax.log 2>&1; then
    ok "ansible-playbook --syntax-check 通过"
  else
    bad "ansible-playbook --syntax-check 失败（见 /tmp/opencode/t001_syntax.log）"
  fi
else
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi

echo "-- 真实执行冒烟（防止「配置无效但静态检查假绿」）"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i localhost, -c local playbooks/site.yml \
    >/tmp/opencode/t001_smoke.log 2>&1; then
    ok "真实执行冒烟通过（配置可加载、playbook 可运行）"
  else
    bad "真实执行冒烟失败（见 /tmp/opencode/t001_smoke.log）"
  fi
else
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi

echo "-- YAML 风格"
if command -v "$YAMLLINT" >/dev/null 2>&1; then
  if "$YAMLLINT" -c .yamllint . >/tmp/opencode/t001_yamllint.log 2>&1; then
    ok "yamllint 通过"
  else
    bad "yamllint 失败（见 /tmp/opencode/t001_yamllint.log）"
  fi
else
  bad "找不到 yamllint"
fi

echo "-- make help"
# 注意：不能写成 `make help | grep -q`，grep -q 提前关管道会让 make 收 SIGPIPE(141)，
# 在 set -o pipefail 下会误判失败。先捕获输出再匹配。
help_out="$(make help 2>/dev/null || true)"
if grep -qE 'lint|syntax|test' <<<"$help_out"; then
  ok "make help 列出 lint/syntax/test"
else
  bad "make help 未列出 lint/syntax/test"
fi

echo "-- 密钥未入库（行为断言，非子串匹配）"
if git rev-parse --git-dir >/dev/null 2>&1; then
  ignore_ok=1
  for probe in secret.key secret.pem kubeconfig vault-password.txt inventory/hosts.ini; do
    if ! git check-ignore -q --no-index "$probe"; then
      bad "未被 .gitignore 忽略: $probe"
      ignore_ok=0
    fi
  done
  [[ $ignore_ok -eq 1 ]] && ok "密钥类探针均被 .gitignore 忽略"
  if git ls-files | grep -qiE '(\.key$|\.pem$|kubeconfig|vault[-_]?pass)'; then
    bad "git 跟踪了密钥类文件"
  else
    ok "git 未跟踪密钥类文件"
  fi
else
  bad "非 git 仓库：无法做忽略行为断言（请先 git init）"
fi

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
