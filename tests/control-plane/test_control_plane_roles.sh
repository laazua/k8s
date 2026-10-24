#!/usr/bin/env bash
# =============================================================================
# T007 控制平面组件 role 验收测试（TDD：先红后绿）
#   静态：结构 / 变量化 / 安全默认 / unit 模板 / 服务接线 / 语法 / 风格。
#   动态：沙箱内**真实** pki → **真实单成员 TLS etcd** → **真实 kube-apiserver /
#         kube-controller-manager / kube-scheduler**（高位端口，从 role 渲染的
#         unit 的 ExecStart 拉起）→ healthz/readyz/ns/匿名拒绝/身份/幂等/fail-fast。
#   受限：不写宿主 /etc/systemd/system、不 systemctl、不占默认端口；trap 全量清理。
#   用法: tests/control-plane/test_control_plane_roles.sh
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
mkdir -p /tmp/opencode

pass_count=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
changed_of() { grep -oE 'changed=[0-9]+' "$1" 2>/dev/null | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
snapshot_path() {
  local p="$1"
  if [[ -e "$p" ]]; then
    if [[ -f "$p" ]]; then sha_of "$p"; else stat -c '%F %a' "$p"; fi
  else printf '__MISSING__'; fi
}
snapshot_ports() {
  ss -ltn 2>/dev/null | grep -E ':(6443|10257|10259|16443|20257|20259|12379)[[:space:]]' \
    | awk '{print $4}' | sort | tr '\n' ' '
}

# --- Ansible 探测 -----------------------------------------------------------
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook 2>/dev/null || echo "$HOME/ansible/bin/ansible-playbook")}"
if [[ "$ANSIBLE_PLAYBOOK" == */ansible/bin/ansible-playbook ]]; then
  export PYTHONPATH="$(dirname "$(dirname "$ANSIBLE_PLAYBOOK")"):${PYTHONPATH:-}"
fi
have_ansible() { command -v "$ANSIBLE_PLAYBOOK" >/dev/null 2>&1 || [[ -x "$ANSIBLE_PLAYBOOK" ]]; }
YAMLLINT="${YAMLLINT:-yamllint}"

ROLE_APISERVER=roles/kube-apiserver
ROLE_CM=roles/kube-controller-manager
ROLE_SCHED=roles/kube-scheduler
PLAY_STACK=tests/control-plane/sandbox_stack.yml
PLAY_CP=tests/control-plane/sandbox_control_plane.yml
INV=tests/control-plane/inventory.ini
UNIT_EXEC=tests/etcd/unit_exec.py

VERSION=1.31.0
CACHE="${T007_TEST_CACHE:-/tmp/opencode/k8s-cache}"
KUBECTL_SHA=7c27adc64a84d1c0cc3dcf7bf4b6e916cc00f3f576a2dbac51b318d926032437
declare -A ART_SHA=(
  [kube-apiserver]=9016f6048ff9827ef58934e98f28a8026634c10b4e6fcc1df49451038a23a9aa
  [kube-controller-manager]=9cf02d0ebf704ffdc727d0ad02e64bc5621f8013c4034b568bf7c939fe150490
  [kube-scheduler]=1e519991d41389bb885df59c19389afe847dad511992d009ff766bc7f3992f89
  [kubectl]="$KUBECTL_SHA"
)

echo "== T007 控制平面组件 role 验收 =="

echo "-- A1 role / 测试资产结构"
for r in "$ROLE_APISERVER" "$ROLE_CM" "$ROLE_SCHED"; do
  for f in defaults/main.yml tasks/main.yml tasks/facts.yml tasks/validate.yml \
    tasks/binary.yml tasks/config.yml tasks/service.yml handlers/main.yml \
    meta/main.yml README.md; do
    check "存在 $r/$f" "[[ -f '$r/$f' ]]"
  done
done
check "存在 $ROLE_APISERVER/templates/kube-apiserver.service.j2" \
  "[[ -f '$ROLE_APISERVER/templates/kube-apiserver.service.j2' ]]"
check "存在 $ROLE_CM/templates/kube-controller-manager.service.j2" \
  "[[ -f '$ROLE_CM/templates/kube-controller-manager.service.j2' ]]"
check "存在 $ROLE_SCHED/templates/kube-scheduler.service.j2" \
  "[[ -f '$ROLE_SCHED/templates/kube-scheduler.service.j2' ]]"
# role 引用的模板必须**同时**存在于工作区且已入库（防止 .gitignore 吞掉交付资产）。
# 注：模板名不叫 kubeconfig.j2 —— 该名字被 .gitignore 的 `kubeconfig.*` 规则忽略（T007 r1 B1）；
# 无 .git 的 `git archive` 检出无法做跟踪断言，跳过（此时归档内容即真相）。
role_template_sources() {
  grep -rhoE '^[[:space:]]*src:[[:space:]]*[A-Za-z0-9_.-]+\.j2' "$1"/tasks \
    | sed -E 's/^[[:space:]]*src:[[:space:]]*//' | sort -u
}
templates_tracked() {
  local r="$1" s
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    [[ -f "$r/templates/$s" ]] || return 1
    if git rev-parse --git-dir >/dev/null 2>&1; then
      git ls-files --error-unmatch "$r/templates/$s" >/dev/null 2>&1 || return 1
    fi
  done < <(role_template_sources "$r")
  return 0
}
check "存在 $ROLE_APISERVER/templates/kubeconfig_file.j2 且三 role 模板均已入库" \
  "[[ -f '$ROLE_APISERVER/templates/kubeconfig_file.j2' ]] && \
   templates_tracked '$ROLE_APISERVER' && templates_tracked '$ROLE_CM' && templates_tracked '$ROLE_SCHED'"
for f in "$PLAY_STACK" "$PLAY_CP" "$INV" "$UNIT_EXEC"; do
  check "存在 $f" "[[ -f '$f' ]]"
done

echo "-- A2 变量化 / 复用全局变量"
for r in "$ROLE_APISERVER" "$ROLE_CM" "$ROLE_SCHED"; do
  d="$r/defaults/main.yml"
  check "$r defaults 复用 k8s_version" "grep -q 'k8s_version' '$d'"
  check "$r defaults 复用 k8s_artifact_dir" "grep -q 'k8s_artifact_dir' '$d'"
  check "$r defaults 复用 k8s_bin_dir" "grep -q 'k8s_bin_dir' '$d'"
  check "$r defaults 复用 k8s_config_dir" "grep -q 'k8s_config_dir' '$d'"
  check "$r defaults 复用 kube_systemd_dir" "grep -q 'kube_systemd_dir' '$d'"
  check "$r defaults 提供下载 URL（含版本/架构）" \
    "grep -q 'download_url_base' '$d' && grep -q 'bin/linux' '$d'"
  check "$r defaults 固定 ${VERSION} sha256" "grep -q '\"${VERSION}\"' '$d'"
  check "$r defaults 提供服务管理开关" "grep -q '_manage_service: true' '$d'"
  check "$r defaults 提供 unit 路径（可重定向）" "grep -q '_unit_dir:' '$d'"
done
check "tasks 中无硬编码 IPv4" \
  "! grep -rqE '([0-9]{1,3}\\.){3}[0-9]{1,3}' $ROLE_APISERVER/tasks $ROLE_CM/tasks $ROLE_SCHED/tasks"
