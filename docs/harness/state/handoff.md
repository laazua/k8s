# 交接摘要（Handoff）

> 仅凭本文件 + `state.yaml` 即可继续工作。最新条目在最上方。
>
> ⚠️ **历史被覆盖（2026-11-06 发现）**：提交 `a1adfe6`（T009 generator）把本文件由 1175 行重写为 47 行
> （`-1128` 行），T001–T008 的交接历史与本会话 T008 r1 评估条目**从工作区丢失**。
> 原始内容可用 `git show a1adfe6^:docs/harness/state/handoff.md` 取回。
> **规则重申：handoff 只允许「在最上方追加」，不得整体重写。**

---

## [2026-11-23] Planner · T016 build 收尾交接（根因已定位，待实现）

> 本轮角色是 **Planner**（写入仅限 `state/` 四文件），代码修复**未执行**；下列 3 处为可直接照做的补丁。

- **现状**：生成者交付已提交 `e90ba07`（提交消息仅 `..`，语义应更正为
  `T016: 端到端全流程验收 + 使用文档`）。静态段 `--static-only` = **100/0**；全流程首跑
  **282/12/2**（rc=2），沙箱已清理、ansible 日志不可得，故用定向复现定位。
- **未提交的工作区改动（保留，勿丢）**：`docs/usage.md`（变量表链接写为字面量 `docs/variables.md`）、
  `tests/e2e/full_flow.sh`（代码块计数改 awk；宿主写保护只判写入动词/重定向）。已实测静态 100/0，
  应与下面 3 处修复一起提交。
- **根因（12 条失败中的 9 条）**：node1 沙箱从未安装 `kube-proxy`（B1 只装配 containerd/kubelet），
  worker 升级组件清单是 `kubelet,kube-proxy` → `upgrade:backup | 备份当前版本二进制` 备份第二项时
  `src` 不存在 → node play 中止 → 之后 node 升级/回滚断言全红（含「二次运行 changed=3」= 备份目录/
  MANIFEST/SHA256SUMS）。**证据**：备份里有 `bin/kubelet`、kubelet 二进制仍 1.31.0。
  **验证**：手工最小 node1 沙箱（旧二进制 + pki + kubelet.conf + config.yaml + 制品）+ 真实
  `playbooks/upgrade.yml --limit node1` → 补齐 kube-proxy 后 **rc=0**、二次运行 **changed=0**
  （生产 worker 的 kube-proxy 由 `node.yml` 安装，缺它属沙箱缺口，不是产品缺陷）。
- **补丁 1（B1 节点装配）**：在 `full_flow.sh` 的 `node1 kubelet 装配 exit 0` 之后加真实装配：
  `ap tests/kube-proxy/sandbox_kube_proxy.yml "$SB/logs/node1_kp.log" -l node1 -e "kube_proxy_root_prefix=$SB/node1"`
  （extra vars 优先级高于 play vars），并断言 `-x "$SB/node1/usr/local/bin/kube-proxy"` 且版本 = `v1.31.0`。
- **补丁 2（快照判定，3 条失败）**：`snapshot_problems()`（约 92–108 行）对 `ports` 空串放行——
  `if k == "ports" and v == "": continue`（`__ERROR__`/`__EMPTY__` 仍判失败）。基线无端口占用是合法的。
- **补丁 3（Cilium 断言，1 条失败）**：断言路径改按 role 变量，真实渲染文件是
  `$SB/etc/kubernetes/cilium/cilium.yaml`（`cilium_manifest_path`），不是 `$SB/etc/cilium/`；
  建议 `find "$SB/etc" -path '*/cilium/cilium.yaml'` 或直接按 `cilium_manifest_path` 断言。
- **建议（非阻塞）**：`ap_cp`/`ap_node` 失败分支打印日志末尾 20–30 行（剥离 `ok/changed/skipping`
  行），避免再次因沙箱清理丢失唯一现场。
- **收尾门禁**：`make test-e2e-full` **双跑**（归一化沙箱路径/PID/耗时后 diff=0）；`make lint` rc=0；
  `test-e2e`/`test-taints`/`test-add-node`/`test-upgrade` 各一次；全量 `make test` 若未跑须在契约 §9 声明。
- **随后**：补契约 §8（红→绿、两次 diff、门禁）与 §9（T017 D1–D5、T018 D1/D6、T019 D1/D2/D3、
  T012 D5–D9 逐条）→ `contract_status: ready_for_eval` / `next_action: "eval T016"` → T016 r1。

---

## [2026-11-20] Generator · T019（T015 测试假绿/一致性加固）→ **ready_for_eval**

- **交付**（只改 `tests/upgrade/`、`roles/upgrade/`、`contracts/T015.md` 措辞；未动 `roles/etcd|pki|download`）：
  - `tests/upgrade/test_upgrade_flow.sh` **268 → 305 PASS**（总条数 270 → 307，SKIP=2 单列）：
    - **D1 MAJOR**：E7/E8 的 `upgrade_bin_dir` 放**真实 1.31.0 旧二进制** → `backup` 通过、`binaries`
      阶段真实执行；断言改独立关键字 `did not match` / `制品版本不符`，并断言官方 sha 出现在报错里、
      `upgrade:binaries | 获取/读取 …` 与 `upgrade:backup | 写入 SHA256SUMS` 任务行出现。
      另修 **E8 的 `-e upgrade_known_sha256={...}`（被当字符串 → 「sha 未固定」假绿）为整份 JSON 注入**，
      并加两条守卫（注入生效 / 未提前失败）。
    - **D2**：新增 `task_status`/`task_changed`，按 `TASK [...]` 块的结果行判定（`changed: [cp1]`），
      3 条真实断言 + 2 条合成日志自检（skipping→判否、changed→判是）。
    - **D3**：`sandbox 资产不写宿主` 改为 `sandbox_prefixed`（真实解析 4 个沙箱资产的 `*_root*` 绑定）
      + inventory local/高位端口；kubepods 改为「新建数=停止数 + 无失败 + loaded 集合回到测试前
      + 选集合逻辑自检」，并打印新建数（实测 0，无 Pod）。
    - **D4**：E8 前置改「假制品 sha ≠ 官方 1.32.13 sha」（+64 位 hex + 与注入值一致）。
    - **D5**：负例 `upgrade_needed=false` + `retention=1`（fake 根）→ changed=0、目录数不变；
      正例 `-e upgrade_version_probe_component=kube-scheduler` + `retention=2` → changed>0、目录数=2。
    - **D6**：4 份日志断言无 `'item' is undefined`。
    - **D7**：两份 README 含多成员覆盖变量、`defaults` 注释、T015 §5 记录（4 条静态断言）。
    - **D8**：PKI/kubeconfig/kubelet.conf 三条断言标注「（辅助）」，注释说明主证据。
  - `roles/upgrade/tasks/validate.yml`：备份裁剪加 `upgrade_needed | bool`（D5）。
  - `roles/upgrade/tasks/{backup,rollback}.yml`：4 处任务名去掉 `{{ item }}`（D6；评测只报了 backup，
    实测 rollback 在 upgrade 路径上同样告警）。
  - `roles/upgrade/defaults/main.yml`：多成员 `member_name`/`peer_url` 覆盖注释（对齐 `roles/etcd`）。
  - `roles/upgrade/README.md`、`tests/upgrade/README.md`：多成员回滚覆盖项 + 主/辅证据口径。
  - `contracts/T015.md` §4 D5 措辞（主证据=bin 哈希）与 §5 多成员覆盖项。
- **TDD**：红（测试先改、实现未改）**289 PASS / 10 FAIL / 2 SKIP**（`/tmp/opencode/t019_red.log`，
  10 条全指向 D1(E8)/D5/D6/D7）→ 绿 **305/0/2** ×2（`t019_greenA.log`/`t019_greenB.log`，
  归一化沙箱目录名+bash 作业 PID+`T015_KEEP_SANDBOX` 调试行后 **diff 0 行**）。
