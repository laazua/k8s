#!/usr/bin/env bash
# =============================================================================
# T004 PKI / 证书 role（pki）验收测试（TDD：先红后绿）
#  策略：**离线 + 沙箱真实执行** —— 用本地 openssl 真生成 CA/密钥/证书、真落盘，
#        再用 openssl 断言 SAN / 主体 / 权限 / 有效期 / 链式验证 / 幂等 / 自愈。
#        宿主 /etc/kubernetes 全程零污染（执行前后快照比对）。
# 用法: tests/pki/test_pki_role.sh
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
have_openssl() { command -v openssl >/dev/null 2>&1; }

ROLE=roles/pki
PLAY=tests/pki/sandbox.yml
INV=tests/pki/inventory.ini
INV_ALT=tests/pki/inventory_alt.ini
INV_NOMASTER=tests/pki/inventory_nomaster.ini
YAMLLINT="${YAMLLINT:-yamllint}"

# --- openssl 断言小工具 ------------------------------------------------------
SAN()    { openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n'; }
san_has() { SAN "$1" | grep -qE "(^|,)${2}(,|$)"; }
SUBJ()   { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//'; }

check_san() {  # 名称 证书 期望条目...
  local name="$1" cert="$2"; shift 2
  local miss=() e
  for e in "$@"; do san_has "$cert" "$e" || miss+=("$e"); done
  if [[ ${#miss[@]} -eq 0 ]]; then ok "$name"; else bad "$name（缺失: ${miss[*]}；实得 $(SAN "$cert")）"; fi
}
check_mode() {  # 名称 期望权限 路径...
  local name="$1" want="$2"; shift 2
  local wrong=() p g
  for p in "$@"; do
    g="$(stat -c '%a' "$p" 2>/dev/null || echo MISSING)"
    [[ "$g" == "$want" ]] || wrong+=("${p##*/}=$g")
  done
  if [[ ${#wrong[@]} -eq 0 ]]; then ok "$name"; else bad "$name（期望 $want，实得: ${wrong[*]}）"; fi
}
check_verify() {  # 名称 CA 证书...
  local name="$1" ca="$2"; shift 2
  local wrong=() c
  for c in "$@"; do openssl verify -CAfile "$ca" "$c" >/dev/null 2>&1 || wrong+=("$(basename "$c")"); done
  if [[ ${#wrong[@]} -eq 0 ]]; then ok "$name"; else bad "$name（未通过: ${wrong[*]}）"; fi
}
hash_manifest() { ( cd "$1" && find . -type f \( -name '*.crt' -o -name '*.key' -o -name '*.pub' \) \
  | sort | xargs -r sha256sum ); }
hash_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
not_expired() { local b=0 f; for f in "$@"; do openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 || b=1; done; [[ $b -eq 0 ]]; }

echo "== T004 pki role 验收 =="

echo "-- A1 role / 测试资产结构"
for f in "$ROLE/defaults/main.yml" "$ROLE/tasks/main.yml" "$ROLE/tasks/facts.yml" "$ROLE/tasks/ca.yml" \
  "$ROLE/tasks/cert.yml" "$ROLE/tasks/kubelet.yml" "$ROLE/tasks/sa.yml" "$ROLE/tasks/verify.yml" \
  "$ROLE/tasks/_needs_regen.yml" "$ROLE/meta/main.yml" "$ROLE/README.md"; do
  check "存在 $f" "[[ -f '$f' ]]"
done
for f in "$PLAY" "$INV" "$INV_ALT" "$INV_NOMASTER"; do
  check "存在 $f" "[[ -f '$f' ]]"
done

if ! have_openssl; then
  bad "找不到 openssl（无法验证 PKI）"
fi
if ! have_ansible; then
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi

echo "-- A19 语法与风格"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i "$INV" --syntax-check "$PLAY" >/tmp/opencode/t004_syntax.log 2>&1; then
    ok "$PLAY --syntax-check 通过"
  else
    bad "$PLAY --syntax-check 失败（见 /tmp/opencode/t004_syntax.log）"
  fi
else
  bad "找不到 ansible-playbook（跳过语法检查）"
fi
if command -v "$YAMLLINT" >/dev/null 2>&1; then
  if "$YAMLLINT" -c .yamllint "$ROLE" tests/pki >/tmp/opencode/t004_yamllint.log 2>&1; then
    ok "yamllint（roles/pki, tests/pki）无 error"
  else
    bad "yamllint 失败（见 /tmp/opencode/t004_yamllint.log）"
  fi
else
  bad "找不到 yamllint"
fi

echo "-- A15 变量化 / 禁止硬编码 SAN"
check "tasks 中无硬编码 IPv4 地址" "! grep -rqE '([0-9]{1,3}\.){3}[0-9]{1,3}' $ROLE/tasks/"
check "tasks 中无硬编码集群主机名" "! grep -rqE 'k8s-master|k8s-node|cp-a|worker-a' $ROLE/tasks/"
check "tasks 中无硬编码 /etc/kubernetes（必须可重定向）" "! grep -rq '/etc/kubernetes' $ROLE/tasks/"
check "defaults 提供沙箱前缀 pki_root_prefix（可重定向）" "grep -q '^pki_root_prefix:' $ROLE/defaults/main.yml"
check "SAN 来源为 inventory 分组（groups[）" "grep -rq \"groups\\[\" $ROLE/tasks/facts.yml"
check "SAN 来源含 k8s_vip" "grep -rq 'k8s_vip' $ROLE/tasks/facts.yml"
check "defaults 变量化：key 类型/长度/摘要/有效期/权限/分组名" \
  "grep -q '^pki_key_type:' $ROLE/defaults/main.yml && grep -q '^pki_key_size:' $ROLE/defaults/main.yml && \
   grep -q '^pki_digest:' $ROLE/defaults/main.yml && grep -q '^pki_cert_duration_days:' $ROLE/defaults/main.yml && \
   grep -q '^pki_ca_duration_days:' $ROLE/defaults/main.yml && grep -q '^pki_key_mode:' $ROLE/defaults/main.yml && \
   grep -q '^pki_master_group:' $ROLE/defaults/main.yml && grep -q '^pki_etcd_group:' $ROLE/defaults/main.yml"

echo "-- A20 范围约束（不接入 site.yml；不改已验收资产）"
check "playbooks/site.yml 未引用 pki" "! grep -q 'pki' playbooks/site.yml"
if git rev-parse --git-dir >/dev/null 2>&1; then
  dirty="$(git status --porcelain -- tests/skeleton tests/base tests/download roles/base roles/download | wc -l)"
  check "tests/{skeleton,base,download}、roles/{base,download} 未被改动" "[[ $dirty -eq 0 ]]"
fi

# ---------------------------------------------------------------------------
if have_ansible && have_openssl; then

  SB="$(mktemp -d /tmp/opencode/t004.XXXXXX)"
  PKI="$SB/etc/kubernetes/pki"
  ETCD="$PKI/etcd"
  KUBELET="$PKI/kubelet"

  cleanup() {
    if [[ ${fail:-0} -eq 0 ]]; then
      rm -rf "$SB" "$SB2"
    else
      printf '  (存在失败断言，保留沙箱供排障: %s)\n' "$SB"
    fi
  }

  # 宿主零污染快照（A17）
  snapshot_path() {
    local p="$1"
    if [[ -e "$p" ]]; then
      if [[ -f "$p" ]]; then sha256sum "$p" | awk '{print $1}'; else stat -c '%F %a' "$p"; fi
    else printf '__MISSING__'; fi
  }
  HOST_PATHS=(/etc/kubernetes /etc/kubernetes/pki)
  declare -A pre_host_state=()
  for p in "${HOST_PATHS[@]}"; do pre_host_state["$p"]="$(snapshot_path "$p")"; done

  run_role() {  # 沙箱 日志 附加参数...
    local sb="$1" log="$2"; shift 2
    "$ANSIBLE_PLAYBOOK" -i "$INV" tests/pki/sandbox.yml -e "{\"pki_root_prefix\": \"$sb\", \"pki_file_owner\": \"{{ omit }}\", \"pki_file_group\": \"{{ omit }}\"}" "$@" >"$log" 2>&1
  }
  changed_of() { grep -oE 'changed=[0-9]+' "$1" | tail -1 | cut -d= -f2; }

  echo "-- A2 首跑：真实生成全套 PKI（沙箱）"
  if run_role "$SB" /tmp/opencode/t004_run1.log; then
    ok "首跑 exit 0"
  else
    bad "首跑失败（见 /tmp/opencode/t004_run1.log）"
  fi
  EXPECTED=(
    "$PKI/ca.crt" "$PKI/ca.key"
    "$PKI/apiserver.crt" "$PKI/apiserver.key"
    "$PKI/admin.crt" "$PKI/admin.key"
    "$PKI/front-proxy-ca.crt" "$PKI/front-proxy-ca.key"
    "$PKI/front-proxy-client.crt" "$PKI/front-proxy-client.key"
    "$PKI/apiserver-etcd-client.crt" "$PKI/apiserver-etcd-client.key"
    "$PKI/sa.key" "$PKI/sa.pub"
    "$ETCD/ca.crt" "$ETCD/ca.key"
    "$ETCD/server.crt" "$ETCD/server.key"
    "$ETCD/peer.crt" "$ETCD/peer.key"
    "$KUBELET/k8s-node1.crt" "$KUBELET/k8s-node1.key"
    "$KUBELET/k8s-node2.crt" "$KUBELET/k8s-node2.key"
  )
  missing=()
  for f in "${EXPECTED[@]}"; do [[ -f "$f" ]] || missing+=("${f##*/}"); done
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "全部预期产物已生成（CA×3 + apiserver/kubelet×2/etcd/front-proxy/SA/admin 共 ${#EXPECTED[@]} 个文件）"
  else
    bad "产物缺失: ${missing[*]}"
  fi

  echo "-- A3 apiserver SAN 覆盖 VIP + 全部 master/节点名（+必要 IP/DNS）"
  check_san "apiserver SAN 含 VIP" "$PKI/apiserver.crt" IPAddress:10.10.0.100
  check_san "apiserver SAN 含全部 master 主机名与 IP" "$PKI/apiserver.crt" \
    DNS:k8s-master1 DNS:k8s-master2 DNS:k8s-master3 IPAddress:10.10.0.11 IPAddress:10.10.0.12 IPAddress:10.10.0.13
  check_san "apiserver SAN 含全部 node 主机名与 IP" "$PKI/apiserver.crt" \
    DNS:k8s-node1 DNS:k8s-node2 IPAddress:10.10.0.21 IPAddress:10.10.0.22
  check_san "apiserver SAN 含 kubernetes 服务 DNS/服务 IP/回环" "$PKI/apiserver.crt" \
    DNS:kubernetes DNS:kubernetes.default DNS:kubernetes.default.svc DNS:kubernetes.default.svc.cluster.local \
    IPAddress:10.96.0.1 IPAddress:127.0.0.1

  echo "-- A4 kubelet SAN 含各自节点名（且不含其它节点）"
  check_san "kubelet/k8s-node1 SAN 含节点名与地址" "$KUBELET/k8s-node1.crt" DNS:k8s-node1 IPAddress:10.10.0.21
  check_san "kubelet/k8s-node2 SAN 含节点名与地址" "$KUBELET/k8s-node2.crt" DNS:k8s-node2 IPAddress:10.10.0.22
  check "kubelet/k8s-node1 SAN 不含其它节点名（不过度扩散）" "! san_has '$KUBELET/k8s-node1.crt' DNS:k8s-node2"
  check "kubelet/k8s-node1 SAN 不含 VIP" "! san_has '$KUBELET/k8s-node1.crt' IPAddress:10.10.0.100"

  echo "-- A5 etcd server/peer SAN 含全部 etcd 成员"
  check_san "etcd server SAN 含全部 etcd 成员名与 IP" "$ETCD/server.crt" \
    DNS:k8s-master1 DNS:k8s-master2 DNS:k8s-master3 IPAddress:10.10.0.11 IPAddress:10.10.0.12 IPAddress:10.10.0.13 IPAddress:127.0.0.1
  check_san "etcd peer SAN 含全部 etcd 成员名与 IP" "$ETCD/peer.crt" \
    DNS:k8s-master1 DNS:k8s-master2 DNS:k8s-master3 IPAddress:10.10.0.11 IPAddress:10.10.0.12 IPAddress:10.10.0.13

  echo "-- A6 front-proxy 独立 CA（与 kubernetes-ca 隔离）"
  check "front-proxy-client 递归 CA 校验者 front-proxy-ca 签发" \
    "openssl verify -CAfile '$PKI/front-proxy-ca.crt' '$PKI/front-proxy-client.crt'"
  check "kubernetes-ca **不能**验证 front-proxy-client（CA 隔离）" \
    "! openssl verify -CAfile '$PKI/ca.crt' '$PKI/front-proxy-client.crt'"
  check "etcd-ca **不能**验证 apiserver（CA 隔离）" \
    "! openssl verify -CAfile '$ETCD/ca.crt' '$PKI/apiserver.crt'"

  echo "-- A7 权限：私钥 600 / 证书 644 / 目录 700"
  check_mode "全部私钥权限 600" 600 "$PKI/ca.key" "$PKI/apiserver.key" "$PKI/admin.key" \
    "$PKI/front-proxy-ca.key" "$PKI/front-proxy-client.key" "$PKI/apiserver-etcd-client.key" \
    "$PKI/sa.key" "$ETCD/ca.key" "$ETCD/server.key" "$ETCD/peer.key" \
    "$KUBELET/k8s-node1.key" "$KUBELET/k8s-node2.key"
  check_mode "全部证书权限 644" 644 "$PKI/ca.crt" "$PKI/apiserver.crt" "$PKI/admin.crt" \
    "$PKI/front-proxy-ca.crt" "$PKI/front-proxy-client.crt" "$PKI/apiserver-etcd-client.crt" \
    "$ETCD/ca.crt" "$ETCD/server.crt" "$ETCD/peer.crt" \
    "$KUBELET/k8s-node1.crt" "$KUBELET/k8s-node2.crt"
  check_mode "PKI 目录权限 700" 700 "$PKI" "$ETCD" "$KUBELET"
  check "sa.pub 权限 644" "[[ \$(stat -c '%a' '$PKI/sa.pub' 2>/dev/null) == 644 ]]"
  check "apiserver.key 权限明确为 600（验收硬指标）" "[[ \$(stat -c '%a' '$PKI/apiserver.key' 2>/dev/null) == 600 ]]"

  echo "-- A8 链式验证（openssl verify -CAfile）"
  check_verify "kubernetes-ca 链：apiserver"     "$PKI/ca.crt" "$PKI/apiserver.crt"
  check_verify "kubernetes-ca 链：admin"         "$PKI/ca.crt" "$PKI/admin.crt"
  check_verify "kubernetes-ca 链：kubelet×2"     "$PKI/ca.crt" "$KUBELET/k8s-node1.crt" "$KUBELET/k8s-node2.crt"
  check_verify "etcd-ca 链：server/peer"         "$ETCD/ca.crt" "$ETCD/server.crt" "$ETCD/peer.crt"
  check_verify "etcd-ca 链：apiserver-etcd-client" "$ETCD/ca.crt" "$PKI/apiserver-etcd-client.crt"
  check_verify "front-proxy-ca 链：front-proxy-client" "$PKI/front-proxy-ca.crt" "$PKI/front-proxy-client.crt"
  check "全部证书均未过期（-checkend 0）" \
    "not_expired '$PKI'/*.crt '$ETCD'/*.crt '$KUBELET'/*.crt"

  echo "-- A9 主体（CN / O）"
  check "apiserver CN=kube-apiserver"        "SUBJ '$PKI/apiserver.crt' | grep -q 'CN=kube-apiserver'"
  check "admin CN=kubernetes-admin"          "SUBJ '$PKI/admin.crt' | grep -q 'CN=kubernetes-admin'"
  check "admin O=system:masters"             "SUBJ '$PKI/admin.crt' | grep -q 'O=system:masters'"
  check "kubelet/k8s-node1 CN=system:node:k8s-node1" "SUBJ '$KUBELET/k8s-node1.crt' | grep -q 'CN=system:node:k8s-node1'"
  check "kubelet/k8s-node1 O=system:nodes"   "SUBJ '$KUBELET/k8s-node1.crt' | grep -q 'O=system:nodes'"
  check "front-proxy-client CN=front-proxy-client" "SUBJ '$PKI/front-proxy-client.crt' | grep -q 'CN=front-proxy-client'"
  check "etcd peer CN=etcd-peer"             "SUBJ '$ETCD/peer.crt' | grep -q 'CN=etcd-peer'"
  check "三个 CA 主体独立" \
    "SUBJ '$PKI/ca.crt' | grep -q 'CN=kubernetes-ca' && SUBJ '$ETCD/ca.crt' | grep -q 'CN=etcd-ca' && SUBJ '$PKI/front-proxy-ca.crt' | grep -q 'CN=front-proxy-ca'"

  echo "-- A10 ServiceAccount 密钥对"
  check "sa.key 为 RSA 2048" "openssl pkey -in '$PKI/sa.key' -noout -text 2>/dev/null | grep -q 'Private-Key: (2048'"
  check "sa.pub 与 sa.key 公钥一致（modulus 比对）" \
    "[[ \$(openssl rsa -in '$PKI/sa.key' -noout -modulus 2>/dev/null) == \$(openssl rsa -pubin -in '$PKI/sa.pub' -noout -modulus 2>/dev/null) ]]"

  echo "-- A11 幂等 + 不覆盖（第二次 changed=0 且产物逐一不变）"
  H1="$(hash_manifest "$PKI")"
  if run_role "$SB" /tmp/opencode/t004_run2.log; then
    c="$(changed_of /tmp/opencode/t004_run2.log)"
    if [[ "${c:-x}" == "0" ]]; then ok "第二次执行 changed=0（幂等）"; else bad "第二次执行 changed=${c:-?}，非幂等（见 /tmp/opencode/t004_run2.log）"; fi
  else
    bad "第二次执行失败（见 /tmp/opencode/t004_run2.log）"
  fi
  H2="$(hash_manifest "$PKI")"
  if [[ "$H1" == "$H2" ]]; then
    ok "第二次执行后全部产物 sha256 逐一不变（$(printf '%s\n' "$H1" | wc -l) 个文件）"
  else
    bad "产物被改动: $(diff <(printf '%s\n' "$H1") <(printf '%s\n' "$H2") | head -6 | tr '\n' ' ')"
  fi

  echo "-- A12 不覆盖「仍有效」的既有证书（外部签发 + 旧 mtime）"
  EB="$SB/extbuild"; mkdir -p "$EB"
  {
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$EB/ext.key" 2>/dev/null
    openssl req -new -key "$EB/ext.key" -out "$EB/ext.csr" -subj "/CN=kube-apiserver-external/O=Kubernetes" -sha256 2>/dev/null
    printf '[v3_ext]\nbasicConstraints = critical,CA:FALSE\nkeyUsage = critical,digitalSignature,keyEncipherment\nextendedKeyUsage = serverAuth\nsubjectAltName = DNS:external.example\n' > "$EB/ext.ext"
    openssl x509 -req -in "$EB/ext.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial -CAserial "$EB/ca.srl" \
      -out "$EB/ext.crt" -days 3650 -sha256 -extfile "$EB/ext.ext" -extensions v3_ext 2>/dev/null
  } >/dev/null 2>&1
  if [[ -s "$EB/ext.crt" ]]; then
    install -m 644 "$EB/ext.crt" "$PKI/apiserver.crt"
    install -m 600 "$EB/ext.key" "$PKI/apiserver.key"
    touch -d '2001-01-01 00:00:00' "$PKI/apiserver.crt" "$PKI/apiserver.key"
    check_san "前置条件：外部证书已就位（CN/SAN 与 role 默认不同）" "$PKI/apiserver.crt" DNS:external.example
    HX="$(hash_of "$PKI/apiserver.crt")"
    if run_role "$SB" /tmp/opencode/t004_run3.log; then
      c="$(changed_of /tmp/opencode/t004_run3.log)"
      check "A12 重跑 changed=0（未覆盖既有有效证书）" "[[ '${c:-x}' == '0' ]]"
    else
      bad "A12 重跑失败（见 /tmp/opencode/t004_run3.log）"
    fi
    if [[ "$(hash_of "$PKI/apiserver.crt")" == "$HX" ]]; then
      ok "A12 既有有效证书内容未变（sha256 不变，未重签/未覆盖）"
    else
      bad "A12 既有有效证书被覆盖了（内容哈希变化）"
    fi
    check "A12 外部证书仍可被本 CA 验证（说明 role 自检未误判）" \
      "openssl verify -CAfile '$PKI/ca.crt' '$PKI/apiserver.crt'"
  else
    bad "A12 前置条件构造失败（无法生成外部签名证书）"
  fi

  echo "-- A13 损坏 / 过期 → 重建（自愈语义）"
  printf 'not a certificate at all\n' > "$KUBELET/k8s-node1.crt"
  K1KEY="$(hash_of "$KUBELET/k8s-node1.key")"
  if run_role "$SB" /tmp/opencode/t004_run4.log; then
    c="$(changed_of /tmp/opencode/t004_run4.log)"
    check "A13a 损坏证书 → 重跑 changed>=1（被重建）" "[[ \${c:-0} -ge 1 ]]"
    check "A13a 重建后证书可被 CA 验证（已修复）" \
      "openssl verify -CAfile '$PKI/ca.crt' '$KUBELET/k8s-node1.crt'"
    check "A13a 重建后 SAN 仍含节点名" "san_has '$KUBELET/k8s-node1.crt' DNS:k8s-node1"
    if [[ "$(hash_of "$KUBELET/k8s-node1.key")" == "$K1KEY" ]]; then
      ok "A13a 私钥未被无谓轮换（证书重签、密钥复用）"
    else
      bad "A13a 私钥被无谓轮换（应只在缺失/不匹配时重建）"
    fi
  else
    bad "A13a 损坏证书后重跑失败（见 /tmp/opencode/t004_run4.log）"
  fi
  # 过期证书：用 role 自己的 ca/admin.key 另签一份**真实已过期**的 admin 证书
  openssl req -new -key "$PKI/admin.key" -out "$EB/exp.csr" -subj "/CN=kubernetes-admin/O=system:masters" -sha256 2>/dev/null
  printf '[v3_ext]\nbasicConstraints = critical,CA:FALSE\nkeyUsage = critical,digitalSignature\nextendedKeyUsage = clientAuth\n' > "$EB/exp.ext"
  openssl x509 -req -in "$EB/exp.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAserial "$EB/ca.srl" \
    -not_before 20190101000000Z -not_after 20200101000000Z \
    -out "$PKI/admin.crt" -sha256 -extfile "$EB/exp.ext" -extensions v3_ext 2>/dev/null
  AK="$(hash_of "$PKI/admin.key")"; AC="$(hash_of "$PKI/admin.crt")"
  check "A13b 前置条件：放入的 admin 证书**确实已过期**" "! openssl x509 -in '$PKI/admin.crt' -noout -checkend 0 >/dev/null 2>&1"
  if run_role "$SB" /tmp/opencode/t004_run5.log; then
    check "A13b 过期证书 → 重跑后被替换（未过期）" "openssl x509 -in '$PKI/admin.crt' -noout -checkend 0"
    check "A13b 替换后内容已变化（确实重签）" "[[ \"\$(hash_of '$PKI/admin.crt')\" != '$AC' ]]"
    check "A13b 替换后 CN/O 正确" "SUBJ '$PKI/admin.crt' | grep -q 'CN=kubernetes-admin' && SUBJ '$PKI/admin.crt' | grep -q 'O=system:masters'"
    if [[ "$(hash_of "$PKI/admin.key")" == "$AK" ]]; then
      ok "A13b 私钥复用（仅重签证书）"
    else
      bad "A13b 私钥被无谓轮换"
    fi
  else
    bad "A13b 过期证书后重跑失败（见 /tmp/opencode/t004_run5.log）"
  fi

  echo "-- A14 CA 损坏 → CA 重建 + 其签发 leaf 全量重签"
  printf 'broken ca\n' > "$ETCD/ca.crt"
  ECAK="$(hash_of "$ETCD/ca.key")"
  ES="$(hash_of "$ETCD/server.crt")"; EP="$(hash_of "$ETCD/peer.crt")"; EC="$(hash_of "$PKI/apiserver-etcd-client.crt")"
  if run_role "$SB" /tmp/opencode/t004_run6.log; then
    check "A14 etcd-ca 证书被重建（内容变化且可自校验）" \
      "[[ \"\$(hash_of '$ETCD/ca.crt')\" != 'broken' ]] && openssl x509 -in '$ETCD/ca.crt' -noout -checkend 0"
    check "A14 etcd-ca 私钥复用（未做无谓 CA 密钥轮换）" "[[ \"\$(hash_of '$ETCD/ca.key')\" == '$ECAK' ]]"
    check "A14 etcd leaf（server/peer/apiserver-etcd-client）全部重签" \
      "[[ \"\$(hash_of '$ETCD/server.crt')\" != '$ES' && \"\$(hash_of '$ETCD/peer.crt')\" != '$EP' && \"\$(hash_of '$PKI/apiserver-etcd-client.crt')\" != '$EC' ]]"
    check_verify "A14 重建后 etcd 链仍然自洽" "$ETCD/ca.crt" "$ETCD/server.crt" "$ETCD/peer.crt" "$PKI/apiserver-etcd-client.crt"
    check "A14 kubernetes-ca 链未受牵连" "openssl verify -CAfile '$PKI/ca.crt' '$KUBELET/k8s-node1.crt'"
  else
    bad "A14 CA 损坏后重跑失败（见 /tmp/opencode/t004_run6.log）"
  fi

  echo "-- A15b 对照组 inventory：SAN 随变量变化（证明未硬编码）"
  SB2="$(mktemp -d /tmp/opencode/t004alt.XXXXXX)"
  P2="$SB2/etc/kubernetes/pki"
  if "$ANSIBLE_PLAYBOOK" -i "$INV_ALT" tests/pki/sandbox.yml \
    -e "{\"pki_root_prefix\": \"$SB2\", \"pki_file_owner\": \"{{ omit }}\", \"pki_file_group\": \"{{ omit }}\"}" \
    >/tmp/opencode/t004_alt1.log 2>&1; then
    ok "对照组 inventory 首跑 exit 0"
  else
    bad "对照组 inventory 首跑失败（见 /tmp/opencode/t004_alt1.log）"
  fi
  check_san "A15b 对照组 apiserver SAN 跟随新 VIP/主机名/服务网段" "$P2/apiserver.crt" \
    IPAddress:192.168.77.7 DNS:cp-a DNS:cp-b DNS:cp-c IPAddress:192.168.77.11 IPAddress:172.30.0.1
  check "A15b 对照组 SAN **不含**主 inventory 的 VIP/主机名（无硬编码）" \
    "! san_has '$P2/apiserver.crt' IPAddress:10.10.0.100 && ! san_has '$P2/apiserver.crt' DNS:k8s-master1"
  check_san "A15b 对照组 kubelet SAN 跟随新节点名" "$P2/kubelet/worker-a.crt" DNS:worker-a IPAddress:192.168.77.21
  # 强制重签开关
  FN1="$(hash_manifest "$P2")"
  if "$ANSIBLE_PLAYBOOK" -i "$INV_ALT" tests/pki/sandbox.yml \
    -e "{\"pki_root_prefix\": \"$SB2\", \"pki_file_owner\": \"{{ omit }}\", \"pki_file_group\": \"{{ omit }}\", \"pki_force_regen\": true}" \
    >/tmp/opencode/t004_alt2.log 2>&1; then
    c="$(changed_of /tmp/opencode/t004_alt2.log)"
    check "A15b pki_force_regen=true → 全量重签（changed>=1）" "[[ \${c:-0} -ge 1 ]]"
    check "A15b 强制重签后内容确实变化" "[[ \"\$(hash_manifest '$P2')\" != \"\$FN1\" ]]"
    check "A15b 强制重签后链仍自洽" "openssl verify -CAfile '$P2/front-proxy-ca.crt' '$P2/front-proxy-client.crt'"
  else
    bad "A15b pki_force_regen 运行失败（见 /tmp/opencode/t004_alt2.log）"
  fi
  rm -rf "$SB2"

  echo "-- A16 拓扑缺失 → fail fast（不生成空 SAN 证书）"
  SB3="$(mktemp -d /tmp/opencode/t004nom.XXXXXX)"
  rc=0
  "$ANSIBLE_PLAYBOOK" -i "$INV_NOMASTER" tests/pki/sandbox.yml \
    -e "{\"pki_root_prefix\": \"$SB3\", \"pki_file_owner\": \"{{ omit }}\", \"pki_file_group\": \"{{ omit }}\"}" \
    >/tmp/opencode/t004_nomaster.log 2>&1 || rc=$?
  check "A16 缺少 k8s_master 分组 → role 失败（exit≠0）" "[[ $rc -ne 0 ]]"
  check "A16 报错信息指出缺失的分组名（可诊断）" "grep -q 'k8s_master' /tmp/opencode/t004_nomaster.log"
  check "A16 失败时未生成任何证书" "[[ ! -e '$SB3/etc/kubernetes/pki/apiserver.crt' ]]"
  rm -rf "$SB3"

  echo "-- A18 密钥/证书不入 git"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    check "*.key 被 .gitignore 忽略" "git check-ignore -q path/to/some.key"
    check "*.crt 被 .gitignore 忽略" "git check-ignore -q path/to/some.crt"
    check "*.pem 被 .gitignore 忽略" "git check-ignore -q path/to/some.pem"
    check "工作区无未忽略的密钥/证书文件" \
      "! git status --porcelain | grep -qE '\.(key|crt|pem)$'"
  fi

  echo "-- A17 宿主零污染（/etc/kubernetes 未被创建/改动）"
  for p in "${HOST_PATHS[@]}"; do
    post="$(snapshot_path "$p")"
    if [[ "${pre_host_state[$p]}" == "$post" ]]; then
      ok "宿主 $p 状态未变化（沙箱隔离生效）"
    else
      bad "宿主 $p 被污染！（执行前 ${pre_host_state[$p]}，执行后 $post）"
    fi
  done
  check "宿主未创建 /etc/kubernetes（本机此前不存在则必须仍不存在）" \
    "[[ '${pre_host_state[/etc/kubernetes]}' != '__MISSING__' || ! -e /etc/kubernetes ]]"

  cleanup
fi

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