check "tasks 中无硬编码 6443/10257/10259/2379" \
  "! grep -rqE '(^|[^0-9])(6443|10257|10259|2379)([^0-9]|$)' $ROLE_APISERVER/tasks $ROLE_CM/tasks $ROLE_SCHED/tasks"
check "tasks 中无硬编码 /etc/systemd/system" \
  "! grep -rq '/etc/systemd/system' $ROLE_APISERVER/tasks $ROLE_CM/tasks $ROLE_SCHED/tasks"
check "tasks 中无硬编码 /etc/kubernetes" \
  "! grep -rq '/etc/kubernetes' $ROLE_APISERVER/tasks $ROLE_CM/tasks $ROLE_SCHED/tasks"
check "tasks 中无硬编码下载 URL" \
  "! grep -rqE 'https?://' $ROLE_APISERVER/tasks $ROLE_CM/tasks $ROLE_SCHED/tasks"
check "三个 role 使用 FQCN ansible.builtin" \
  "grep -rq 'ansible\\.builtin\\.' $ROLE_APISERVER/tasks && \
   grep -rq 'ansible\\.builtin\\.' $ROLE_CM/tasks && \
   grep -rq 'ansible\\.builtin\\.' $ROLE_SCHED/tasks"

echo "-- A3 apiserver unit 模板（安全 / 重启 / 资源 / 启动顺序）"
T_UNIT_APISERVER="$ROLE_APISERVER/templates/kube-apiserver.service.j2"
check "A3 apiserver ExecStart 使用变量二进制 + 参数列表" \
  "grep -q 'ExecStart={{ kube_apiserver_binary }} {{ kube_apiserver_args | join' '$T_UNIT_APISERVER'"
check "A3 apiserver unit Restart=always" "grep -q '^Restart=always' '$T_UNIT_APISERVER'"
check "A3 apiserver unit RestartSec" "grep -q '^RestartSec=' '$T_UNIT_APISERVER'"
check "A3 apiserver unit LimitNOFILE" "grep -q '^LimitNOFILE=' '$T_UNIT_APISERVER'"
check "A3 apiserver unit After=network-online.target" \
  "grep -q '^After=network-online.target' '$T_UNIT_APISERVER'"
check "A3 apiserver unit WantedBy=multi-user.target" \
  "grep -q '^WantedBy=multi-user.target' '$T_UNIT_APISERVER'"
check "A3 apiserver unit 无硬编码端口" \
  "! grep -qE '(6443|16443|10257|10259)' '$T_UNIT_APISERVER'"
check "A3 apiserver defaults 安全默认 anonymous-auth=false" \
  "grep -qE '^kube_apiserver_anonymous_auth:[[:space:]]*false' '$ROLE_APISERVER/defaults/main.yml'"
check "A3 apiserver defaults 授权模式含 RBAC" \
  "grep -qE '^kube_apiserver_authorization_mode:[[:space:]]*\"RBAC' '$ROLE_APISERVER/defaults/main.yml'"
check "A3 apiserver facts 渲染 --anonymous-auth" \
  "grep -q -- '--anonymous-auth=' '$ROLE_APISERVER/tasks/facts.yml'"
check "A3 apiserver facts 渲染 --authorization-mode" \
  "grep -q -- '--authorization-mode=' '$ROLE_APISERVER/tasks/facts.yml'"
check "A3 apiserver facts 渲染 --client-ca-file" \
  "grep -q -- '--client-ca-file=' '$ROLE_APISERVER/tasks/facts.yml'"
check "A3 apiserver facts 渲染 ServiceAccount 签名参数" \
  "grep -q -- '--service-account-key-file=' '$ROLE_APISERVER/tasks/facts.yml' && \
   grep -q -- '--service-account-signing-key-file=' '$ROLE_APISERVER/tasks/facts.yml'"
check "A3 无 --insecure-port（已移除的不安全选项）" \
  "! grep -rq -- '--insecure-port' $ROLE_APISERVER $ROLE_CM $ROLE_SCHED"
check "A3 apiserver 强制安全默认校验" \
  "grep -q 'require_secure_defaults' '$ROLE_APISERVER/tasks/validate.yml'"

echo "-- A4 cm / scheduler unit 模板"
for pair in "$ROLE_CM:kube-controller-manager" "$ROLE_SCHED:kube-scheduler"; do
  r="${pair%%:*}"; n="${pair##*:}"
  t="$r/templates/$n.service.j2"
  check "A4 $n ExecStart 使用变量二进制 + 参数列表" \
    "grep -q \"ExecStart={{ ${n//-/_}_binary }} {{ ${n//-/_}_args | join\" '$t'"
  check "A4 $n Restart=always" "grep -q '^Restart=always' '$t'"
  check "A4 $n LimitNOFILE" "grep -q '^LimitNOFILE=' '$t'"
  check "A4 $n After=network-online.target" "grep -q '^After=network-online.target' '$t'"
  check "A4 $n WantedBy=multi-user.target" "grep -q '^WantedBy=multi-user.target' '$t'"
  check "A4 $n facts 含 --kubeconfig" \
    "grep -q -- '--kubeconfig=' '$r/tasks/facts.yml'"
  check "A4 $n facts 含 delegated authentication kubeconfig" \
    "grep -q -- '--authentication-kubeconfig=' '$r/tasks/facts.yml' && \
     grep -q -- '--authorization-kubeconfig=' '$r/tasks/facts.yml'"
  check "A4 $n facts 含 --leader-elect" "grep -q -- '--leader-elect=' '$r/tasks/facts.yml'"
done
check "A4 cm facts 含 SA/CA 签名参数" \
  "grep -q -- '--service-account-private-key-file=' '$ROLE_CM/tasks/facts.yml' && \
   grep -q -- '--cluster-signing-cert-file=' '$ROLE_CM/tasks/facts.yml'"

echo "-- A5 控制面引导（kubeconfig / 客户端证书）"
check "A5 apiserver defaults 管理 kubeconfig" \
  "grep -qE '^kube_apiserver_manage_kubeconfigs:[[:space:]]*true' '$ROLE_APISERVER/defaults/main.yml'"
check "A5 签发 controller-manager 客户端证书" \
  "grep -q 'system:kube-controller-manager' '$ROLE_APISERVER/defaults/main.yml'"
check "A5 签发 scheduler 客户端证书" \
  "grep -q 'system:kube-scheduler' '$ROLE_APISERVER/defaults/main.yml'"
check "A5 签发 apiserver-kubelet-client 证书" \
  "grep -q 'kube-apiserver-kubelet-client' '$ROLE_APISERVER/defaults/main.yml'"
check "A5 渲染 kubeconfig（内嵌证书/私钥）" \
  "grep -q 'client-certificate-data' '$ROLE_APISERVER/templates/kubeconfig_file.j2' && \
   grep -q 'client-key-data' '$ROLE_APISERVER/templates/kubeconfig_file.j2'"
check "A5 kubeconfig 0600" \
  "grep -qE '^kube_apiserver_kubeconfig_mode:[[:space:]]*\"0600\"' '$ROLE_APISERVER/defaults/main.yml'"