- **门禁**：`make lint` rc=0；`make test-control-plane` 269/0；`make test-node` 291/0；
  全量 `make test` 未跑（~85 分钟成本，已如实声明）。
- **遗留/风险**：kubepods 新建 slice 实测 0（无 Pod），D3 的「只停本次新建」由选集合自检 + loaded
  集合恢复承担；`task_status` 依赖 default stdout callback 格式；多成员 etcd 回滚仍未验证（T015 §5）。
- **下一步**：`eval T019`（`eval_round: 1`）。

---

## [2026-11-19] Generator · T018（T014 零影响/证书幂等加固）→ **ready_for_eval**

- **交付**（只改 `roles/add-node/`、`tests/add-node/`、两份 README；未动 `roles/pki|node|control-plane`）：
  - `validate.yml`：幂等判定改为**内容级**——首跑记录 `node2.state`（`<ca> <cert> <key>` sha256），
    重跑要求「记录一致 ∧ `openssl verify` 链到集群 CA ∧ CN/O 匹配 ∧ `-checkend`」；
    记录不一致/证书失效 → `add_node_cert_reissue`（自愈）；节点 CA 与记录不一致 →
    `add_node_ca_tampered` 显式 assert 失败（不重建/不替换 CA）。
  - `cert.yml`：仅自愈时 `pki_force_regen=true`；签发后写哈希记录；从 T014 升级的节点回填记录
    （不重签）；签发/写记录/清理一律 `when: not ansible_check_mode`。
  - `verify.yml`：Ready 读取 `failed_when: false` + 独立 assert（NotReady 必须有 reason），
    失败信息改为可诊断载荷。
  - `test_add_node_flow.sh`：**231 → 276** 断言（+45）。新增快照逐键守卫（空值/`__ERROR__`/
    `__EMPTY__`/缺键 → FAIL 打印键名）+ **负例注入**；证书哈希基线 + leaf 篡改自愈 + CA 替换显式失败；
    两次 `--check`（cert/verify 读路径）；verify 对未注册节点负例；`kubepods_loaded` 比较；
    `unit_set_hash` 纳入符号链接；D3 断言目标改 `$SB/nonmember`；D8 恒真断言加实载荷。
- **TDD**：红（stash role）**263/13/2**（12 条直击目标 + 1 条级联），日志 `/tmp/opencode/t018_red.log`
  → 绿 **276/0/2** ×2（`t018_green1.log`/`t018_green2.log`，归一化 diff **0 行**）。
- **门禁**：`make lint` rc=0；`make test-e2e` 59/0；`make test-node` 291/0。
  全量 `make test` 未跑（~82 分钟，成本政策；已如实声明）。
- **取舍**：CA 被替换选「显式失败」（无可信 CA 副本，自动替换会掩盖篡改）；leaf 自愈会轮换私钥，
  沙箱不重启 kubelet（与 T014 受限一致）。
- **下一步**：Evaluator 独立复核。牙齿建议：①`snapshot_invalid_keys` 恒返回空 → A1/A3 红；
  ②`already_joined` 回退到「文件存在」→ A5/A7 红；③删 verify Ready 断言 → A13 负例不再 rc≠0；
  ④取反 cert 的 `not ansible_check_mode` → A10/A11 红。

---

## [2026-11-19] Generator · T017（e2e real 模式健壮性）→ **ready_for_eval**

- **交付**（仅 `tests/e2e/`，不改 sandbox 语义）：
  - `smoke.sh`：`need_val` 参数校验（缺值/值像选项 → rc=2，含 `--mode --image x`）；
    `run_real` 重写（healthz 失败即止；`-o json` + python3 一次取回，rc≠0 / 空集 → FAIL；
    Ready 由 `.status.conditions` 解析；`--image` Job 创建被拒 → FAIL 带 API stderr 摘要）；
    `cleanup()` 幂等 + 每步失败 `bad "清理失败: ..."`，`RESULT` 移到 cleanup 之后；
    `kubepods` 只停前后差集新增 slice；Service ClusterIP / CoreDNS 版本改读 role defaults
    （`E2E_SERVICE_IP` / `E2E_COREDNS_VERSION` 覆盖并校验，`CD_SHA_MAP` 显式登记 sha256）。
  - `test_smoke_contract.sh`：31 → **59** 断言（缺值 4 组、`--static-only --mode real`、
    stub kubectl 三态负例、SKIP 恰好 3 条且文案匹配、cleanup 行序 + 动态故障注入）。
  - `tests/e2e/README.md`：新增两个 env 变量、`RESULT` 后置与 real 失败语义、DNS 版本来源。
- **TDD**：红 **43 PASS / 15 FAIL**（58 条，含 `rc=124` 死循环复现与 `PASS 全部节点 Ready（0/0）`）→ 绿 **59/0** ×2
  （两次 diff 仅 static-only 耗时一行；内层 sandbox 仍 **30/0/3**）。
- **其它门禁**：`make lint` rc=0；`make test-taints` 175/0；`make test-add-node` 231/0/2。
  全量 `make test` 未重跑（成本 ~82 分钟，diff 仅 `tests/e2e/`），已在契约 §9 声明。
- **受限**：real 成功路径仍需真机（本机无集群）；跨节点 Pod 仍 SKIP；`kubepods` 差集分支正常运行未触发。
- **下一步**：Evaluator 独立复核（建议反证：删 `nodes==0` 早退、Job 失败改回 `skipped`、cleanup `bad` 改 `true`）。

---

## [2026-11-21] Planner · T019 r1 评估收口（主会话代评）→ 推进 T016（最后一个任务）

- **决策**：T019 r1 = PASS **予以接受**；报告 `reports/T019-r1.md`（功能 5 / 幂等 5 / 可配置 4 / 测试 4 / 结构 5 / 安全 5，完整度 4）。
  报告由**主会话代评**产出（`harness-evaluator` 子代理再次触发 `Free usage limit reached`），已在报告首行注明。
- **roadmap v1.10**：T019 → `done`（已验/受限）；upgrade 268 → **305**；全量预期 **16 套件 / 2583**（未重跑）；
  T019 r1 的 D1–D3 MINOR 并入 **T016 顺手修**（`task_status` 依赖 default callback、D5 负例仅在 fake 根、全量未跑）。
- **spec v1.12**：A15 补「证据口径」——sha256/版本断言须真实执行、回滚证据取任务结果行、目标版本重跑不裁剪备份。
- **状态**：`phase: BUILDING` / `active_task: T016` / `contract_status: accepted`（T019）/
  `next_action: "build T016"` / `done_tasks: 18` / `planned_tasks: 19` / `blockers: []`。
- **下一步**：**T016**（端到端验收与使用文档；T017/T018/T019 均已 accepted，无剩余前置）。

---

## [2026-11-20] Planner · T018 r1 评估收口（主会话代评）→ 推进 T019

- **决策**：T018 r1 = PASS **予以接受**；报告 `reports/T018-r1.md`（功能 5 / 幂等 5 / 可配置 4 / 测试 4 / 结构 5 / 安全 5，完整度 4）。
  该报告由**主会话代评**产出（`harness-evaluator` 子代理两次触发 `Free usage limit reached`），已在报告首行注明。
- **roadmap v1.9**：T018 → `done`（已验/受限）；add-node 231 → **276**；全量预期 **16 套件 / 2546**（未重跑）；
  T018 r1 的 D1–D3 MINOR 并入 **T016 顺手修**（D6 静态断言仅文本、自愈后需重启 kubelet 文档化、全量未跑）。
- **spec v1.11**：A14 补强为「快照逐键有载荷 + 证书内容级幂等 + `--check` 零写入」。
- **状态**：`phase: BUILDING` / `active_task: T019` / `contract_status: accepted`（T018）/
  `next_action: "build T019"` / `done_tasks: 17` / `planned_tasks: 19`。
- **下一步**：T019（T015 测试假绿修复：E7/E8 真实执行 + D2–D8），之后 T016。

---

