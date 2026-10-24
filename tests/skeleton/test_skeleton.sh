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

echo "-- 密钥未入库（行为断言 + 探针自检，非子串匹配）"
# 只匹配「真实密钥/凭据产物」。任务/模板文件名里带 kubeconfig 子串的 .yml/.j2 不是凭据
# （历史缺陷：宽泛的 `kubeconfig` 子串把 tasks/kubeconfig_one.yml、tasks/kubeconfigs.yml 误报成密钥）。
# r2 M5：补真实凭据变体 —— `my-kubeconfig` / `kubeconfig-old` / `config.kubeconfig.bak` /
#        `admin.conf`（kubeconfig 类 .conf）等此前漏报的命名。
SECRET_RE='(^|/)kubeconfig($|\.)|(^|/)[^/]*\.kubeconfig($|\.)|(^|/)[^/]*[-_]kubeconfig($|\.)|(^|/)kubeconfig[-_][^/]*$|(^|/)[^/]*\.conf$|\.key$|\.pem$|(^|/)vault[-_]?pass[^/]*$'
# 单一判定（正则 + 文档/模板/任务文件排除）：探针、自检、端到端负例共用，避免「正则改一处、
# 自检改另一处」的保护失效。`kubeconfig.*`（如 kubeconfig.yaml）仍是凭据；`*.yml/*.yaml`
# 的任务/变量文件（kubeconfig_one.yml、sandbox_*.yml）不是。
is_secret_path() {
  local p="$1"
  printf '%s\n' "$p" | grep -qiE "$SECRET_RE" || return 1
  case "${p##*/}" in
    *.j2|*.md|*.sh|*.py) return 1 ;;
    kubeconfig.*) return 0 ;;
    *.yml|*.yaml) return 1 ;;
  esac
  return 0
}
secret_hits() { local p; while IFS= read -r p; do is_secret_path "$p" && printf '%s\n' "$p"; done; }
if git rev-parse --git-dir >/dev/null 2>&1; then
  ignore_ok=1
  for probe in secret.key secret.pem kubeconfig vault-password.txt inventory/hosts.ini; do
    if ! git check-ignore -q --no-index "$probe"; then
      bad "未被 .gitignore 忽略: $probe"
      ignore_ok=0
    fi
  done
  [[ $ignore_ok -eq 1 ]] && ok "密钥类探针均被 .gitignore 忽略"

  # 探针自检（防「收紧正则」变成「保护失效」）：
  #   正例：真实 kubeconfig（无扩展名 / 带扩展名 / *.kubeconfig / *-kubeconfig / kubeconfig-*）
  #         与 *.key / *.pem / kubeconfig 类 *.conf / vault 密码必须命中；
  #   负例：任务/模板/文档文件名（仅含 kubeconfig 子串）不得误报。
  self_fail=""
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    is_secret_path "$p" || self_fail+="漏报:$p "
  done <<'PATHS'
kubeconfig
etc/kubernetes/kubeconfig
admin.kubeconfig
my-kubeconfig
kubeconfig-old
config.kubeconfig.bak
admin.conf
controller-manager.conf
scheduler.conf
secrets/server.key
secrets/server.pem
vault-password.txt
vault_pass
roles/x/files/vault_password_file
PATHS
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    is_secret_path "$p" && self_fail+="误报:$p "
  done <<'PATHS'
roles/kube-apiserver/tasks/kubeconfig_one.yml
roles/kube-apiserver/tasks/kubeconfigs.yml
roles/kube-apiserver/templates/kubeconfig_file.j2
tests/control-plane/sandbox_control_plane.yml
docs/harness/state/contracts/T007.md
tasks/kubeconfig_one.yml
PATHS

  # 端到端负例：临时 git 仓库 + 真实凭据（无扩展名 kubeconfig、*-kubeconfig、*.conf）
  # 必须仍被判为「已跟踪」，证明收紧/扩正则没有削弱对真实凭据的保护
  # （临时仓库用后即删，主仓库 index 不受影响）。
  probe_repo="$(mktemp -d /tmp/opencode/t001_probe.XXXXXX)"
  if git -C "$probe_repo" init -q 2>/dev/null; then
    printf 'apiVersion: v1\nkind: Config\n' >"$probe_repo/kubeconfig"
    printf 'apiVersion: v1\nkind: Config\n' >"$probe_repo/my-kubeconfig"
    printf 'apiVersion: v1\nkind: Config\n' >"$probe_repo/admin.conf"
    if git -C "$probe_repo" add -f -- kubeconfig my-kubeconfig admin.conf 2>/dev/null &&
      [[ "$(git -C "$probe_repo" ls-files | secret_hits | wc -l)" -eq 3 ]]; then
      :
    else
      self_fail+="端到端漏报:临时仓库 kubeconfig/my-kubeconfig/admin.conf "
    fi
  else
    self_fail+="无法创建临时 git 仓库 "
  fi
  rm -rf "$probe_repo"

  if [[ -n "$self_fail" ]]; then
    bad "密钥探针自检失败（$self_fail）"
  elif hits="$(git ls-files | secret_hits)" && [[ -n "$hits" ]]; then
    bad "git 跟踪了真实密钥/凭据文件: $(tr '\n' ' ' <<<"$hits")"
  else
    ok "git 未跟踪真实密钥/凭据（探针自检：真实 kubeconfig 仍会被判为跟踪）"
  fi
else
  bad "非 git 仓库：无法做忽略行为断言（请先 git init）"
fi

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
