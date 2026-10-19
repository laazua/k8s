#!/usr/bin/env bash
# T003 下载与代理 role（download）验收测试（TDD：先红后绿）
#  策略：**全部离线** —— 本地 mock HTTP 源 + mock 正向代理 + mock 不稳定源，
#        真实执行 role（真下载 / 真落盘 / 真校验 / 真走代理），按行为断言判定。
# 用法: tests/download/test_download_role.sh
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

PLAY=tests/download/run_role.yml
ROLE=roles/download
FIX=tests/download/fixtures

echo "== T003 download role 验收 =="

echo "-- A1 role 结构完整性"
for f in "$ROLE/defaults/main.yml" "$ROLE/tasks/main.yml" "$ROLE/handlers/main.yml" \
  "$ROLE/meta/main.yml" "$ROLE/README.md"; do
  check "存在 $f" "[[ -f '$f' ]]"
done
check "存在测试 playbook $PLAY" "[[ -f '$PLAY' ]]"
check "存在 fixture $FIX/hello.bin" "[[ -f '$FIX/hello.bin' ]]"
check "存在 fixture $FIX/flaky.bin" "[[ -f '$FIX/flaky.bin' ]]"

echo "-- A8 变量化 / 无硬编码"
check "tasks 中无硬编码 http(s) URL" "! grep -qE 'https?://' $ROLE/tasks/*.yml"
check "defaults 提供 download_items" "grep -q '^download_items:' $ROLE/defaults/main.yml"
check "defaults 提供 download_timeout" "grep -q '^download_timeout:' $ROLE/defaults/main.yml"
check "defaults 提供 download_retries" "grep -q '^download_retries:' $ROLE/defaults/main.yml"
check "defaults 提供 download_retry_delay" "grep -q '^download_retry_delay:' $ROLE/defaults/main.yml"
check "defaults 提供 download_proxy_env（引用 proxy_env）" \
  "grep -qE '^download_proxy_env:.*proxy_env' $ROLE/defaults/main.yml"
check "defaults 复用全局 k8s_artifact_dir" "grep -q 'k8s_artifact_dir' $ROLE/defaults/main.yml"
check "使用 FQCN ansible.builtin.get_url" "grep -q 'ansible\.builtin\.get_url' $ROLE/tasks/main.yml"
check "get_url 使用 sha256 checksum 强校验" "grep -qE 'checksum:.*sha256' $ROLE/tasks/main.yml"
check "任务均带 name（无裸 module）" "! grep -qE '^\s+- (get_url|file|assert|set_fact|stat):' $ROLE/tasks/main.yml"

echo "-- A12 范围约束（不接入 site.yml；不改已验收资产）"
check "site.yml 未引用 download" "! grep -q 'download' playbooks/site.yml"
if git rev-parse --git-dir >/dev/null 2>&1; then
  dirty="$(git status --porcelain -- tests/skeleton tests/base roles/base | wc -l)"
  check "tests/skeleton、tests/base、roles/base 未被改动" "[[ $dirty -eq 0 ]]"
fi

echo "-- A11 语法检查"
if have_ansible; then
  if "$ANSIBLE_PLAYBOOK" -i localhost, -c local --syntax-check "$PLAY" \
    >/tmp/opencode/t003_syntax.log 2>&1; then
    ok "$PLAY --syntax-check 通过"
  else
    bad "$PLAY --syntax-check 失败（见 /tmp/opencode/t003_syntax.log）"
  fi
else
  bad "找不到 ansible-playbook（请设置 ANSIBLE_PLAYBOOK）"
fi

# ---------------------------------------------------------------------------
echo "-- 启动本地 mock 服务（origin / flaky / proxy）"
if ! have_ansible; then
  bad "找不到 ansible-playbook（跳过全部动态用例）"