## [2026-11-19] Planner · T017 r1 评估收口 → 推进 T018

- **决策**：T017 r1 = PASS **予以接受**；报告 `reports/T017-r1.md`（功能 5 / 幂等 5 / 可配置 4 / 测试 4 / 结构 4 / 安全 5，完整度 4）。
- **roadmap v1.8**：T017 → `done`（目标验收保留 + 已验/受限分栏）；e2e 契约 31 → **59** 条；
  T017 的 D1–D5 MINOR 记为 **T016 顺手修**（不新立任务）；任务数仍 19。
- **spec v1.10**：A12 判定细化（缺值 `rc=2`、空集/Job 拒绝一律 FAIL、清理失败影响 `RESULT`、SKIP 条数可断言）；
  全量预期 **16 套件 / 2501 断言**（**未实跑**）。
- **状态**：`phase: BUILDING` / `active_task: T018` / `contract_status: accepted`（T017）/
  `next_action: "build T018"` / `done_tasks: 16` / `planned_tasks: 19`。
- **下一步**：T018（add-node 零影响空值显式失败 + 证书幂等真实化 + D3–D8）；随后 T019，最后 T016。

---

## [2026-11-19] Planner · T015 r1 评估收口 → 推进 T017，新增 T019

- **决策**：T015 r1 = PASS **予以接受**；报告 `reports/T015-r1.md`（功能 5 / 幂等 5 / 可配置 4 / 测试 4 / 结构 5 / 安全 5，完整度 4）。
- **roadmap v1.7**：T015 → `done`（目标验收保留 + 已验/受限分栏）；新增 **T019**（T015 测试假绿/一致性加固），
  T016 依赖追加 T019；任务数 **19**。
- **spec v1.9**：A15 判定细化为「备份可校验 + 运行中 apiserver `/version` 真实变更 + `snapshot restore` 回滚 + 二次 changed=0」；
  成本基线 **15 套件 / 2473 断言 / ~81m39s**（`test-upgrade` 268、~10.2 分钟、SKIP=2）。
- **状态**：`phase: BUILDING` / `active_task: T017` / `contract_status: accepted`（T015）/
  `next_action: "build T017"` / `done_tasks: 15` / `planned_tasks: 19`。
- **下一步**：T017（e2e real 模式健壮性）；随后 T018、T019，最后 T016。
- **环境提示**：宿主 `/tmp/opencode` 需 ≥6G（t015 已加磁盘前置守卫）。

---

## [2026-11-18] Generator · T015（版本升级与回滚）→ **ready_for_eval**

- **交付**：`roles/upgrade`（`validate → backup → binaries → verify`，回滚走
  `rollback_validate → rollback`，同一 role 由 `upgrade_action` 分派）+ **真实入口**
  `playbooks/upgrade.yml`（两 play：`hosts: k8s_master` / `hosts: k8s_node`，各 `serial: 1`，
  tags 全接线）+ `tests/upgrade/`（**268 断言**，SKIP=2 单列）+ Makefile `test-upgrade` 并挂入 `make test`。
- **验收面**：真实 `etcdctl snapshot save` + PKI + kubeconfig + 旧二进制 → 时间戳目录
  （`MANIFEST.txt` + `SHA256SUMS`，失败即中止）；版本变更以**本机二进制 `--version`** 为准、
  集群 `/version` 交叉校验；回滚 = 旧二进制 + **真实 `etcdctl snapshot restore` + 数据目录换入**
  + 证书（内容哈希逐项可证，升级期写入的 ConfigMap 随 etcd 回退消失）；幂等 `changed=0`；
  7 类 fail-fast；`--check` rc=0/changed>0 且不落盘；宿主内容级零污染（只停本次新建 kubepods unit）。
- **门禁**：`make test-upgrade` **268/0/2** ×2（613s / 612s；逐条 diff 仅 bash 打印的 PID 4 行）；
  `make lint` rc=0；全量 `make test` rc=0 / **4899s**，15 套件 = **2473 PASS / 0 FAIL**
  （`27/39/59/100/225/186/269/291/208/229/135/175/231/268/31`）。
- **红 → 绿（5 组修复，见契约 §8.1）**：①制品探针不可执行（缓存 0644）→ 复制到 staging 0755，
  `kubectl` 改 `version --client`；②备份任务在 rollback/`--check` 下的模板错误（`loop_control.label`
  引用被跳过的 `upgrade_backup_dir`、`find` 目录不存在）；③etcd restore 需
  `--initial-cluster` + `--initial-advertise-peer-urls` 一致；④测试资产：`-e` 传 list 改 JSON、
  升级/回滚后加 `wait_node_version`；⑤沙箱 kubelet 1.32 拒绝 loopback `--node-ip` → 改用默认路由源地址。
- **门禁首次跑踩坑（非代码缺陷）**：宿主 `/` 仅剩 1.8G 时沙箱写盘失败 → 级联 22 条假 FAIL；
  清理旧沙箱后同代码全绿。已在套件加**磁盘前置守卫**（`/tmp/opencode` <6G 直接 FAIL 中止），
  评估者复跑前请确认 ≥6G（一次沙箱约 3.2G）。
- **受限**（契约 §5/§9）：单宿主单节点、无 CNI/镜像（node1 Ready=False 有 reason）、无 systemd 启停、
  etcd 单成员、未做系统化变异、`upgrade_manage_service=true` 路径未验证。
- **状态**：`contract_status: ready_for_eval` / `eval_round: 1` / `next_action: "eval T015"` /
  roadmap T015 → `in-progress`。**下一步**：Evaluator 独立复现（优先 6 颗牙齿，见契约 §10）。

---

## [2026-11-17] Planner · T014 r1 评估收口 → 推进 T015，新增 T018

- **决策**：T014 r1 = PASS **予以接受**；报告 `reports/T014-r1.md`（功能 5 / 幂等 5 / 可配置 4 / 测试 4 / 结构 5 / 安全 5，完整度 4）。
- **roadmap v1.6**：T014 → `done`（目标验收保留 + 已验/受限分栏）；新增 **T018**（零影响快照空值显式失败、
  证书幂等真实性、D3–D8），T016 依赖追加 T018；任务数 **18**。
- **spec v1.8**：A14 判定细化为「真实 kubelet 注册 + 既有节点零影响（PID/启动时间/哈希/Node UID）+ 二次 changed=0」；
  成本基线 **14 套件 / 2205 断言 / ~71m24s**（`test-add-node` 231、~10.8 分钟、SKIP=2）。
- **状态**：`phase: BUILDING` / `active_task: T015` / `contract_status: accepted`（T014）/
  `next_action: "build T015"` / `done_tasks: 14` / `planned_tasks: 18`。
- **下一步**：T015（升级与回滚）；T017/T018 仍为 T016 强制前置。

---

## [2026-11-16] Generator · T014（加节点流程）→ **ready_for_eval**

- **交付**：`roles/add-node/`（`defaults` 全变量化；`validate` 分组/CA/版本/证书预检；
  `cert` 复用 `pki:tasks_from: cert` **只签本节点 kubelet 证书**，显式
  `pki_ca_rebuilt: {kubernetes: false}`，**绝不** include `pki:ca|main`；`verify` 在控制端
  `delegate_to` 读回 Node/Ready/reason）+ 真实入口 `playbooks/add-node.yml`
  （`hosts: k8s_node`、`serial: 1`、`tags: [add-node]`；顺序
  validate→cert→containerd→kubelet→verify；`base` 由 `add_node_manage_host` 门控）。
- **测试**：`tests/add-node/test_add_node_flow.sh` **231 断言**（SKIP=2 单列）+ 4 个沙箱 play
  （`sandbox_stack` / `sandbox_node1` / `sandbox_node1_kubelet` / `sandbox_node2_containerd` /
  `sandbox_add_node_nonmember`）+ `inventory.ini`（`ansible_connection=local`，沙箱专用）。