echo "-- A6 systemd 服务接线（active+enabled 的静态部分）"
for pair in "$ROLE_APISERVER:kube_apiserver" "$ROLE_CM:kube_controller_manager" "$ROLE_SCHED:kube_scheduler"; do
  r="${pair%%:*}"; v="${pair##*:}"
  check "A6 $r service.yml 使用 ansible.builtin.systemd" \
    "grep -q 'ansible.builtin.systemd' '$r/tasks/service.yml'"
  check "A6 $r service.yml 设置 enabled" "grep -q 'enabled:' '$r/tasks/service.yml'"
  check "A6 $r service.yml daemon_reload" "grep -q 'daemon_reload: true' '$r/tasks/service.yml'"
  check "A6 $r defaults enabled=true" "grep -qE '^${v}_service_enabled:[[:space:]]*true' '$r/defaults/main.yml'"
  check "A6 $r defaults state=started" "grep -qE '^${v}_service_state:[[:space:]]*started' '$r/defaults/main.yml'"
  check "A6 $r handler 使用 restarted" "grep -q 'state: restarted' '$r/handlers/main.yml'"
done

echo "-- A7 文档"
for r in "$ROLE_APISERVER" "$ROLE_CM" "$ROLE_SCHED"; do
  check "A7 $r README 说明变量与验证方式" \
    "grep -qi '变量' '$r/README.md' && grep -qi '验证' '$r/README.md'"
done
check "A7 apiserver README 声明 systemd 受限验证" \
  "grep -qi 'systemd' '$ROLE_APISERVER/README.md'"

echo "-- A8 范围约束（不接入 site.yml；不改已验收资产）"
check "playbooks/site.yml 未引用控制面 role" \
  "! grep -qE 'kube-apiserver|kube-controller-manager|kube-scheduler' playbooks/site.yml"
if git rev-parse --git-dir >/dev/null 2>&1; then
  frozen="tests/skeleton tests/base tests/download tests/pki tests/etcd tests/ha roles/base roles/download roles/pki roles/etcd roles/haproxy roles/keepalived"
  dirty="$(git status --porcelain -- $frozen | wc -l)"
  check "已 PASS 的 roles/tests 未被改动" "[[ $dirty -eq 0 ]]"
  check "工作区无未忽略的密钥/证书/kubeconfig" \
    "! git status --porcelain | grep -qE '\\.(key|crt|pem|conf)$'"
fi

echo "-- A9 语法与风格"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_STACK" >/tmp/opencode/t007_syntax_stack.log 2>&1; then
    ok "$PLAY_STACK --syntax-check 通过"
  else
    bad "$PLAY_STACK --syntax-check 失败（见 /tmp/opencode/t007_syntax_stack.log）"
  fi
  if "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY_CP" >/tmp/opencode/t007_syntax_cp.log 2>&1 &&
    "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check tests/control-plane/real_services.yml \
      >>/tmp/opencode/t007_syntax_cp.log 2>&1; then
    ok "$PLAY_CP + real_services.yml --syntax-check 通过（真机复验 playbook 可执行）"
  else
    bad "$PLAY_CP / real_services.yml --syntax-check 失败（见 /tmp/opencode/t007_syntax_cp.log）"
  fi
else
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi
if command -v "$YAMLLINT" >/dev/null 2>&1; then
  if "$YAMLLINT" -c .yamllint "$ROLE_APISERVER" "$ROLE_CM" "$ROLE_SCHED" tests/control-plane \
    >/tmp/opencode/t007_yamllint.log 2>&1; then
    ok "yamllint（roles/kube-*, tests/control-plane）无 error"
  else
    bad "yamllint 失败（见 /tmp/opencode/t007_yamllint.log）"
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
if [[ ! -d "$ROLE_APISERVER" || ! -d "$ROLE_CM" || ! -d "$ROLE_SCHED" ]]; then
  bad "控制面 role 不存在：结构/变量/动态用例均无法执行（红阶段）"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi
if ! sudo -n true 2>/dev/null; then
  bad "需要免密 sudo：以 root 应用属主模型并从 unit 拉起真实控制面进程"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi

ensure_artifact() {  # ensure_artifact <name> <url> <sha>
  local p="$CACHE/$1"
  if [[ -f "$p" && "$(sha_of "$p")" == "$3" ]]; then return 0; fi
  printf '  （首次运行：缓存官方制品 %s）\n' "$1"
  curl -fL --retry 3 --connect-timeout 20 -o "$p.tmp" "$2" || return 1
  mv "$p.tmp" "$p"
  [[ "$(sha_of "$p")" == "$3" ]]
}
for b in kube-apiserver kube-controller-manager kube-scheduler kubectl; do
  if ! ensure_artifact "$b" "https://dl.k8s.io/v${VERSION}/bin/linux/amd64/$b" "${ART_SHA[$b]}"; then
    bad "无法获取/校验官方制品 $b"
    echo
    echo "== 汇总: PASS=$pass_count FAIL=$fail =="
    exit 1
  fi
done
ok "4 个官方制品缓存可用（sha256 与 defaults 一致）"

# etcd 发行包同样走本地缓存：stack playbook 的 etcd play 需要它，
# 不预置的话每次首跑都会从 storage.googleapis.com 重下（同 M4 的非密闭缺陷）。
ETCD_TARBALL="etcd-v3.5.16-linux-amd64.tar.gz"
ETCD_TARBALL_SHA=b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc
ensure_etcd_tarball() {
  local p="$CACHE/$ETCD_TARBALL" seed="${ETCD_TEST_CACHE:-/tmp/opencode/etcd-cache}/$ETCD_TARBALL"
  [[ -f "$p" && "$(sha_of "$p")" == "$ETCD_TARBALL_SHA" ]] && return 0
  if [[ -f "$seed" && "$(sha_of "$seed")" == "$ETCD_TARBALL_SHA" ]]; then
    cp "$seed" "$p" && return 0
  fi
  printf '  （首次运行：缓存 etcd 发行包 %s）\n' "$ETCD_TARBALL"
  curl -fL --retry 3 --connect-timeout 20 -o "$p.tmp" \
    "https://storage.googleapis.com/etcd/v3.5.16/$ETCD_TARBALL" || return 1
  mv "$p.tmp" "$p"
  [[ "$(sha_of "$p")" == "$ETCD_TARBALL_SHA" ]]
}
if ! ensure_etcd_tarball; then
  bad "无法获取/校验 etcd 发行包 $ETCD_TARBALL"
  echo
  echo "== 汇总: PASS=$pass_count FAIL=$fail =="
  exit 1
fi
printf '  （etcd 发行包缓存就绪：%s）\n' "$ETCD_TARBALL"