else
  SB="$(mktemp -d /tmp/opencode/t003.XXXXXX)"
  ART="$SB/opt/k8s/artifacts"
  PORTS="$SB/ports.json"
  PLOG="$SB/proxy.log"; OLOG="$SB/origin.log"; FLOG="$SB/flaky.log"
  : > "$PLOG"; : > "$OLOG"; : > "$FLOG"

  python3 tests/download/mock_servers.py \
    --fixture-dir "$FIX" --flaky-fixture "$FIX/flaky.bin" --ports-file "$PORTS" \
    --origin-log "$OLOG" --flaky-log "$FLOG" --proxy-log "$PLOG" \
    >"$SB/mock.log" 2>&1 &
  MOCK_PID=$!
  # 注意：不把随机端口/临时路径写进正常输出，保证两次运行日志可逐行比对（确定性）。
  mkdir -p /tmp/opencode
  cleanup() {
    kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null
    if [[ ${fail:-0} -eq 0 ]]; then
      rm -rf "$SB"
    else
      printf '  (存在失败断言，保留沙箱供排障: %s)\n' "$SB"
      cp -f "$PORTS" /tmp/opencode/t003_last_ports.json 2>/dev/null || true
    fi
  }
  trap cleanup EXIT

  for _ in $(seq 1 60); do [[ -s "$PORTS" ]] && break; sleep 0.2; done
  pget() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$PORTS" "$1" 2>/dev/null; }
  ORIGIN="$(pget origin)"; PROXY="$(pget proxy)"; FLAKY="$(pget flaky)"

  if [[ -z "$ORIGIN" || -z "$PROXY" || -z "$FLAKY" ]]; then
    bad "mock 服务未就绪（见 $SB/mock.log）"
  else
    ok "mock 服务就绪（origin / flaky / proxy 三个本地端口）"
  fi

  FHASH="$(sha256sum "$FIX/hello.bin" | awk '{print $1}')"
  BADHASH="$(printf '0%.0s' $(seq 1 64))"
  run_case() { "$ANSIBLE_PLAYBOOK" -i localhost, -c local "$PLAY" -e "@$1" >"$2" 2>&1; }
  changed_of() { grep -oE 'changed=[0-9]+' "$1" | tail -1 | cut -d= -f2; }
  snap() { stat -c '%i %y %s' "$1" 2>/dev/null; }

  # -------------------------------------------------------------------------
  echo "-- A2 正常下载 + sha256 强校验 + 落盘到制品目录"
  cat > "$SB/a2.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_timeout": 5,
  "download_retries": 2,
  "download_retry_delay": 1,
  "download_items": [
    {"name": "hello.bin", "url": "http://127.0.0.1:$ORIGIN/hello.bin", "sha256": "$FHASH", "mode": "0755"}
  ]
}
EOF
  if run_case "$SB/a2.json" "$SB/a2.log"; then
    ok "A2 下载+校验 exit 0"
  else
    bad "A2 下载+校验失败（见 $SB/a2.log）"
  fi
  check "A2 制品落在制品目录（download_cache_dir）" "[[ -f '$ART/hello.bin' ]]"
  check "A2 内容 sha256 == 期望（强校验通过）" \
    "[[ \$(sha256sum '$ART/hello.bin' 2>/dev/null | awk '{print \$1}') == '$FHASH' ]]"
  check "A2 制品权限按 item.mode（0755）" "[[ \$(stat -c '%a' '$ART/hello.bin' 2>/dev/null) == 755 ]]"
  check "A2 制品目录权限 0755" "[[ \$(stat -c '%a' '$ART' 2>/dev/null) == 755 ]]"
  S1="$(snap "$ART/hello.bin")"

  echo "-- A4/A5 幂等 + 已存在不改动"
  if run_case "$SB/a2.json" "$SB/a2b.log"; then
    c="$(changed_of "$SB/a2b.log")"
    if [[ "${c:-x}" == "0" ]]; then
      ok "A4 第二次执行 changed=0（幂等）"
    else
      bad "A4 第二次执行 changed=${c:-?}，非幂等（见 $SB/a2b.log）"
    fi
  else
    bad "A4 第二次执行失败（见 $SB/a2b.log）"
  fi
  S2="$(snap "$ART/hello.bin")"
  if [[ -n "$S1" && "$S1" == "$S2" ]]; then
    ok "A5 重复执行未改动制品（inode/mtime/size 不变）"
  else
    bad "A5 制品被改动（执行前 [$S1] 执行后 [$S2]）"
  fi
  # 离线缓存命中：源不可达（端口 1）仍应成功且 changed=0 —— 证明「已存在则跳过」未发网络请求
  cat > "$SB/a5.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_timeout": 3,
  "download_items": [
    {"name": "hello.bin", "url": "http://127.0.0.1:1/unreachable.bin", "sha256": "$FHASH", "mode": "0755"}
  ]
}
EOF
  if run_case "$SB/a5.json" "$SB/a5b.log"; then
    c="$(changed_of "$SB/a5b.log")"
    check "A5 源不可达但制品已存在 → changed=0（离线缓存命中）" "[[ '${c:-x}' == '0' ]]"
  else
    bad "A5 源不可达时未跳过（离线缓存失效，见 $SB/a5b.log）"
  fi
  check "A5 离线跳过后内容仍正确" \
    "[[ \$(sha256sum '$ART/hello.bin' 2>/dev/null | awk '{print \$1}') == '$FHASH' ]]"

  # -------------------------------------------------------------------------
  echo "-- A3 sha256 不符 → 任务必须失败（且不留成品/半成品）"
  cat > "$SB/a3.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_timeout": 5,
  "download_items": [
    {"name": "bad.bin", "url": "http://127.0.0.1:$ORIGIN/hello.bin", "sha256": "$BADHASH"}
  ]
}
EOF
  rc=0; run_case "$SB/a3.json" "$SB/a3.log" || rc=$?
  if [[ $rc -ne 0 ]]; then
    ok "A3 sha256 不符 → playbook 失败（exit=$rc，非 warning/静默跳过）"
  else
    bad "A3 sha256 不符却 exit 0（必须失败！见 $SB/a3.log）"
  fi
  check "A3 失败日志明确报 checksum 不符" "grep -qiE 'did not match|checksum' '$SB/a3.log'"
  check "A3 未留下成品文件 bad.bin" "[[ ! -e '$ART/bad.bin' ]]"
  check "A3 未留下半成品残留（bad.bin*）" "! ls '$ART'/bad.bin* 2>/dev/null"
  check "A3 未把失败品写到 .part/.tmp" "! ls '$ART'/*.part '$ART'/*.tmp 2>/dev/null"
  # A3b：修正 hash 后同一 dest 必须能成功（证明失败未留误导性残留会被误跳过）
  cat > "$SB/a3b.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_timeout": 5,
  "download_items": [
    {"name": "bad.bin", "url": "http://127.0.0.1:$ORIGIN/hello.bin", "sha256": "$FHASH"}
  ]
}
EOF
  rc=0; run_case "$SB/a3b.json" "$SB/a3b.log" || rc=$?
  check "A3b 修正 sha256 后重跑成功（无残留误跳过）" "[[ $rc -eq 0 ]]"
  check "A3b 修正后内容正确" \
    "[[ \$(sha256sum '$ART/bad.bin' 2>/dev/null | awk '{print \$1}') == '$FHASH' ]]"

  echo "-- A10 强校验不可省略（缺 sha256 / 非法 sha256 → fail fast）"
  olog_before10="$(wc -l < "$OLOG")"
  cat > "$SB/a10a.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_items": [
    {"name": "nosha.bin", "url": "http://127.0.0.1:$ORIGIN/hello.bin"}
  ]
}
EOF
  rc=0; run_case "$SB/a10a.json" "$SB/a10a.log" || rc=$?
  check "A10 缺 sha256 → 失败" "[[ $rc -ne 0 ]]"
  check "A10 缺 sha256 的报错明确（必须提供）" "grep -q '必须提供' '$SB/a10a.log'"
  check "A10 缺 sha256 时未落盘" "[[ ! -e '$ART/nosha.bin' ]]"

  cat > "$SB/a10b.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_items": [
    {"name": "badfmt.bin", "url": "http://127.0.0.1:$ORIGIN/hello.bin", "sha256": "not-a-sha256"}
  ]
}
EOF
  rc=0; run_case "$SB/a10b.json" "$SB/a10b.log" || rc=$?
  check "A10 非法 sha256（非 64 位 hex）→ 失败" "[[ $rc -ne 0 ]]"
  check "A10 非法 sha256 报错明确" "grep -q '必须提供' '$SB/a10b.log'"
  check "A10 非法 sha256 时未落盘" "[[ ! -e '$ART/badfmt.bin' ]]"
  olog_after10="$(wc -l < "$OLOG")"
  check "A10 校验在下载前失败（未发起网络请求）" "[[ ${olog_after10:-0} -eq ${olog_before10:-0} ]]"

  # -------------------------------------------------------------------------
  echo "-- A6 代理生效（proxy_env.http_proxy → 请求确实经代理）"
  : > "$PLOG"
  cat > "$SB/a6.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_timeout": 5,
  "proxy_env": {"http_proxy": "http://127.0.0.1:$PROXY"},
  "download_items": [
    {"name": "proxied.bin", "url": "http://127.0.0.1:$ORIGIN/hello.bin", "sha256": "$FHASH"}
  ]
}
EOF
  rc=0; run_case "$SB/a6.json" "$SB/a6.log" || rc=$?
  check "A6 经代理下载成功（exit 0）" "[[ $rc -eq 0 ]]"
  check "A6 代理日志记录到该请求（请求确实经代理）" \
    "grep -q 'GET http://127.0.0.1:$ORIGIN/hello.bin' '$PLOG'"
  check "A6 经代理下载内容正确" \
    "[[ \$(sha256sum '$ART/proxied.bin' 2>/dev/null | awk '{print \$1}') == '$FHASH' ]]"

  echo "-- A7 no_proxy 被尊重（命中则不经代理，走直连）"
  : > "$PLOG"
  olog_before="$(wc -l < "$OLOG")"
  cat > "$SB/a7.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_timeout": 5,
  "proxy_env": {"http_proxy": "http://127.0.0.1:$PROXY", "no_proxy": "127.0.0.1"},
  "download_items": [
    {"name": "noproxy.bin", "url": "http://127.0.0.1:$ORIGIN/hello.bin", "sha256": "$FHASH"}
  ]
}
EOF
  rc=0; run_case "$SB/a7.json" "$SB/a7.log" || rc=$?
  check "A7 no_proxy 命中时下载成功（exit 0）" "[[ $rc -eq 0 ]]"
  check "A7 代理日志为空（no_proxy 生效，未走代理）" "[[ ! -s '$PLOG' ]]"
  olog_after="$(wc -l < "$OLOG")"
  check "A7 源日志新增请求（确为直连）" "[[ ${olog_after:-0} -gt ${olog_before:-0} ]]"

  # -------------------------------------------------------------------------
  echo "-- A9 超时/重试（不稳定源：首次 503，其后 200）"
  : > "$FLOG"
  FLAKYHASH="$(sha256sum "$FIX/flaky.bin" | awk '{print $1}')"
  cat > "$SB/a9.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_timeout": 5,
  "download_retry_delay": 1,
  "download_items": [
    {"name": "retry.bin", "url": "http://127.0.0.1:$FLAKY/retry.bin", "sha256": "$FLAKYHASH"}
  ]
}
EOF
  rc=0; run_case "$SB/a9.json" "$SB/a9.log" || rc=$?
  check "A9 不稳定源重试后成功（exit 0，用 role 默认 retries）" "[[ $rc -eq 0 ]]"
  check "A9 源日志证明重试发生（/retry.bin 被请求 >=2 次）" \
    "[[ \$(grep -c 'GET /retry.bin' '$FLOG') -ge 2 ]]"
  check "A9 首次请求为 503" "grep -q 'GET /retry.bin 503' '$FLOG'"
  check "A9 重试后制品内容正确" \
    "[[ \$(sha256sum '$ART/retry.bin' 2>/dev/null | awk '{print \$1}') == '$FLAKYHASH' ]]"

  echo "-- A9b 重试次数可配置（download_retries=0 → 不重试，503 即失败）"
  cat > "$SB/a9b.json" <<EOF
{
  "download_root_prefix": "$SB",
  "k8s_artifact_dir": "/opt/k8s/artifacts",
  "download_timeout": 5,
  "download_retries": 0,
  "download_retry_delay": 1,
  "download_items": [
    {"name": "retry0.bin", "url": "http://127.0.0.1:$FLAKY/retry0.bin", "sha256": "$FLAKYHASH"}
  ]
}
EOF
  rc=0; run_case "$SB/a9b.json" "$SB/a9b.log" || rc=$?
  check "A9b download_retries=0 时首次 503 即失败（变量确实生效）" "[[ $rc -ne 0 ]]"
  check "A9b 未重试（/retry0.bin 仅被请求 1 次）" \
    "[[ \$(grep -c 'GET /retry0.bin' '$FLOG') -eq 1 ]]"
  check "A9b 失败时未落盘 retry0.bin" "[[ ! -e '$ART/retry0.bin' ]]"

  echo "-- mock 进程回收（不得残留监听端口）"
  kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null
  check "mock 进程已退出（无残留监听）" "! kill -0 $MOCK_PID 2>/dev/null"
fi

echo
echo "== 汇总: PASS=$pass_count FAIL=$fail =="
[[ $fail -eq 0 ]]