- **Makefile**：新增 `test-add-node`，并挂到 `make test`（第 13 个套件，在 `test-taints` 后）。
- **红 → 绿**：role 未实现 **138 PASS / 93 FAIL**（`/tmp/opencode/t014_red3.log`）→
  `make test-add-node` **231/0/2**；首绿唯一 FAIL 是 Ansible 打印 skipped 任务名含「已加入」
  被误判，改任务名措辞（消息体保留「已加入」，断言未放宽）后全绿。
- **复跑**：`231/0/2` ×2（645s / 651s），去 ANSI 后逐条 diff **仅沙箱临时目录名 2 行不同**。
- **全量**：`make test` **rc=0 / 4284s**，14 套件 = `27/39/59/100/225/186/269/291/208/229/135/175/231/31`
  = **2205 PASS / 0 FAIL**；`make lint` **rc=0**。
- **牙齿**：B7 篡改 `kubelet.conf` 后重跑必须 `changed>0` 并复原；C7 比较器自检 + 快照空值
  显式 FAIL；D1–D6 六组 fail-fast 断言「rc≠0 + 关键字 + 未落盘/未建新 CA」；C5/C6 既有
  node1/apiserver/etcd 的 PID/启动时间/配置哈希/Node UID 全部 `check_eq`（不静默）。
- **受限（已在契约 §5/§9 声明）**：无镜像 → 系统 Pod 不 Running（SKIP=2）；单宿主双运行时；
  无 systemd（handler 重启路径未验）；沙箱不跑 `base`；`preissued` 成功路径未端到端；
  `--check` 不覆盖 containerd/kubelet 写任务；未做实现级 mutation campaign。
- **遗留 / 风险**：`kubepods.slice` 双 kubelet 共享（清理只停本次新建 slice）；`serial: 1`
  多新节点批次未实测；`preissued` 推荐路径需在 T016 文档写清。
- **状态**：`phase: EVALUATING` / `contract_status: ready_for_eval` / `eval_round: 1` /
  `next_action: "eval T014"`；roadmap T014 → `in-progress`（未自行判 PASS）。
- **下一步**：Evaluator r1（建议先按契约 §10 做 1–2 个实现级变异，再按 §9 复核受限项）。

---

## [2026-11-13] Planner · T013 r2 评估收口 → 推进 T014

- **决策**：T013 r2 = PASS **予以接受**（r1 FAIL 的 D1 BLOCKER / D2 MAJOR 均已关闭）。
  报告 `reports/T013-r2.md`：功能 5 / 幂等 5 / 可配置 4 / 测试 4 / 结构 5 / 安全 5，完整度 4。
- **roadmap v1.5**：T013 → `done`（目标验收保留 + 已验/受限分栏）；记录 R2-D1–D4 MINOR 留 T016 收口。
- **spec v1.7**：A13 判定细化为「真实 scheduler 绑定（`spec.nodeName`），无镜像不要求 Running」；
  成本基线更新为 **13 套件 / 1974 断言 / ~61m33s**（`test-taints` 175，单跑 ~5.5 分钟）。
- **状态**：`phase: BUILDING` / `active_task: T014` / `contract_status: accepted`（T013）/
  `next_action: "build T014"` / `done_tasks: 13` / `planned_tasks: 17`。
- **下一步**：T014（加节点流程）—— 注意 T017 仍是 T016 的强制前置，可与 T014 并行。

---

## [2026-11-13] Generator · T013 r2（修复 r1 D1–D7）→ **ready_for_eval**

- **D1 [BLOCKER] `--check`**：nodes 的 3 个只读 `command` 加 `check_mode: false`；写任务与
  写后断言加 `when: not ansible_check_mode`；新增 B11（真实 apiserver 上 `--check` rc=0、
  `changed=0`、污点/标签哈希不变、日志无 `from_json`，随后真实应用 `changed=0`）。
- **D2 [MAJOR] 真机入口**：新增 `playbooks/taints.yml`（`hosts: k8s_master`/`become`/
  `roles: [taints]`/`tags: [taints]`）；README 与契约 §5 改为
  `cp inventory/hosts.example inventory/hosts.yml && ansible-playbook -i inventory/hosts.yml
  playbooks/taints.yml --tags taints`（需已有 admin.conf）；新增 syntax-check 与
  `--list-tasks` 非空断言（16 tasks）。
- **D3–D7**：A4 改「冻结 role `git status` + `roles/taints` 全量 sha256 前后一致」；
  宿主快照内容级（`/etc/kubernetes`、unit 集合+内容、containerd 目录、端口、sysctl、
  kubepods）且采集失败重试 3 次显式 FAIL；清理只停「前后差集」的精确 kubepods unit 并记录
  失败；validate 增 kubectl `stat`+可执行；kubectl 全改 `argv` 列表 + 目标节点列表类型 /
  key/value 字符集校验（含 3 组负例）。
- **红 → 绿**：新增 15 条断言先红 **160 PASS / 15 FAIL**（`t013_r2_red2.log`）；
  `make test-taints` **175/0** ×2（324s / 326s，逐条 `diff` 一致，`t013_r2_green1/2.log`）。
- **全量**：`make test` **rc=0 / 3693s**，13 套件
  `27/39/59/100/225/186/269/291/208/229/135/175/31` = **1974 PASS / 0 FAIL**
  （前 11 套件与 1799 基线一致；taints 144→175；e2e 31）。
- **门禁**：`make lint` rc=0；`playbooks/taints.yml --syntax-check` rc=0；`--list-tasks` 非空。
- **受限项不变（契约 §5/§9）**：Pod 不 Running（无镜像）、cp1 合成 Node、单 worker、CM 控制器子集；
  真机命令已可执行但真实多主机仍待 T016 收敛。
- **提交号**：本条目所在提交（`git rev-parse HEAD`，信息
  `T013 r2: 修复 r1 D1–D7（--check/真机入口/测试卫生）`）。
- **状态**：`contract_status: ready_for_eval` / `eval_round: 2` / `next_action: "eval T013 (r2)"`；
  roadmap T013 保持 `in-progress`。

---

## [2026-11-12] Generator · T013 build → **ready_for_eval**

- **交付**：`roles/taints`（defaults/tasks/meta/README）：给 `[k8s_master]` 写真实
  `node-role.kubernetes.io/control-plane:NoSchedule` 污点 + 角色标签；先 `kubectl get -o json`
  读现状、按需 `taint/label --overwrite`，第二次 `changed=0`；effect 白名单 / 非控制面主机 /
  缺 kubeconfig / kubectl 不可执行均 fail-fast。`tests/taints`（inventory + 4 个 sandbox
  playbook + `workload.example.yml` + `README.md` + 主脚本）**144 断言**；
  Makefile 新增 `test-taints` 并挂入 `make test`（在 e2e 之前）。
- **TDD 红 → 绿**：role 未实现时 **PASS=92 / FAIL=52**（更早两轮 88/55、85/58）；
  实现后 `make test-taints` **144/0**。green3 = 144/0（约 950s），green4 复跑 = 144/0
  （约 327s），PASS/FAIL 全集逐条 `diff` **一致**；B8 幂等 `changed=0`、污点/标签哈希不变。
- **全量回归**：`make test` **rc=0 / 3641s**，13 套件
  `27/39/59/100/225/186/269/291/208/229/135/144/31` = **1943 PASS / 0 FAIL**；
  前 11 套件与 1799 基线逐项一致（新增 taints=144，e2e 仍 31）。
- **牙齿证据（真实调度）**：带污点时 `nodeSelector=cp1` 且无 toleration 的 Pod 停留
  Pending（事件含 untolerated taint）；临时移除污点后同类 Pod 被真实绑定到 `cp1`；
  重跑 role 恢复污点。fail-fast 三组均 rc≠0、错误信息可判定、污点未变。
- **调试关键（仅测试适配，未弱化断言）**：宿主根盘可用 12.9% < kubelet 默认
  `imagefs.available<15%` → `DiskPressure=True` 反复 Evict 已调度 Pod（曾 6103 Pod）。
  在 `tests/taints/sandbox_kubelet.yml` 增加 `--eviction-hard=...<1%`（内存阈值不变）；
  B7 仍要求恰好 3 Pod、全部 node1、0 个 cp1。