# --- B0 密闭性门禁（不计入既有断言基线；失败即套件失败）--------------------
# 缺陷背景（T007 r2 M4）：kubectl 曾用显式 dest 直指 usr/local/bin，绕过 download
# role 的制品缓存，每次首跑都直连 dl.k8s.io；CDN 限速时全量门禁第二次必红。
# 该门禁把「测试不依赖外网」变成硬约束：
#   静态：stack playbook 的 kubectl 下载项必须落制品缓存，不得直写 bin；
#   动态：缓存已就位 + kubectl_url 指向不可达地址（可用时再叠加 unshare -n 真断网，
#         新 netns 仅 lo、无默认路由），stack 仍须 exit 0 且装出的 kubectl sha256 正确。
#         缓存命中时 get_url 不发请求，因此任何真实网络依赖都会在此立即失败。
stack_uses_cache() {
  # 下载项必须落制品缓存（download_items 内不写显式 dest → 默认 download_cache_dir），
  # 且沙箱 bin 只能由「从缓存 copy」产生（不允许下载项直写 usr/local/bin）。
  local block
  block="$(sed -n '/^    download_items:/,/^  roles:/p' "$PLAY_STACK")"
  grep -qE 'src:[[:space:]]*"\{\{ download_cache_dir \}\}/kubectl"' "$PLAY_STACK" &&
    ! grep -qE '^[[:space:]]+dest:' <<<"$block"
}
stack_offline_ok() {  # stack_offline_ok <sandbox> <log>
  local sb="$1" log="$2" inner rc
  local json="{\"sandbox_root\":\"$sb\",\"kubectl_url\":\"http://127.0.0.1:1/kubectl\"}"
  if sudo -n unshare -n true >/dev/null 2>&1; then
    # 真断网：新 netns 仅 lo、无默认路由（等价 unshare -rn；保留 root 以便 become）
    inner="ip link set lo up; cd $(printf '%q' "$PWD") && timeout 300 $(printf '%q' "$ANSIBLE_PLAYBOOK") -i $(printf '%q' "$INV") $(printf '%q' "$PLAY_STACK") -e $(printf '%q' "$json")"
    sudo -n env PYTHONPATH="${PYTHONPATH:-}" unshare -n bash -c "$inner" >"$log" 2>&1
    rc=$?
  else
    timeout 300 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_STACK" -e "$json" >"$log" 2>&1
    rc=$?
  fi
  return $rc
}
OFF_SB="$(mktemp -d /tmp/opencode/t007off.XXXXXX)"
chmod 0755 "$OFF_SB"
mkdir -p "$OFF_SB/opt/k8s/artifacts" "$OFF_SB/etc" "$OFF_SB/var"
chmod 0755 "$OFF_SB/etc" "$OFF_SB/var"
cp "$CACHE/kubectl" "$OFF_SB/opt/k8s/artifacts/kubectl"
cp "$CACHE/$ETCD_TARBALL" "$OFF_SB/opt/k8s/artifacts/$ETCD_TARBALL"
chmod 0644 "$OFF_SB"/opt/k8s/artifacts/*
OFF_SHA=""
if stack_uses_cache && stack_offline_ok "$OFF_SB" /tmp/opencode/t007_offline_stack.log; then
  OFF_SHA="$(sha_of "$OFF_SB/usr/local/bin/kubectl")"
fi
if [[ "$OFF_SHA" == "$KUBECTL_SHA" ]]; then
  if sudo -n unshare -n true >/dev/null 2>&1; then
    printf '  \033[32mOK\033[0m   B0 密闭性：kubectl 从制品缓存安装（unshare -n 断网 + 不可达 URL 下 stack exit 0）\n'
  else
    printf '  \033[32mOK\033[0m   B0 密闭性：kubectl 从制品缓存安装（不可达 URL 下 stack exit 0）\n'
  fi
else
  bad "B0 密闭性失败：kubectl 未命中本地制品缓存（不可达 URL 下 stack 未 exit 0；见 /tmp/opencode/t007_offline_stack.log）"
fi
sudo -n rm -rf "$OFF_SB"

# 宿主零污染快照
PRE_HOST_UNITS="$(ls /etc/systemd/system/kube-*.service 2>/dev/null | sort | tr '\n' ' ')"
PRE_ETC_K8S="$(snapshot_path /etc/kubernetes)"
PRE_PORTS="$(snapshot_ports)"

SB=""
ETCD_PID=""
declare -A PID=()
declare -A WRAPPER=()
KUBECTL=""

stop_proc() {  # stop_proc <pattern>
  local pat="$1" i
  sudo -n pkill -9 -f -- "$pat" 2>/dev/null || true
  for ((i = 0; i < 40; i++)); do
    pgrep -f -- "$pat" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 0
}
cleanup() {
  local k
  for k in "${!WRAPPER[@]}"; do
    wait "${WRAPPER[$k]}" 2>/dev/null || true
  done
  [[ -n "${SB:-}" ]] || return 0
  stop_proc "$SB/usr/local/bin/kube-apiserver"
  stop_proc "$SB/usr/local/bin/kube-controller-manager"
  stop_proc "$SB/usr/local/bin/kube-scheduler"
  stop_proc "$SB/usr/local/bin/etcd"
  sudo -n rm -rf "$SB" 2>/dev/null || true
}
trap cleanup EXIT

port_free() {
  ! ss -ltn 2>/dev/null | grep -qE ':(16443|20257|20259|12379)[[:space:]]'
}
wait_port() {  # wait_port <port>：等待组件安全端口真正监听（进程启动到 bind 有间隔）
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

SB="$(mktemp -d /tmp/opencode/t007.XXXXXX)"
chmod 0755 "$SB"
mkdir -p "$SB/opt/k8s/artifacts" "$SB/logs" "$SB/client" "$SB/kubectl-cache" "$SB/etc" "$SB/var"
chmod 0755 "$SB/etc" "$SB/var"
for b in kube-apiserver kube-controller-manager kube-scheduler kubectl "$ETCD_TARBALL"; do
  cp "$CACHE/$b" "$SB/opt/k8s/artifacts/$b"
done
chmod 0644 "$SB"/opt/k8s/artifacts/*
ok "沙箱制品已就绪（$SB）"

ap() {  # ap <playbook> <log> [额外的 -e json]
  local play="$1" log="$2"
  shift 2
  timeout 600 "$ANSIBLE_PLAYBOOK" -i "$INV" "$play" "$@" >"$log" 2>&1
}

echo "-- B1 pki + 单成员 TLS etcd 沙箱"
if ap "$PLAY_STACK" /tmp/opencode/t007_stack.log -e "{\"sandbox_root\":\"$SB\"}"; then
  ok "stack playbook exit 0（kubectl + pki + etcd 渲染）"
else
  bad "stack playbook 失败（见 /tmp/opencode/t007_stack.log）"
fi
check "B1 pki 产出 apiserver 证书" "sudo -n test -f '$SB/etc/kubernetes/pki/apiserver.crt'"
check "B1 pki 产出 admin 证书/私钥" \
  "sudo -n test -f '$SB/etc/kubernetes/pki/admin.crt' && sudo -n test -f '$SB/etc/kubernetes/pki/admin.key'"
check "B1 pki 产出 SA 密钥对" \
  "sudo -n test -f '$SB/etc/kubernetes/pki/sa.pub' && sudo -n test -f '$SB/etc/kubernetes/pki/sa.key'"
check "B1 pki 产出 apiserver-etcd-client 证书" \
  "sudo -n test -f '$SB/etc/kubernetes/pki/apiserver-etcd-client.crt'"
check "B1 etcd unit 已渲染" "sudo -n test -f '$(unit_path etcd-etcd1)'"
check "B1 kubectl 已安装到沙箱" "[[ -x '$SB/usr/local/bin/kubectl' ]]"

ETCD_UNIT="$(unit_path etcd-etcd1)"
mapfile -t ETCD_ARGS < <(python3 "$UNIT_EXEC" "$ETCD_UNIT")
if [[ ${#ETCD_ARGS[@]} -gt 0 ]]; then
  ( sudo -n setpriv --reuid 65534 --regid 65534 --clear-groups \
      "${ETCD_ARGS[@]}" </dev/null >>"$SB/logs/etcd.log" 2>&1 ) &
  WRAPPER[etcd]=$!
  for _ in $(seq 1 100); do ETCD_PID="$(proc_pid etcd)"; [[ -n "$ETCD_PID" ]] && break; sleep 0.1; done
  ok "已从 etcd unit 拉起单成员 TLS etcd（PID ${ETCD_PID:-?}）"
else
  bad "无法解析 etcd unit 的 ExecStart"
fi

# etcdctl 客户端材料（root 0600 → 复制给测试用户）
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
check "B1 单成员 etcd healthy（真实 TLS）" "wait_etcd"

echo "-- B2 控制面 role 首次渲染（沙箱）"
if ap "$PLAY_CP" /tmp/opencode/t007_cp_run1.log -e "{\"sandbox_root\":\"$SB\"}"; then
  ok "控制面 playbook 首跑 exit 0"
else
  bad "控制面 playbook 首跑失败（见 /tmp/opencode/t007_cp_run1.log）"
fi
C1="$(changed_of /tmp/opencode/t007_cp_run1.log)"
check "B2 首跑 changed>0（真实安装/渲染）" "[[ ${C1:-0} -gt 0 ]]"

UNIT_API="$(unit_path kube-apiserver)"
UNIT_CM="$(unit_path kube-controller-manager)"
UNIT_SCHED="$(unit_path kube-scheduler)"
for u in "$UNIT_API" "$UNIT_CM" "$UNIT_SCHED"; do
  check "B2 已渲染 unit $(basename "$u")" "sudo -n test -f '$u'"
  check "B2 unit $(basename "$u") 属主 root:root 0644" \
    "[[ \"\$(sudo -n stat -c '%u:%g %a' '$u' 2>/dev/null)\" == '0:0 644' ]]"
done
for b in kube-apiserver kube-controller-manager kube-scheduler; do
  check "B2 二进制 $b 已安装且可执行" "sudo -n test -x '$SB/usr/local/bin/$b'"
  check "B2 二进制 $b 版本 = $VERSION" \
    "'$SB/usr/local/bin/$b' --version 2>/dev/null | grep -q 'v${VERSION}'"
done

echo "-- B3 apiserver unit 内容（关键 flag）"
check "B3 apiserver ExecStart 使用沙箱二进制" "grep -q '^ExecStart=$SB/usr/local/bin/kube-apiserver ' '$UNIT_API'"
check "B3 apiserver --advertise-address=127.0.0.1" "grep -q -- '--advertise-address=127.0.0.1' '$UNIT_API'"
check "B3 apiserver --bind-address=127.0.0.1" "grep -q -- '--bind-address=127.0.0.1' '$UNIT_API'"
check "B3 apiserver --secure-port=16443（高位，不占默认端口）" \
  "grep -q -- '--secure-port=16443' '$UNIT_API'"
check "B3 apiserver --etcd-servers 来自 inventory" \
  "grep -q -- '--etcd-servers=https://127.0.0.1:12379' '$UNIT_API'"
check "B3 apiserver etcd CA/客户端证书参数" \
  "grep -q -- '--etcd-cafile=$SB/etc/kubernetes/pki/etcd/ca.crt' '$UNIT_API' && \
   grep -q -- '--etcd-certfile=$SB/etc/kubernetes/pki/apiserver-etcd-client.crt' '$UNIT_API' && \
   grep -q -- '--etcd-keyfile=$SB/etc/kubernetes/pki/apiserver-etcd-client.key' '$UNIT_API'"
check "B3 apiserver TLS 服务证书参数" \
  "grep -q -- '--tls-cert-file=$SB/etc/kubernetes/pki/apiserver.crt' '$UNIT_API' && \
   grep -q -- '--tls-private-key-file=$SB/etc/kubernetes/pki/apiserver.key' '$UNIT_API'"
check "B3 apiserver --client-ca-file" \
  "grep -q -- '--client-ca-file=$SB/etc/kubernetes/pki/ca.crt' '$UNIT_API'"
check "B3 apiserver --kubelet-client-certificate/key" \
  "grep -q -- '--kubelet-client-certificate=$SB/etc/kubernetes/pki/apiserver-kubelet-client.crt' '$UNIT_API' && \
   grep -q -- '--kubelet-client-key=$SB/etc/kubernetes/pki/apiserver-kubelet-client.key' '$UNIT_API'"
check "B3 apiserver 安全默认 --anonymous-auth=false" \
  "grep -q -- '--anonymous-auth=false' '$UNIT_API'"
check "B3 apiserver --authorization-mode=RBAC,Node" \
  "grep -q -- '--authorization-mode=RBAC,Node' '$UNIT_API'"
check "B3 apiserver ServiceAccount key/signing key/issuer" \
  "grep -q -- '--service-account-key-file=$SB/etc/kubernetes/pki/sa.pub' '$UNIT_API' && \
   grep -q -- '--service-account-signing-key-file=$SB/etc/kubernetes/pki/sa.key' '$UNIT_API' && \
   grep -q -- '--service-account-issuer=https://kubernetes.default.svc.cluster.local' '$UNIT_API'"
check "B3 apiserver --service-cluster-ip-range 来自变量" \
  "grep -q -- '--service-cluster-ip-range=10.96.0.0/12' '$UNIT_API'"
check "B3 apiserver front-proxy / requestheader 参数" \
  "grep -q -- '--requestheader-client-ca-file=' '$UNIT_API' && \
   grep -q -- '--proxy-client-cert-file=' '$UNIT_API' && \
   grep -q -- '--requestheader-allowed-names=front-proxy-client' '$UNIT_API'"
check "B3 apiserver 准入 NodeRestriction" \
  "grep -q -- '--enable-admission-plugins=NodeRestriction' '$UNIT_API'"
check "B3 apiserver Restart=always" "grep -q '^Restart=always' '$UNIT_API'"
check "B3 apiserver LimitNOFILE=65536" "grep -q '^LimitNOFILE=65536' '$UNIT_API'"
check "B3 apiserver After=network-online.target" "grep -q '^After=network-online.target' '$UNIT_API'"
check "B3 apiserver WantedBy=multi-user.target" "grep -q '^WantedBy=multi-user.target' '$UNIT_API'"
check "B3 apiserver User=root / Type=simple" \
  "grep -q '^User=root' '$UNIT_API' && grep -q '^Type=simple' '$UNIT_API'"
check "B3 apiserver 无 --insecure-port" "! grep -q -- '--insecure-port' '$UNIT_API'"

echo "-- B4 cm / scheduler unit 内容"
check "B4 cm ExecStart 使用沙箱二进制" \
  "grep -q '^ExecStart=$SB/usr/local/bin/kube-controller-manager ' '$UNIT_CM'"
check "B4 cm --kubeconfig=controller-manager.conf" \
  "grep -q -- '--kubeconfig=$SB/etc/kubernetes/controller-manager.conf' '$UNIT_CM'"
check "B4 cm delegated authentication/authorization kubeconfig" \
  "grep -q -- '--authentication-kubeconfig=$SB/etc/kubernetes/controller-manager.conf' '$UNIT_CM' && \
   grep -q -- '--authorization-kubeconfig=$SB/etc/kubernetes/controller-manager.conf' '$UNIT_CM'"
check "B4 cm --client-ca-file / requestheader" \
  "grep -q -- '--client-ca-file=' '$UNIT_CM' && grep -q -- '--requestheader-client-ca-file=' '$UNIT_CM'"
check "B4 cm SA/CA 签名参数" \
  "grep -q -- '--service-account-private-key-file=$SB/etc/kubernetes/pki/sa.key' '$UNIT_CM' && \
   grep -q -- '--root-ca-file=$SB/etc/kubernetes/pki/ca.crt' '$UNIT_CM' && \
   grep -q -- '--cluster-signing-cert-file=$SB/etc/kubernetes/pki/ca.crt' '$UNIT_CM' && \
   grep -q -- '--cluster-signing-key-file=$SB/etc/kubernetes/pki/ca.key' '$UNIT_CM'"
check "B4 cm --use-service-account-credentials=true" \
  "grep -q -- '--use-service-account-credentials=true' '$UNIT_CM'"
check "B4 cm --leader-elect=true" "grep -q -- '--leader-elect=true' '$UNIT_CM'"
check "B4 cm --secure-port=20257 / bind 127.0.0.1" \
  "grep -q -- '--secure-port=20257' '$UNIT_CM' && grep -q -- '--bind-address=127.0.0.1' '$UNIT_CM'"
check "B4 cm Restart=always / LimitNOFILE / After" \
  "grep -q '^Restart=always' '$UNIT_CM' && grep -q '^LimitNOFILE=65536' '$UNIT_CM' && \
   grep -q '^After=network-online.target' '$UNIT_CM'"
check "B4 cm WantedBy=multi-user.target" "grep -q '^WantedBy=multi-user.target' '$UNIT_CM'"

check "B4 scheduler ExecStart 使用沙箱二进制" \
  "grep -q '^ExecStart=$SB/usr/local/bin/kube-scheduler ' '$UNIT_SCHED'"
check "B4 scheduler --kubeconfig=scheduler.conf" \
  "grep -q -- '--kubeconfig=$SB/etc/kubernetes/scheduler.conf' '$UNIT_SCHED'"
check "B4 scheduler delegated authentication/authorization kubeconfig" \
  "grep -q -- '--authentication-kubeconfig=$SB/etc/kubernetes/scheduler.conf' '$UNIT_SCHED' && \
   grep -q -- '--authorization-kubeconfig=$SB/etc/kubernetes/scheduler.conf' '$UNIT_SCHED'"
check "B4 scheduler --client-ca-file / requestheader" \
  "grep -q -- '--client-ca-file=' '$UNIT_SCHED' && grep -q -- '--requestheader-client-ca-file=' '$UNIT_SCHED'"
check "B4 scheduler --leader-elect=true / --secure-port=20259" \
  "grep -q -- '--leader-elect=true' '$UNIT_SCHED' && grep -q -- '--secure-port=20259' '$UNIT_SCHED'"
check "B4 scheduler Restart=always / LimitNOFILE / After" \
  "grep -q '^Restart=always' '$UNIT_SCHED' && grep -q '^LimitNOFILE=65536' '$UNIT_SCHED' && \
   grep -q '^After=network-online.target' '$UNIT_SCHED'"
check "B4 scheduler WantedBy=multi-user.target" "grep -q '^WantedBy=multi-user.target' '$UNIT_SCHED'"

echo "-- B5 kubeconfig（证书内嵌 / 身份 / server）"
KUBE_API="$SB/etc/kubernetes"
for kc in admin controller-manager scheduler; do
  check "B5 $kc.conf 已渲染" "sudo -n test -f '$KUBE_API/$kc.conf'"
  check "B5 $kc.conf 权限 0600 root:root" \
    "[[ \"\$(sudo -n stat -c '%u:%g %a' '$KUBE_API/$kc.conf' 2>/dev/null)\" == '0:0 600' ]]"
done
# 复制给测试用户用于 kubectl / 解析（不改变原文件）
for kc in admin controller-manager scheduler; do
  sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$KUBE_API/$kc.conf" "$SB/client/$kc.conf"
done
KUBECTL="$SB/usr/local/bin/kubectl"
kctl() { "$KUBECTL" --kubeconfig "$SB/client/admin.conf" --cache-dir "$SB/kubectl-cache" --request-timeout=10s "$@"; }
kc_cert_subject() {  # kc_cert_subject <kubeconfig>
  python3 - "$1" <<'PY'
import base64
import subprocess
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh)
data = cfg["users"][0]["user"]["client-certificate-data"]
pem = base64.b64decode(data)
p = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
                   input=pem, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
print(p.stdout.decode().strip())
PY
}
kc_server() {
  python3 - "$1" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh)
print(cfg["clusters"][0]["cluster"]["server"])
PY
}
sudo -n install -m 0600 -o "$(id -u)" -g "$(id -g)" "$SB/etc/kubernetes/pki/ca.crt" "$SB/client/ca.crt"
kc_verified() {  # kc_verified <kubeconfig> <ca-file>
  python3 - "$1" "$2" <<'PY'
import base64
import subprocess
import sys
import yaml

cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
pem = base64.b64decode(cfg["users"][0]["user"]["client-certificate-data"])
p = subprocess.run(["openssl", "verify", "-CAfile", sys.argv[2]], input=pem,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
sys.exit(p.returncode)
PY
}
kc_key_matches() {  # kc_key_matches <kubeconfig>
  python3 - "$1" <<'PY'
import base64
import subprocess
import sys
import yaml

cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
user = cfg["users"][0]["user"]
cert = base64.b64decode(user["client-certificate-data"])
key = base64.b64decode(user["client-key-data"])
cpub = subprocess.run(["openssl", "x509", "-noout", "-pubkey"], input=cert,
                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
kpub = subprocess.run(["openssl", "pkey", "-pubout"], input=key,
                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
sys.exit(0 if cpub.stdout.strip() and cpub.stdout.strip() == kpub.stdout.strip() else 1)
PY
}
wait_log_grep() {  # wait_log_grep <file> <pattern>（大小写不敏感，兼容日志措辞变化）
  local i
  for ((i = 0; i < 120; i++)); do
    grep -qi -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}
check "B5 admin kubeconfig server = https://127.0.0.1:16443" \
  "[[ \"\$(kc_server '$SB/client/admin.conf')\" == 'https://127.0.0.1:16443' ]]"
check "B5 admin 客户端身份 CN=kubernetes-admin,O=system:masters" \
  "kc_cert_subject '$SB/client/admin.conf' | grep -q 'CN=kubernetes-admin' && \
   kc_cert_subject '$SB/client/admin.conf' | grep -q 'O=system:masters'"
check "B5 controller-manager 客户端身份 CN=system:kube-controller-manager" \
  "kc_cert_subject '$SB/client/controller-manager.conf' | grep -q 'CN=system:kube-controller-manager'"
check "B5 scheduler 客户端身份 CN=system:kube-scheduler" \
  "kc_cert_subject '$SB/client/scheduler.conf' | grep -q 'CN=system:kube-scheduler'"
check "B5 客户端证书由 kubernetes-ca 签发（openssl verify）" \
  "kc_verified '$SB/client/admin.conf' '$SB/client/ca.crt'"
check "B5 kubeconfig 内嵌证书与私钥匹配" \
  "kc_key_matches '$SB/client/admin.conf' && kc_key_matches '$SB/client/controller-manager.conf' && \
   kc_key_matches '$SB/client/scheduler.conf'"

echo "-- B6 从 unit 拉起真实控制面"
start_unit() {  # start_unit <component> <unit> <log>
  local comp="$1" unit="$2" log="$3" i pid
  local -a _args=()
  mapfile -t _args < <(python3 "$UNIT_EXEC" "$unit")
  [[ ${#_args[@]} -gt 0 ]] || return 1
  ( sudo -n "${_args[@]}" </dev/null >>"$log" 2>&1 ) &
  WRAPPER[$comp]=$!
  for ((i = 0; i < 120; i++)); do
    pid="$(proc_pid "$comp")"
    if [[ -n "$pid" ]]; then PID[$comp]="$pid"; return 0; fi
    sleep 0.1
  done
  return 1
}
if start_unit kube-apiserver "$UNIT_API" "$SB/logs/apiserver.log"; then
  ok "已从 unit 拉起 kube-apiserver（PID ${PID[kube-apiserver]}）"
else
  bad "无法拉起 kube-apiserver（见 $SB/logs/apiserver.log）"
fi

wait_healthz() {
  local i
  for ((i = 0; i < 180; i++)); do
    kctl get --raw /healthz 2>/dev/null | grep -qx ok && return 0
    sleep 0.5
  done
  return 1
}
check "B6 kubectl get --raw /healthz = ok" "wait_healthz"
check "B6 kubectl get --raw /readyz = ok" \
  "kctl get --raw /readyz 2>/dev/null | grep -qx ok"
check "B6 /readyz?verbose 无失败项（无 '[-]'）" \
  "! kctl get --raw '/readyz?verbose' 2>/dev/null | grep -q '\\[-\\]'"
check "B6 kubectl get ns 成功" "kctl get ns >/dev/null 2>&1"
check "B6 默认命名空间存在（default）" "kctl get ns default -o name 2>/dev/null | grep -qx 'namespace/default'"
check "B6 系统命名空间存在（kube-system）" "kctl get ns kube-system -o name 2>/dev/null | grep -qx 'namespace/kube-system'"

if start_unit kube-controller-manager "$UNIT_CM" "$SB/logs/controller-manager.log"; then
  ok "已从 unit 拉起 kube-controller-manager（PID ${PID[kube-controller-manager]}）"
else
  bad "无法拉起 kube-controller-manager（见 $SB/logs/controller-manager.log）"
fi
if start_unit kube-scheduler "$UNIT_SCHED" "$SB/logs/scheduler.log"; then
  ok "已从 unit 拉起 kube-scheduler（PID ${PID[kube-scheduler]}）"
else
  bad "无法拉起 kube-scheduler（见 $SB/logs/scheduler.log）"
fi
check "B6 三进程均存活" \
  "ps -o pid= -p '${PID[kube-apiserver]:-0}' >/dev/null 2>&1 && \
   ps -o pid= -p '${PID[kube-controller-manager]:-0}' >/dev/null 2>&1 && \
   ps -o pid= -p '${PID[kube-scheduler]:-0}' >/dev/null 2>&1"
check "B6 cm secure-port 20257 监听" "wait_port 20257"
check "B6 scheduler secure-port 20259 监听" "wait_port 20259"
check "B6 cm 日志显示成功获取 leader lease" \
  "wait_log_grep '$SB/logs/controller-manager.log' 'uccessfully acquired lease'"
check "B6 scheduler 日志显示成功获取 leader lease" \
  "wait_log_grep '$SB/logs/scheduler.log' 'uccessfully acquired lease'"

echo "-- B7 安全默认（真实请求）"
ANON_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1:16443/api 2>/dev/null)"
check "B7 匿名访问 /api 被拒（严格 401，实际 $ANON_CODE）" \
  "[[ '$ANON_CODE' == '401' ]]"
ANON_NS="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1:16443/api/v1/namespaces 2>/dev/null)"
check "B7 匿名访问 namespaces 被拒（严格 401，实际 $ANON_NS）" \
  "[[ '$ANON_NS' == '401' ]]"
check "B7 管理员 kubeconfig 可正常访问（对照）" "kctl get --raw /version >/dev/null 2>&1"
check "B7 apiserver 进程参数含 --anonymous-auth=false" \
  "tr '\\0' '\\n' <'/proc/${PID[kube-apiserver]:-0}/cmdline' | grep -qx -- '--anonymous-auth=false'"
check "B7 apiserver 进程参数含 --authorization-mode=RBAC,Node" \
  "tr '\\0' '\\n' <'/proc/${PID[kube-apiserver]:-0}/cmdline' | grep -qx -- '--authorization-mode=RBAC,Node'"
check "B7 apiserver 进程参数含 --client-ca-file" \
  "tr '\\0' '\\n' <'/proc/${PID[kube-apiserver]:-0}/cmdline' | grep -q -- '--client-ca-file='"
check "B7 cm 进程参数含 --kubeconfig=controller-manager.conf" \
  "tr '\\0' '\\n' <'/proc/${PID[kube-controller-manager]:-0}/cmdline' | grep -qx -- '--kubeconfig=$SB/etc/kubernetes/controller-manager.conf'"
check "B7 scheduler 进程参数含 --kubeconfig=scheduler.conf" \
  "tr '\\0' '\\n' <'/proc/${PID[kube-scheduler]:-0}/cmdline' | grep -qx -- '--kubeconfig=$SB/etc/kubernetes/scheduler.conf'"
check "B7 cm 进程以 root 运行" \
  "[[ \"\$(ps -o uid= -p '${PID[kube-controller-manager]:-0}' | tr -d ' ')\" == '0' ]]"
check "B7 scheduler 进程以 root 运行" \
  "[[ \"\$(ps -o uid= -p '${PID[kube-scheduler]:-0}' | tr -d ' ')\" == '0' ]]"

echo "-- B8 幂等（运行中重跑：changed=0 / 不通知 handler / PID 不变）"
declare -A ST_BEFORE=()
PIDS_BEFORE=""
for c in kube-apiserver kube-controller-manager kube-scheduler; do
  ST_BEFORE[$c]="$(proc_starttime "${PID[$c]:-0}")"
  PIDS_BEFORE+="${PID[$c]:-0} "
done
UNIT_HASH_BEFORE="$(sha_of "$UNIT_API") $(sha_of "$UNIT_CM") $(sha_of "$UNIT_SCHED")"
KC_HASH_BEFORE="$(sha_of "$SB/client/admin.conf") $(sha_of "$SB/client/controller-manager.conf") $(sha_of "$SB/client/scheduler.conf")"
if ap "$PLAY_CP" /tmp/opencode/t007_cp_run2.log -e "{\"sandbox_root\":\"$SB\"}"; then
  c="$(changed_of /tmp/opencode/t007_cp_run2.log)"
  check "B8 第二次运行 changed=0" "[[ '${c:-x}' == '0' ]]"
else
  bad "B8 第二次运行失败（见 /tmp/opencode/t007_cp_run2.log）"
fi
check "B8 未通知任何 restart handler" "! grep -q 'RUNNING HANDLER' /tmp/opencode/t007_cp_run2.log"
PIDS_AFTER=""
for c in kube-apiserver kube-controller-manager kube-scheduler; do PIDS_AFTER+="${PID[$c]:-0} "; done
check "B8 三进程 PID 未变（未被重启）" "[[ '$PIDS_AFTER' == '$PIDS_BEFORE' ]]"
for c in kube-apiserver kube-controller-manager kube-scheduler; do
  check "B8 $c /proc starttime 未变" \
    "[[ \"\$(proc_starttime '${PID[$c]:-0}')\" == '${ST_BEFORE[$c]}' ]]"
done
check "B8 unit 内容未变" \
  "[[ \"\$(sha_of '$UNIT_API') \$(sha_of '$UNIT_CM') \$(sha_of '$UNIT_SCHED')\" == '$UNIT_HASH_BEFORE' ]]"
check "B8 kubeconfig 内容未变" \
  "[[ \"\$(sha_of '$SB/client/admin.conf') \$(sha_of '$SB/client/controller-manager.conf') \$(sha_of '$SB/client/scheduler.conf')\" == '$KC_HASH_BEFORE' ]]"
check "B8 集群仍 healthy（healthz）" "kctl get --raw /healthz 2>/dev/null | grep -qx ok"

echo "-- B9 fail-fast 矩阵（任何失败都不得改动已渲染 unit）"
unit_hash_now() { printf '%s %s %s' "$(sha_of "$UNIT_API")" "$(sha_of "$UNIT_CM")" "$(sha_of "$UNIT_SCHED")"; }
UNIT_HASH_NOW="$(unit_hash_now)"
run_ff() {  # run_ff <log> <extra-json>
  local log="$1" extra="$2"
  timeout 600 "$ANSIBLE_PLAYBOOK" -i "$INV" "$PLAY_CP" \
    -e "{\"sandbox_root\":\"$SB\"}" -e "$extra" >"$log" 2>&1
}
# 缺证书
rc=0
run_ff /tmp/opencode/t007_ff_cert.log \
  "{\"kube_apiserver_tls_cert_file\":\"$SB/missing/apiserver.crt\"}" || rc=$?
check "B9 缺证书 → exit≠0" "[[ $rc -ne 0 ]]"
check "B9 缺证书 → 错误提及证书/密钥" \
  "grep -qE '缺少控制面所需证书|证书/密钥' /tmp/opencode/t007_ff_cert.log"
check "B9 缺证书 → unit 未变" "[[ \"\$(unit_hash_now)\" == '$UNIT_HASH_NOW' ]]"
# 缺 etcd endpoint
rc=0
run_ff /tmp/opencode/t007_ff_etcd.log \
  "{\"kube_apiserver_etcd_servers\":[],\"kube_apiserver_etcd_group\":\"t007_missing_group\"}" || rc=$?
check "B9 缺 etcd endpoint → exit≠0" "[[ $rc -ne 0 ]]"
check "B9 缺 etcd endpoint → 错误提及 etcd" "grep -q 'etcd endpoint 为空' /tmp/opencode/t007_ff_etcd.log"
check "B9 缺 etcd endpoint → unit 未变" "[[ \"\$(unit_hash_now)\" == '$UNIT_HASH_NOW' ]]"
# 缺 SA key
rc=0
run_ff /tmp/opencode/t007_ff_sa.log \
  "{\"kube_apiserver_service_account_signing_key_file\":\"$SB/missing/sa.key\"}" || rc=$?
check "B9 缺 SA key → exit≠0" "[[ $rc -ne 0 ]]"
check "B9 缺 SA key → 错误提及缺失文件" "grep -q 'sa.key' /tmp/opencode/t007_ff_sa.log"
check "B9 缺 SA key → unit 未变" "[[ \"\$(unit_hash_now)\" == '$UNIT_HASH_NOW' ]]"
# 缺 controller-manager kubeconfig（cm role 只消费，必须 fail-fast）
rc=0
run_ff /tmp/opencode/t007_ff_cm_kc.log \
  "{\"kube_controller_manager_kubeconfig\":\"$SB/missing/controller-manager.conf\"}" || rc=$?
check "B9 cm 缺 kubeconfig → exit≠0" "[[ $rc -ne 0 ]]"
check "B9 cm 缺 kubeconfig → 错误提及依赖文件" \
  "grep -q '缺少 kube-controller-manager 依赖文件' /tmp/opencode/t007_ff_cm_kc.log"
check "B9 cm 缺 kubeconfig → unit 未变" "[[ \"\$(unit_hash_now)\" == '$UNIT_HASH_NOW' ]]"
# 版本不匹配（复用 1.31.0 制品，却声明 1.30.0）
rc=0
run_ff /tmp/opencode/t007_ff_version.log \
  "{\"kube_apiserver_version\":\"1.30.0\",\"kube_apiserver_download_url\":\"https://dl.k8s.io/v${VERSION}/bin/linux/amd64/kube-apiserver\",\"kube_apiserver_sha256\":\"${ART_SHA[kube-apiserver]}\"}" || rc=$?
check "B9 版本不匹配 → exit≠0" "[[ $rc -ne 0 ]]"
check "B9 版本不匹配 → 错误给出实际版本" \
  "grep -q '版本与 kube_apiserver_version=1.30.0 不一致' /tmp/opencode/t007_ff_version.log && \
   grep -q 'v1.31.0' /tmp/opencode/t007_ff_version.log"
check "B9 版本不匹配 → unit 未变" "[[ \"\$(unit_hash_now)\" == '$UNIT_HASH_NOW' ]]"
# 端口冲突（外部 python 监听）；端口可用 T007_TEST_CONFLICT_PORT 覆盖，避免并行跑套件互相抢占
CONFLICT_PORT="${T007_TEST_CONFLICT_PORT:-17443}"
python3 - "$CONFLICT_PORT" <<'PY' >"$SB/dummy-listener.log" 2>&1 &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(5)
time.sleep(60)
PY
DUMMY_PID=$!
sleep 0.5
rc=0
run_ff /tmp/opencode/t007_ff_port.log "{\"kube_apiserver_secure_port\":$CONFLICT_PORT}" || rc=$?
kill "$DUMMY_PID" 2>/dev/null || true
wait "$DUMMY_PID" 2>/dev/null || true
check "B9 端口冲突 → exit≠0" "[[ $rc -ne 0 ]]"
check "B9 端口冲突 → 错误提及 secure-port/占用" \
  "grep -qE 'secure-port $CONFLICT_PORT 已被其它进程占用' /tmp/opencode/t007_ff_port.log"
check "B9 端口冲突 → unit 未变" "[[ \"\$(unit_hash_now)\" == '$UNIT_HASH_NOW' ]]"

echo "-- B10 清理与宿主零污染"
stop_proc "$SB/usr/local/bin/kube-apiserver"
stop_proc "$SB/usr/local/bin/kube-controller-manager"
stop_proc "$SB/usr/local/bin/kube-scheduler"
stop_proc "$SB/usr/local/bin/etcd"
for k in "${!WRAPPER[@]}"; do wait "${WRAPPER[$k]}" 2>/dev/null || true; done
WRAPPER=()
check "B10 控制面/etcd 进程已全部退出" \
  "! pgrep -f '$SB/usr/local/bin/kube-apiserver' >/dev/null 2>&1 && \
   ! pgrep -f '$SB/usr/local/bin/kube-controller-manager' >/dev/null 2>&1 && \
   ! pgrep -f '$SB/usr/local/bin/kube-scheduler' >/dev/null 2>&1 && \
   ! pgrep -f '$SB/usr/local/bin/etcd' >/dev/null 2>&1"
check "B10 高位端口全部释放" "wait_ports_free"

POST_HOST_UNITS="$(ls /etc/systemd/system/kube-*.service 2>/dev/null | sort | tr '\n' ' ')"
POST_ETC_K8S="$(snapshot_path /etc/kubernetes)"
POST_PORTS="$(snapshot_ports)"
check "B10 宿主 /etc/systemd/system 未新增 kube-*.service" \
  "[[ '$PRE_HOST_UNITS' == '$POST_HOST_UNITS' ]]"
check "B10 宿主 /etc/kubernetes 未被创建/改动" "[[ '$PRE_ETC_K8S' == '$POST_ETC_K8S' ]]"
check "B10 宿主默认/测试端口快照一致" "[[ '$PRE_PORTS' == '$POST_PORTS' ]]"

sudo -n rm -rf "$SB"
check "B10 沙箱已清理" "[[ ! -e '$SB' ]]"
SB=""

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