- **受限（契约 §5/§9）**：Pod 无镜像不会 Running；`cp1` 为合成 Node 对象（真实 API +
  真实污点，无 kubelet）；单 worker；CM 仅启用 deployment/replicaset/serviceaccount(-token)，
  apiserver 禁用 `TaintNodesByCondition`。真机复验步骤见契约 §5.5。
- **提交号**：本条目所在提交（`git rev-parse HEAD`，信息
  `T013: 调度约束（控制面污点/标签 + 真实 scheduler 绑定验证）`）。
- **状态**：`phase: BUILDING` / `active_task: T013` / `contract_status: ready_for_eval` /
  `eval_round: 1` / `next_action: "eval T013"`；roadmap T013 → `in-progress`。

---

## [2026-11-12] Planner · T012 评估收口 → 推进 T013，新增 T017

- **决策**：T012 r1 = PASS **予以接受**（不返工）；报告 `reports/T012-r1.md`（被测 `37896d8`，六项 4/5/4/4/4/5，完整度 3）。
- **roadmap v1.4**：T012 → `done`（目标验收保留 + 已验/受限分栏）；新增 **T017**（e2e real 模式健壮性修复），
  `T016` 依赖追加 T017；版本对照更新为 17 个任务。
- **spec v1.6**：新增 **C14 冒烟输出与 SKIP 语义**（SKIP 不计入 PASS、禁止空集恒真、可控失败判 FAIL）；
  A12 细化为「一条命令 + 可判定输出」；新增 **R7 冒烟假绿**；成本基线更新为 12 套件 / **1799** 断言 / ~56 分钟。
- **D1–D3 处理**：real 模式空集恒真、`--image` Job 失败降级 SKIP、参数缺值死循环（rc=124）
  定为 **T016 前置门禁**，由 T017 关闭（含 D4/D6/D9）。
- **状态**：`phase: BUILDING` / `active_task: T013` / `contract_status: accepted`（T012）/
  `next_action: "build T013"` / `done_tasks: 12` / `planned_tasks: 17`。
- **下一步**：T013（调度约束：业务仅落 node），Generator 先建契约并写红测试。

---

## [2026-11-12] Generator（限时降级：主会话代做）· T012 build → **ready_for_eval**

- **交付**：`tests/e2e/smoke.sh`（三种模式：`--static-only` / `--mode sandbox` /
  `--mode real --kubeconfig [--image]`），输出逐项 `PASS/FAIL/SKIP` +
  `RESULT/PASS/FAIL/SKIP` 汇总，退出码 0/1/2；`tests/e2e/test_smoke_contract.sh`
  （31 断言）；`tests/e2e/README.md`；Makefile 新增 `test-e2e` / `smoke-e2e` 并挂入 `make test`。
- **沙箱真实链路**：pki → 单成员 TLS etcd → apiserver（16443）→ containerd（CRI
  `RuntimeReady`）→ kubelet（`node1` 注册，`Ready=False/KubeletNotReady` 有 reason）→
  cluster-addons（kubelet.conf 0600、`system:node:node1`、RBAC `can-i`）→ CoreDNS 1.11.3
  解析 `kubernetes.default=10.96.0.1`。固定 3 条 SKIP（系统 Pod / kube-dns / 跨节点）。
- **门禁**：`make test-e2e` **31/0** ×2（324s/319s，逐条一致）；单跑 smoke **30/0/3 SKIP**
  （319s）；全量 `make test` **rc=0 / 3347s**，`27/39/59/100/225/186/269/291/208/229/135/31`
  = **1799 PASS / 0 FAIL**（前 11 套件与 1768 基线逐项一致）。
- **TDD 红**：契约套件先写先跑，**6 PASS / 25 FAIL**；实现后 31/0。
- **牙齿（静态）**：移走 `roles/cilium` → `--static-only` rc=1，`FAIL role 缺失: roles/cilium`。
- **调试修复**：PKI 0700 目录下断言需 `sudo -n test -f`；CoreDNS 解包需 root；
  `kubectl auth can-i` 会追加说明文本，需取首列；`create pods` 受 Node authorizer 影响，
  反例改 `create serviceaccounts`；清理改用有界 kill（不再 `wait`）。
- **受限（契约 §5）**：系统 Pod Running、kube-dns ClusterIP、跨节点 Pod 均未验证（无镜像）。
- **状态**：`phase: BUILDING` / `contract_status: ready_for_eval` / `eval_round: 1` /
  `active_task: T012` / `next_action: "eval T012"` / `done_tasks: 11`；roadmap T012 → `in-progress`。

---

## [2026-11-12] Evaluator（主会话代评；子代理配额失败）· T011 r1 → **PASS（accepted）**

> 被测 `338c3f8`（工作区 clean）。标准未降低；只验证不改代码。

- **结论**：PASS。功能 5 / 幂等 5 / 可配置 5 / 测试 4 / 结构 5 / 安全 5；完整度 4（加权）。
- **代评声明**：`harness-evaluator` 子代理返回 `Free usage limit reached`
  （`https://opencode.ai/go`），按此前授权的限时降级由主会话独立复现并写报告。
- **独立复现**：`test-cluster-addons` **135/0** ×2（356s / 340s，PASS/FAIL 逐条 `diff` 一致）；
  全量 `make test` **rc=0 / 3010s**，`27/39/59/100/225/186/269/291/208/229/135` =
  **1768 PASS / 0 FAIL**（前 10 套件与 1633 基线逐项一致）。
- **牙齿 4/4**（独立 worktree，均从 clean checkout 起）：
  ①`kubeconfig_mode` 改 0644 → 4 红；②RBAC 加 secrets → 3 红（含动态 `can-i`）；
  ③Corefile 域写死 `cluster.local` → 4 红（含 D2 反证）；④去掉 CoreDNS 版本校验 → 2 红。
- **宿主零污染**：`/etc/kubernetes`（absent）、`10.96.0.0/12` 路由（0）、netns（0）、
  systemd unit（0）跑前跑后一致；worktree 已删除，主工作区 clean。
- **非阻塞 D1–D4**：D1 `verify.yml` 断言与 `cluster_addons_kubeconfig_mode` 同源（改 0644 时
  role 自检仍过，仅测试硬编码抓红）；D2 清理断言 `test ! -d "$SB"` 在 `SB=""` 后恒真；
  D3 B4「不落盘」只查 `coredns.yaml`；D4 契约 §5.6 引用的 `real_addons.yml` 未创建。
- **受限核对**：CoreDNS Pod / 集群内 DNS / kubelet 运行态 / 生产 `RBAC,Node` 权限均未验证，
  契约 §5 声明诚实，未夸大。
- **状态**：`accepted` / `eval_round: 1` / `done_tasks: 11` / `active_task: T012` /
  `next_action: "build T012"` / `phase: BUILDING`；roadmap T011 → `done`。

---

## [2026-11-11] Generator（限时降级：主会话代做）· T011 build → **ready_for_eval**

> 交付 `roles/cluster-addons` + `tests/cluster-addons`；未自评 PASS，待独立评估。

- **交付**：kubeconfig（admin/kubelet，内嵌 CA+leaf，`0600 root:root`，默认不覆盖，
  `cluster_addons_rotate_kubeconfigs=true` 强制轮换）；RBAC（kubelet `system:nodes`
  最小权限、**无 secrets**；CoreDNS 只读）；CoreDNS 清单/Corefile（版本、域、上游、
  缓存、端口、镜像仓库、TLS endpoint、ready 端口全变量化；离线渲染）。
- **测试（135 断言）**：A 结构/无硬编码/gitignore；B 渲染、权限、幂等与不覆盖、9 类 fail-fast；
  C 真实 TLS etcd + kube-apiserver 认证 + RBAC 正反例（`auth whoami` / `can-i`）；
  D CoreDNS 1.11.3 官方二进制按渲染 Corefile 真实解析（kubernetes 插件 + forward 到 DNS mock）
  与域变量反证；E 密闭性（空缓存+不可达显式失败、`--check` 不写）与宿主零污染。
- **门禁**：`make test-cluster-addons` **135 PASS / 0 FAIL**，340s/342s，两次逐条 `diff` 一致；
  全量 `make test` **rc=0，3010s**，`27/39/59/100/225/186/269/291/208/229/135` = **1768 PASS / 0 FAIL**
  （前 10 套件与 1633 基线逐项一致，无回退）。
- **红证据**：临时移走 `roles/cluster-addons` → **68 FAIL**（A1 全缺 + 后续渲染/认证/DNS 全红），
  rc=1。**如实记录为「红证据回放」**：本轮为限时降级接管，测试与实现并行编写，非严格先红后绿。
- **调试修复（首轮 125/9 → 135/0）**：`.gitignore` 的 `kubeconfig.*` 吞掉 `tasks/kubeconfig.yml`
  （改名 `kubeconfigs.yml`）；RBAC secrets 断言误匹配注释；`coredns_version` 未定义；
  `can-i` 受 Node authorizer 隐式放行（沙箱 apiserver 改 RBAC 单模式）；`ready` 在 `:8181`
  而非 metrics 端口（新增 `cluster_addons_coredns_ready_port`）；D2 断言把可解析名误判为 NXDOMAIN；
  `pgrep -f "$SB/"` 自匹配。
- **受限（契约 §5）**：CoreDNS Pod Running / 集群内 DNS / kubelet 运行态 / 生产 `RBAC,Node`
  下 kubelet 实际权限（含 Node authorizer）均**未验证**；真机复验步骤已给（注：
  `tests/cluster-addons/real_addons.yml` 尚未创建）。
- **状态**：`phase: EVALUATING` / `contract_status: ready_for_eval` / `eval_round: 1` /
  `active_task: T011` / `next_action: "eval T011"` / `done_tasks: 10`；roadmap T011 → `in-progress`。

---

## [2026-11-10] Evaluator（独立子代理）· T010 r1 → **PASS（accepted）**

> 被测 `eb22fb9`（工作区 clean，`git diff eb22fb9` 为空）。标准未降低；只验证不改代码。

- **结论**：PASS。六项：功能 5 / 幂等 5 / 可配置 5 / 测试 4 / 结构 4 / 安全 4；完整度 4（加权）。
- **独立复现**：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test-cilium` **4 次**均 `229/0` rc=0
  （67.1s/67.7s/67.3s/…，PASS 集逐条 `diff` 一致；要求 2 次，实际 4 次）。`make lint` rc=0。
- **核心数据面**：独立建 2 netns + veth + VXLAN（VNI=7、port=9472、mtu=1400 取自渲染 ConfigMap）：
  underlay 通、路由 `dev vxlan0`、ICMP 2/2、HTTP 返回 `DP-OK-EVAL`；VNI 不一致 / 端口不一致
  独立复现均为 underlay 通、Pod IP 不通。
- **fail-fast**：独立 19 例（mode/CIDR/conflict/version/name/API/port/MTU/cluster-id/registry/
  namespace/pullPolicy/operator 副本）全部 rc=2、错误可定位、已渲染哈希不变；全新沙箱不落盘；
  `replacement=true+enabled=false` 合法 rc=0，`true+true` rc=2（r2 修复成立）。
- **宿主零污染**：4 次后无 netns/vxlan/测试路由/进程/沙箱；宿主 iptables 规则（去 counters/时间戳）
  逐行一致；`/etc/kubernetes` 前后均不存在；无 8472/9472/18081 监听。
- **牙齿 4/4**（worktree，主工作区 clean）：①模板随机 nonce → B3 4 红；②模板 MTU 硬编码 1450
  → 5 红（A3/B1/B1b/泄漏）；③删 Pod CIDR 校验 → B2/B3 共 18 红；④正例一侧端口错配
  → ICMP/MTU/HTTP/反证后 4 红。
- **全量处理**：按成本政策未重跑；核对 `t010_r2_full.log`：rc=0、44m41.765s，10 套件
  `27/39/59/100/225/186/269/291/208/229` = **1633** PASS/0 FAIL；前 9 套件与 T009 基线
  （1404）逐项一致，cilium 段 229 与本次 run1 PASS 集逐条一致。**发现 §8/state/handoff/commit
  的 `1526` 是误加，应为 1633（D1，文档修正，非阻塞）**。
- **非阻塞项**：D1 总数更正；D2 B5 的全局 vxlan 计数与采集失败静默（spec v1.5 残余）；
  D3 `pkill -f "http.server 18081"` 宿主进程匹配过宽；D4 真机前需补 operator `leases` RBAC /
  CNI 安装 init container（契约已声明运行态未验证）。
- **诚实性**：契约 §5.1–5.8 与 READMEs 如实声明 agent/Pod 网络/`cilium status`/Node Ready 未验证，
  内核 VXLAN ≠ Cilium BPF；真机步骤已给。
- **状态**：`accepted` / `eval_round: 1` / `done_tasks: 10` / `active_task: T011` /
  `next_action: "build T011"` / `phase: BUILDING`；roadmap T010 → `done`。
  报告：`docs/harness/state/reports/T010-r1.md`。

---

## [2026-11-10] Generator（主会话代执行）· T010 r2 修复 → **ready_for_eval**

> 子代理再次 `Free usage limit reached`（`https://opencode.ai/go`），按既定降级由主会话续做；
> 修复内容是子代理遗留的 T010 缺陷，评估标准未降低。

- 基线：`a5cd3bb` + 未提交的 `roles/cilium`、`tests/cilium`、`Makefile`、`contracts/T010.md`。
- **r1 全量门禁结果（子代理留存）**：前 8 套件全 PASS；`cilium` **221/8**，
  8 条失败全在 **B1b geneve 变体**。
- **根因（产品 bug + 自相矛盾用例）**：
  1. `roles/cilium/tasks/validate.yml` 的冲突断言写成
     `not (replacement and not enabled)` → 把**合法组合** `replacement=true + enabled=false`
     判为冲突（`t010_variant_geneve.log` 可见反向前提）；
  2. `tests/cilium/test_cilium_role.sh` 的 `conflict` 用例也传
     `replacement=true + enabled=false` 并期待失败，与 B1b 自相矛盾，掩盖了 bug。
- **修复**：断言改为 `not (replacement | bool and enabled | bool)`（仅同时启用才冲突）；
  任务名/fail_msg/契约 §4 B2/conflict 用例（改为 `enabled=true`）同步；
  **TDD 顺序**：B1b 先红（221/8）→ 改实现 → 绿（229/0）。
- **门禁**：
  - `make lint` rc=0（yamllint 无输出，5 份 playbook syntax OK）；
  - `make test-cilium` **连跑两次 229/0**（67s/68s，PASS 集逐条一致）；
  - 全量 `make test` **rc=0，44m42s**：`27/39/59/100/225/186/269/291/208/229` = **1633**，无回退；
    （原误写 1526，已按评估 D1 更正）
  - 宿主：无残留 netns/进程/VXLAN/沙箱。
- 产物：`contracts/T010.md` §8/§10.3 已填、状态 `ready_for_eval`。
- 状态：`state.yaml` → `phase: EVALUATING`、`active_task: T010`、`contract_status: ready_for_eval`、
  `eval_round: 0`、`next_action: "eval T010"`；roadmap T010 → `in-progress`。
- **Generator 不自判 PASS。**

---

## [2026-11-07] Evaluator（主会话临时兼任）· T009 r2 → **PASS**

> 角色隔离降级（`harness-evaluator` 子代理再次提前结束/受限流；经用户此前授权由主会话兼任）。
> 评估标准未降低。被测提交：`741464d`（产品 `a1adfe6` + r1 测试修复）。

### 结论与评分
| 维度 | 分 | 依据 |
| --- | --- | --- |
| 功能正确性 | 5 | ClusterIP 经真实 kube-proxy DNAT 返回 `MOCK-OK-T009`；端点移除→失败→恢复→成功 |
| 幂等/可重入 | 5 | 每轮 B8 `changed=0`；牙齿 `changed_when: true` → 红 |
| 可配置/接缝 | 4 | 全变量化、两套件模板；`bindAddress` 语义已澄清 |
| **测试质量** | **4（≥4 达标）** | r1 flaky 已消除（修复后 **10/10 连续绿**：generator 5 + evaluator 5）；牙齿 5/5（r1）+ 3/3（r2）；MINOR：B10 端口集合漏 etcd peer `12380` |
| 结构/可维护 | 4 | role 16 文件分层清晰 |
| 安全 | 4 | healthz/metrics 默认 `127.0.0.1`、kubeconfig `0600 root:root`、无 `0.0.0.0` 默认 |
| 完整度 | 4 | §5 受限声明诚实（DaemonSet 未运行、无 Pod 流量、systemd 未在宿主启动） |

### 独立复现证据
- **目标套件 5 次**（evaluator 独立跑）：`208/0`、`208/0`、`208/0`、`208/0`、`208/0`，**5/5 rc=0**（276/274/273/275/274s）
  → 日志 `/tmp/opencode/t009_r2_run{1..5}.log`、`t009_r2_5runs.txt`。r1 的 `B10` 随机红未复现。
- **全量门禁**：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` **rc=0，43m17s**，
  `27/39/59/100/225/186/269/291/208` = **1404 全 PASS**，零回退（`t009_r2_full.log`）。
- **静态**：两份 playbook `--syntax-check` 通过；`yamllint` 0 输出（`t009_syntax_*.log`）。
- **核心验收为真**：mock 绑 `10.0.0.10/32 dev lo`，ClusterIP `10.96.0.50` 未绑任何接口；
  `curl` 仅能经 DNAT 到达。逐轮 B4（DNAT 规则）/B5（200+响应体）/B6（后端故障）/B7（端点移除）全 PASS。
- **密闭性**：空缓存 + 不可达 URL → 显式 `failed=1`（`t009_b0_empty.log`）；缓存命中 → 成功（`t009_b0_offline.log`）。
- **收尾**：无残留进程/netns/沙箱/worktree；`git status` clean；`git ls-files` 无凭据。

### r2 牙齿实验（`git worktree`，主工作区 clean）
| # | 变异 | 结果 |
| --- | --- | --- |
| T1 | EndpointSlice 端口 `18080→18081` | rc=2，`202/6`（B4/B5/B6 核心断言） |
| T2 | `verify.yml` 加 `changed_when: true` | rc=2，`207/1`（B8 changed=0） |
| T3 | `healthzBindAddress` 改 `0.0.0.0:10256` | rc=2，`206/2`（A6 两条） |

> T1 期间有一次并发残留进程写入同一日志，尾段第二次汇总（198/10）不计入；首段 `202/6` 的失败项均为预期的核心断言。

### r1 修复验收（B10 flaky）
- 修复方式符合 spec v1.5：快照收敛为本任务端口集合、空值重试 20×0.2s、耗尽显式失败、失败落 diff。
- 函数级反证（evaluator 独立）：前 2 次空 → 第 3 次成功；前 19 次空 → 第 20 次成功；全空 → rc=1；
  正则失效 → 泄漏被过滤成空（确认断言依赖该正则，**非假绿**）。
- 端到端注入：完整套件 + `ss` 前 2 次空返回 → B10 PASS、`208/0`（generator 证据）。

### 非阻塞项（记入后续，不影响本任务 PASS）
- **M1**：`TASK_PORTS_RE` 未包含 etcd peer `12380`（inventory `etcd_peer_port`）→ B10 端口泄漏检测存在盲点；
  建议 T010 或收尾任务补入并加断言。
- **M2（保留）**：`kube_proxy_kubeconfig_source` 默认 `admin.conf`（引导凭据），专用 `system:kube-proxy` 凭据属 T011。
- **N1**：`reports/T009-r2.md` 因本会话写权限受限未落盘，完整报告即本条。

- 状态：`accepted` / `eval_round: 2` / `done_tasks: 9` / `active_task: T010` / `next_action: build T010` / `phase: BUILDING`；
  roadmap T009 → `done`。

---

## [2026-11-06] Generator · T009 r1 修复（B10 flaky）→ **ready_for_eval**

> 仅改测试与契约/状态；产品 role 未改（评估 r1 结论：功能/安全均通过，唯一阻塞为测试缺陷）。

- 基线：`f5f97a6`（被测 `a1adfe6`）；工作区修复后待评估。
- **B10 根因**：`host_ports()` 无空值重试/无失败信号；断言比较**全局**宿主监听端口，
  被无关进程抖动干扰；失败不落 diff。
- **修复**（`tests/kube-proxy/test_kube_proxy_role.sh`）：
  1. `host_ports()` 对齐 `host_ipt_raw()`：空输出重试 20×0.2s，耗尽返回非零；
     PRE/POST 采集失败显式 `bad` + 哨兵，不把「采集失败」误判为「端口变化」。
  2. B10 快照收敛为**本任务端口集合**（16443/12379/20247/20249/18080），
     不再断言全局宿主状态；无关进程增删监听端口不影响结果。
  3. 失败落 `/tmp/opencode/t009_host_ports.diff`（任务端口子集 + 全量诊断 diff）。
  4. N1：`ip route add $SVC_IP/32 dev lo` 加注释（DNAT 在 OUTPUT 生效，不构成绕过）。
  5. M2：契约 A6 精确为「healthz/metrics 不得 `0.0.0.0`」；注明 `bindAddress`
     的 `0.0.0.0` 是代理源地址语义。
- **5 次连续运行**（`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test-kube-proxy`）：
  `208/0`、`208/0`、`208/0`、`208/0`、`208/0`，**5/5 rc=0**（272–275s）。
- **反证**：
  - 函数级（PATH 注入假 `nsenter`）：旧实现 POST 瞬时空 → PRE≠POST 红；
    新实现前 2 次空 → 重试后绿；前 19 次空 → 第 20 次成功；全空 → rc=1。
  - 端到端：完整套件注入前 2 次 `ss` 空返回 → B10 PASS，`208/0`，rc=0。
- **全量**：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` rc=0，2611s，
  `27/39/59/100/225/186/269/291/208` = 1404，FAIL=0（T001–T008 无回退）。
- 收尾：无残留进程/netns/沙箱目录；工作区提交见下条 commit。
- 状态：`ready_for_eval` / `phase: EVALUATING` / `next_action: eval T009 (r2)`；
  roadmap T009 保持 `in-progress`。**Generator 不自判 PASS。**

---

## [2026-11-06] Evaluator（主会话临时兼任）· T009 r1 → **FAIL**

> 角色隔离降级（子代理持续 `Free usage limit reached`，经用户授权）。评估标准未降低。

- 被测：`a1adfe6`；**结论 FAIL**；唯一阻塞为**测试代码缺陷**，产品 role 通过全部功能/安全验收。
- 评分：功能 **5** / 幂等 **5** / 可配置 4 / **测试 3（< 阈值 4）** / 结构 4 / 安全 4；完整度 4。

### 证据
- **全量门禁**：`make test` 一次 rc=0，43m38s，`27/39/59/100/225/186/269/291/208` = **1404**，`FAIL=0`。
- **目标套件 5 次**：`208/0`、**`207/1`（rc=2）**、`208/0`、`208/0`、`208/0` → **约 20% 概率随机红**。
- **唯一失败断言**：`FAIL B10 宿主监听端口快照一致`（`tests/kube-proxy/test_kube_proxy_role.sh:964`）。
- **根因**：`host_ports()`（`:434-436`）直接 `nsenter -t 1 -n ss -ltn | awk | sort | tr`，
  **无空值保护/无重试**；相邻 `host_ipt_raw()`（`:424-432`）有 20 次空值重试。
  ports 断言失败时**不落 diff**（iptables 有 `t009_host_ipt.diff`）。
- **排除自身干扰**：0.25s 间隔 869 次采样 `nsenter -t 1 -n ss -ltn` 行数恒为 13、无空输出；
  150s 静置前后快照一致 → 低频瞬时（`ss` 瞬时异常或共享宿主无关监听抖动）。
- **核心验收为真（不可伪造）**：mock 绑 `10.0.0.10/32 dev lo`，ClusterIP `10.96.0.50` 未绑任何接口；
  牙齿把 EndpointSlice 端口改 18081 → `B4 DNAT`、`B5 ClusterIP 200/响应体`、`B6` 共 **6 条**断言全红。

### 牙齿实验 5/5 命中
| # | 变异 | 结果 |
| --- | --- | --- |
| T1 | EndpointSlice 端口 18080→18081 | rc=2，`202/6`（B4/B5/B6 核心断言） |
| T2 | `healthzBindAddress` 改 `0.0.0.0:10256` | rc=2，`206/2`（A6 两条） |
| T3 | 删除 `ip_vs` 模块 fail-fast | rc=2，`204/4`（B9 ipvs 分支） |
| T4 | `verify.yml` 加 `changed_when: true` | rc=2，`207/1`（B8 changed=0） |
| T5 | `kubeconfig_mode` 0600→0644 | rc=2，`206/2`（A6/B3 权限） |

### 修复要求（r1，只改测试）
1. `host_ports()` 与 `host_ipt_raw()` 对齐：**空值重试**（≥20 次）+ 失败返回非零；
2. 断言失败时落 diff：`/tmp/opencode/t009_host_ports.diff`；
3. 更彻底：把快照**限定为本任务相关端口**（或排除系统已知端口），不要断言全局宿主状态；
4. 修完须证明：连续 **≥5 次** `make test-kube-proxy` 全绿，并说明如何验证不再 flaky。

### 非阻塞项
- **M2**：契约 A6「无 `0.0.0.0` 默认」与 `kube_proxy_bind_address: 0.0.0.0`（README 说明"不真正 bind"）措辞冲突 → 建议契约精确为「healthz/metrics 不得 0.0.0.0」。
- **N1**：测试 `ip route add $SVC_IP/32 dev lo`（`:646`）缺注释，读者易误以为绕过 kube-proxy（实测不会，DNAT 在 OUTPUT 生效）。
- **N2**：`kube_proxy_kubeconfig_source` 默认取 `admin.conf`（引导凭据），已在契约 §5.4 声明；后续编排应换专用 `system:kube-proxy` 凭据。
- **N3**：本文件历史被 `a1adfe6` 覆盖（见顶部说明），属流程违规，需在下次生成时避免。

- 状态：`changes_requested` / `eval_round: 1` / `next_action: build T009 (fix r1)` / `phase: BUILDING`；
  roadmap T009 保持 `in-progress`；`done_tasks: 8`。
- 注：`reports/T009-r1.md` 因本会话写权限受限未落盘，完整报告见本条。

---

# 交接摘要（Handoff）· T009

> 硬要求：**仅凭本文件 + `state.yaml` 就能继续工作**，不需要翻聊天记录。保持短。

- 时间：2026-11-04
- 角色：generator
- 当前任务：T009（kube-proxy role）
- 本次做了什么：
  1. 交付 `roles/kube-proxy`：**官方二进制 + systemd**（契约 §1.1 声明理由：registry 不可达 →
     DaemonSet 无法真实运行；二进制可真跑并完成 A9 验收）。变量化版本/sha256/路径/端口/
     `--cluster-cidr`（Pod CIDR）/proxy-mode/healthz/metrics/conntrack/iptables/ipvs。
  2. 安全默认：healthz/metrics 绑 `127.0.0.1`；kubeconfig `0600 root:root`（source 复制
     或 embedded 内嵌证书两分支）。
  3. fail-fast（落盘前）：proxy_mode 非法、cluster-cidr 缺失/非法、hostname 空、
     kubeconfig 缺失/为空、iptables 依赖缺失、ipvs 但 `/proc/net/ip_vs` 不存在、sha256 非法、
     安装后版本不匹配。
  4. 新增 `tests/kube-proxy/`（208 断言）：静态 A1–A10 + 动态 B0–B10；套件自动
     `sudo unshare -n`（仅 lo）内跑**真实** pki + etcd + kube-apiserver + kube-proxy，
     手工 Node/Service/EndpointSlice + 本地 mock HTTP，**实测 ClusterIP 返回 200**。
  5. `Makefile` 增 `test-kube-proxy` 并挂入 `make test`；契约 §5 声明全部受限项。
- 改了哪些文件：
  - `roles/kube-proxy/{defaults,tasks,templates,handlers,meta}/…, README.md`
  - `tests/kube-proxy/{test_kube_proxy_role.sh,inventory.ini,sandbox_stack.yml,sandbox_apiserver.yml,sandbox_kube_proxy.yml,real_kube_proxy.yml,README.md}`
  - `Makefile`（`test-kube-proxy` + 纳入 `test`）
  - `docs/harness/state/{contracts/T009.md,state.yaml,roadmap.md,handoff.md}`
- 怎么验证（给下一位）：
  ```
  make lint
  make test-kube-proxy            # 208/0；约 3–4 分钟（首次需外网预取制品）
  make test                       # 全量（约 40 分钟）
  ```
  动态证据：B5 `curl http://10.96.0.50/health` → `HTTP/1.0 200` + `MOCK-OK-T009`；
  B4 `iptables-save -t nat` 含 `KUBE-SERVICES` 与 `DNAT --to-destination 10.0.0.10:18080`；
  B8 连跑第二次 `changed=0`、无 handler、PID/starttime/哈希不变。
- 测试/幂等结果：红 `PASS=7 FAIL=17`（role 缺失）→ 绿 `PASS=208 FAIL=0`，连跑两次一致；
  全量 `make test` 一次 **rc=0 / 43m38s**（2026-11-05 复验），各套件
  27/39/59/100/225/186/269/291 + 新增 208 = **1404 断言全 PASS**，既有套件计数逐项与基线
  相同（无回退）；明细见契约 §8.1，日志 `/tmp/opencode/t009_verify_full.log`。
  交付首轮证据：`/tmp/opencode/t009_green{1,2}.log`、`/tmp/opencode/t009_full.log`。
- 复验记录（2026-11-05）：`make lint` rc=0；`make test-kube-proxy` 两次 rc=0（275s/273s，
  208/0，PASS 集仅沙箱目录名/PID 不同）；全量 `make test` 一次 rc=0（43m38s，1404/0）。
  测试后无残留 kube-proxy/apiserver/etcd 进程、无 netns、无 `/tmp/opencode/t009.*` 沙箱目录，
  宿主无 `/etc/kubernetes` 与 kube-proxy unit。
- 遗留问题 / 风险 / 待办：
  - 受限（契约 §5，均不得表述为「已验证」）：宿主 systemd `active/enabled`、多节点
    DaemonSet 调度、Pod 级 ClusterIP（无镜像/无 Pod）、专用 `system:kube-proxy` 凭据（T011）、
    ipvs 动态验证（宿主 `ip_vs` 未加载，仅 fail-fast）。
  - 测试夹具（非产品逻辑，契约 §5.6）：手工 Node、`lo` 上 `10.0.0.10/32` 与
    ClusterIP 网段 `dev lo` 路由、本地 mock HTTP 后端。
  - `ansible-lint` 仍不可得（repo-conventions §8），静态门禁为 syntax-check + yamllint。
  - T008 遗留（未在本次处理，避免越界）：证书身份不符缺定向 fail-fast 断言；
    `--cgroup-driver` 已弃用（T015）。
- 下一步建议（`state.yaml.next_action`）：`eval T009`。
