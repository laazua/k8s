# 交接摘要（Handoff）

> 仅凭本文件 + `state.yaml` 即可继续工作，无需翻聊天记录。
> 最新条目在最上方。

---

## [2026-10-19] Generator · T003 实现完成（build）→ ready_for_eval

- 时间：2026-10-19
- 角色：Generator（harness-generator 子会话；只做 `active_task: T003`，未自判 PASS）
- 当前任务：`T003`（下载与代理 role `download`）
- 本次做了什么：
  1. 写契约 `docs/harness/state/contracts/T003.md`（A1–A12 可判定验收项 + 幂等非典型例外 + **受限声明**）。
  2. **TDD**：先写全离线测试（`tests/download/mock_servers.py` + `fixtures` + `run_role.yml` +
     `test_download_role.sh`）→ 红灯 `PASS=18 FAIL=37`（`the role 'download' was not found`，exit 1）。
  3. 实现 `roles/download`：`defaults`（items/timeout/retries/proxy_env/cache_dir 全部变量化）、
     `tasks/main.yml`（validate → resolve → dirs → fetch → verify）、`handlers`、`meta`、`README.md`。
  4. 绿灯：`tests/download/test_download_role.sh` → **`PASS=59 FAIL=0`**，exit 0。
  5. `Makefile`：`test` 目标纳入新套件，并加 `test-download` 便捷目标。
- **怎么验证**：
  ```bash
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test        # T001 PASS=27 | T002 PASS=39 | T003 PASS=59，exit 0
  make test-download                                     # 仅 T003 套件，全离线
  tests/download/test_download_role.sh
  ```
- **测试/幂等结果**：`make test` **连跑两次**均 exit 0、`PASS=27/39/59 FAIL=0`，两次去色日志 diff 无差异；
  T003 用例内第二次执行 `changed=0`；已存在制品 `inode/mtime/size` 不变；**源不可达时 `changed=0`**
  （证明「已存在且 hash 相符 → 跳过」不发网络请求，可离线预置制品）。
- **关键设计决策**：
  - 强校验用 `get_url` 的 `checksum: "sha256:<hex>"`：实测「hash 不符 → 任务失败且 **dest 不落文件**」，
    无半成品残留；另有 `download:verify` 落盘后独立复验作纵深防御。
  - `download:validate` 强制每项提供 64 位 hex `sha256`（缺省/非法 → **fail fast，绝不降级为 warning**）。
  - 代理用 `environment: "{{ download_proxy_env }}"`（缺省 `{{ proxy_env }}`），实测 `http_proxy` 生效、
    `no_proxy` 被尊重（绕过代理且直连成功）。
  - 重试用任务级 `until/retries/delay`（实测 `loop` + `until` 为**逐项**重试）。
  - **唯一非典型幂等例外（已在契约 §5 声明）**：制品已存在但 sha256 不符 → 视为缓存损坏并**重新下载**（自愈）。
- **牙齿实验（7 组，仓库副本上执行，主工作区零污染）**：E1 删 `checksum`→FAIL×4；E2 删 `environment`→FAIL×1；
  E3 默认 retries=0→FAIL×3；E3c 删 `until/retries/delay`→FAIL×3；E4 放宽 sha256 正则→FAIL×2；
  E5 `force: true`→FAIL×1；E6 制品目录脱离沙箱前缀→FAIL×9。
  **E3 首轮未被捕获**（测试自己 `-e` 传了 `download_retries` 覆盖 role 默认）→ 已修正测试：
  A9 改用 role 默认，并新增 **A9b**（`download_retries: 0` 必须失败且源仅被请求一次）双向锁定该变量。
- **受限声明（对应 spec R1）**：本环境 registry 不可达、**禁止外网**，故不使用 molecule/testinfra，
  改用**本地 mock HTTP 源 + mock 正向代理 + mock 不稳定源**真实验证；**真实 k8s 官方制品（dl.k8s.io）的
  下载与 sha256、以及真实 HTTPS 的 `validate_certs` 无法在此验证**，须按契约 §6 的步骤在联网/真机复验。
- 改了哪些文件：`roles/download/**`（新增）、`tests/download/**`（新增）、`Makefile`、
  `docs/harness/state/contracts/T003.md`（新增）、`state.yaml`、`roadmap.md`（T003 → in-progress）、本文件。
  **未改** `tests/skeleton/`、`tests/base/`、`roles/base/`；**未接入** `playbooks/site.yml`（契约 A12 有断言）。
- 遗留项 / 风险（非阻塞）：
  - 真实制品与真实 HTTPS 未验证（见上「受限声明」）。
  - 测试失败时会**保留**沙箱目录（`/tmp/opencode/t003.XXXXXX`）并写 `t003_last_ports.json` 供排障；成功则清理。
  - 制品属主/属组因 `omit` 无法经 `set_fact` 存续，改在 fetch 的模块参数层解析（tasks 内已注释）。
- 下一步：`eval T003`（Evaluator 独立复现；`eval_round` 由 Evaluator 置 1）。

---

## [2026-10-19] Evaluator · T002 评估第 2 轮 → PASS（eval）

- 时间：2026-10-19
- 角色：Evaluator（harness-evaluator 子会话，独立复现；未改任何代码/测试/契约）
- 当前任务：`T002`（被测提交 `741a926`，上一轮 `fd9d4ec` FAIL）
- 结论：**PASS**（报告 `reports/T002-r2.md`）；六项硬指标均达标（功能 5 / 幂等 5 / 可配置 4 / 测试 4 / 结构 4 / 安全 4；产品完整度 4），阻塞 0。
- 复现：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` 连跑两次均 exit 0、T001 `PASS=27`、T002 `PASS=39`、`FAIL=0`，两次去色日志**完全一致**（核对 Generator 声称的 39 一致）。独立沙箱第二次 `changed=0`；0644/0755 权限、swap 注释、hosts 精确条目全部复核通过。
- **D1（MAJOR）确认修复**：自建探针（不引用仓库测试脚本）独立验证 Debian→`chrony`、RedHat→`chronyd`、`-e base_ntp_service=…` 覆盖生效、Suse 落 else 分支；回退写死 `chronyd` 立即 `FAIL NTP 服务名解析：Debian → chrony`。
- **牙齿实验 6/6 全部被捕获**（临时 worktree + private mount namespace，宿主零污染）：E1 回退 D1→FAIL；E2 删 hosts 循环→A5 两条精确行 FAIL；E3 `changed_when: true`→A6 FAIL；E4 mode 0600→A2 权限 FAIL；E5/E6 让 dest 绕过前缀（sysctl / hosts）→A10 打印前后哈希并 FAIL。
- 其余复核：D2/D3/D6 **确认修复**（含 E2/E5/E6 牙齿）；D4 spec v1.2 与 role README、契约 §5 口径一致；**D5 维持如实记录**（`make smoke` 仍 0 task、`site.yml` 未接入 `base`，未被悄悄"修绿"）。回归：`741a926` 未触碰 `tests/skeleton/`、`playbooks/`、`roles/base/tasks/*`，测试脚本 diff 为纯新增。
- 非阻塞项（N1–N6）：A9 仍整段跳过 NTP tag；A11 "用户覆盖" case 只证明 extra-var 优先级；缺 `base_disable_swap=false` 等配置变体负例；fstab 行首空白正则；README 裸 `ansible-playbook` 缺运行前提；smoke 0 task 建议后续独立 smoke playbook 解决。
- 改了哪些文件：`docs/harness/state/reports/T002-r2.md`（新增）、`state.yaml`（accepted / eval_round 2 / done_tasks 2 / active_task T003 / phase BUILDING）、`roadmap.md`（T002 → done）、本文件。
- 下一步：`build T003`（下载与代理 role：URL+sha256 校验、代理、本地缓存、幂等）。

---

## [2026-10-19] Generator · T002 修复 r1 → ready_for_eval（build）

- 时间：2026-10-19
- 角色：Generator（harness-generator 子会话；只做 `active_task: T002`，未自判 PASS）
- 当前任务：`T002`（主机准备 role `base`，修复 `reports/T002-r1.md` 的 D1/D2/D3/D6 + D4 README 部分）
- 本轮修了什么：
  1. **D1（MAJOR）**：`roles/base/defaults/main.yml` 的 `base_ntp_service` 改为按发行版求值
     `{{ 'chronyd' if ansible_os_family == 'RedHat' else 'chrony' }}`；仍是 role default，
     `group_vars`/`host_vars`/`-e` 可覆盖。`roles/base/README.md`「关键变量」补上 `base_ntp_service`。
  2. **D2（MINOR）**：A5 新增 hosts 精确行断言 `grep -qx '10.0.0.11 k8s-master1'` /
     `grep -qx '10.0.0.21 k8s-node1'`（补 E4 未捕获的缺口）。
  3. **D3（MINOR）**：A10 隔离断言扩展到四个真实宿主路径
     `/etc/sysctl.d/99-kubernetes.conf`、`/etc/modules-load.d/99-kubernetes.conf`、`/etc/hosts`、`/etc/fstab`
     （前后内容 sha256 对比，缺失记 `__MISSING__`）。
  4. **D6（NIT）**：README「仅落盘」示例改为直接运行 `tests/base/sandbox.yml`
     （`SB=$(mktemp -d)` + `-e sandbox_root=$SB --skip-tags base:system`），不再依赖先接入 playbook。
  5. **D4（README 部分）**：README 与契约 §5 的「无 systemd」更正为「PID1=systemd、免密 sudo 可用；
     但为共享开发机，禁止 swapoff/sysctl/改主机名等破坏性主机级变更；无可用容器、registry 不可达」。
     `spec.md` 由 Planner 维护（v1.2），本轮未改。
- **红 → 绿证据**：
  - 先加 `tests/base/assert_ntp_service.yml` + 新断言，修复前跑：Debian 分支
    `FAIL NTP 服务名解析：Debian → chrony`，`PASS=38 FAIL=1`，exit 1（`/tmp/opencode/t002_red.log`）。
  - D2 牙齿实验（临时副本删 hosts 条目循环）：两条精确行断言 FAIL，`PASS=36 FAIL=3`
    （`/tmp/opencode/t002_d2_teeth.log`）。
  - D3 牙齿实验（临时副本清空 `base_root_prefix`，`unshare -rm` 私有 mount namespace 内 bind `/etc`）：
    四个路径全部报「被污染」，`PASS=22 FAIL=17`（`/tmp/opencode/t002_d3_teeth2.log`）；
    namespace 退出后宿主四路径复核干净。
  - 修复后单跑：`tests/base/test_base_role.sh` → **`PASS=39 FAIL=0`**，exit 0（`/tmp/opencode/t002_green.log`）。
- **两次完整回归**（按报告 §9）：
  ```
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test   # 第一次：T001 PASS=27 FAIL=0；T002 PASS=39 FAIL=0；exit 0
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test   # 第二次：同上；去 ANSI 后两次日志 diff 无差异
  ```
  `/tmp/opencode/t002_make_test_r1_{1,2}.log`、`/tmp/opencode/r1_diff.txt`。
  文档定稿后又复跑一次，结果与上面完全一致（`/tmp/opencode/t002_make_test_final.log`）。
- 改了哪些文件：`roles/base/defaults/main.yml`、`roles/base/README.md`、
  `tests/base/test_base_role.sh`、`tests/base/assert_ntp_service.yml`（新增）、
  `docs/harness/state/contracts/T002.md`（§5/§6/§7/§8 + §9/§10）、`state.yaml`、本文件。
  **未改** `tests/skeleton/`、`playbooks/`、`roles/base/tasks/*`；未把 `base` 接入 `site.yml`。
- 提交范围：上述代码/测试/契约/状态 + 此前工作区中 Planner 的 `spec.md`/`roadmap.md` v1.2
  与 Evaluator 的 `reports/T002-r1.md`（一并纳入以保证状态可审计；Generator 未改其内容）。
- 遗留项：**D5**（`make smoke` 仍 0 task）属 T001 已验收门禁，本轮按要求不修，留待后续任务；
  报告 §7 的 NTP tag 拆分、fstab 行首空白正则等非阻塞改进项未做。
- 下一步：`eval T002 (r2)`（Evaluator 独立复现；`eval_round` 由 Evaluator 置 2）。

---

## [2026-10-19] Evaluator · T002 评估第 1 轮 → FAIL（eval）

- 时间：2026-10-19
- 角色：Evaluator（harness-evaluator 子会话，独立复现；未改任何代码/测试/契约）
- 当前任务：`T002`（被测提交 `fd9d4ec`）
- 结论：**FAIL**（报告 `reports/T002-r1.md`）；A1–A10 全部 PASS，但可配置与可移植 3/5（<4）触发 FAIL
- 复现：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` 连跑两次均 exit 0、T001 `PASS=27`、T002 `PASS=31`、`FAIL=0`，两次日志（去色）完全一致；独立沙箱验证内容/权限/幂等，第二次 `changed=0`；宿主 `/etc/{sysctl.d,modules-load.d}/99-kubernetes.conf`、`/etc/hosts`、`/etc/fstab` 均未被污染。
- 牙齿实验（临时 worktree，已删除）：删除 role → `PASS=4 FAIL=24`；删除 fstab replace → A4 FAIL；`ip_forward=0` → A3 FAIL；`changed_when: true` → A6 FAIL；`unshare -rm` 私有 namespace 中破坏前缀 → A10 FAIL「宿主真实系统路径被污染！」。**E4 未被捕获**：删除 hosts 条目渲染循环后仍 `PASS=31`，暴露 A5 只断言受管块标记、不断言条目内容。
- 阻塞缺陷（D1，MAJOR）：`roles/base/defaults/main.yml:46` 默认 `base_ntp_service: chronyd`，Debian/Ubuntu 的 chrony 包实际是 `chrony.service`；`tasks/system.yml:50-58` 未按 os_family 分支。Debian 12 filelist 实测只有 `chrony.service`/`chrony-wait.service`；错误服务名 check 探针 exit 2。README/meta 宣称支持 Debian/Ubuntu，默认配置会失败。
- 其余：D2 A5 测试缺口（MINOR）；D3 A10 只查 sysctl（MINOR）；D4 文档「无 systemd」与实测 PID1=systemd 不符（MINOR，需 Planner 更正）；D5 `make smoke` 仍 0 task（T001 N1 遗留，NIT）；D6 README「仅落盘」示例在未接入 playbook 时无效（NIT）。
- 设计取舍：`base_root_prefix` 沙箱接缝、不用 notify/handler、role 不接入 playbooks 均判定合理（后者代价是 smoke 仍为空转，建议后续独立 smoke playbook）。
- 改了哪些文件：`docs/harness/state/reports/T002-r1.md`（新增）、`state.yaml`、本文件；`roadmap.md` 保持 T002 `in-progress`（FAIL 不勾选）。
- 下一步：`build T002 (fix r1)` —— 修 D1、补 D2 断言、建议增强 D3/D4，重跑 `make test` 两次后交 r2。

---

## [2026-10-19] Planner · 规格维护 v1.1（plan）

- 时间：2026-10-19
- 角色：Planner（主会话，只写规格，未改任何代码/测试/契约/报告）
- 当前任务：`T002`（保持 `in-progress` + `ready_for_eval`，**未回退进度**）
- 本次做了什么（归档两笔欠账 + 固化环境事实）：
  1. **spec C10 / A1**：静态门禁由 `ansible-lint 0 error` **正式改为** `ansible-playbook --syntax-check` + `yamllint`
     （本环境 `ansible-lint` 不可获取；注明「若可安装须恢复为硬门禁」）。
  2. **spec 新增 C13「验收可执行性」**：验收不可执行时必须在契约标注「受限」并给真机复验步骤；
     评估报告不得把「接线断言/干跑」表述为「已验证生效」。
  3. **spec R1 细化**为已勘明事实：无 systemd（PID1）、容器镜像不可获取（dockerd 可起、registry 不通）、
     molecule/testinfra/ansible-lint 均装不上；并写明缓解=可重定向落盘面 + 幂等复跑 + 受限声明。
  4. **roadmap v1.1**：T002「测试方式」改为**沙箱前缀真实执行 + `--list-tasks` 接线 + `--check` 干跑**（验收摘要不变）；
     新增「验证环境」备注，规定后续 T005/T006/T008/T014/T015/T016 的同类降级规则。
  5. `state.yaml`：新增冻结项 `defaults.verification_policy`、`defaults.static_gate`。
- 未做的事（有意）：**没有**把 `phase` 改回 `BUILDING`、**没有**把 `active_task` 指向 T001 ——
  T001 已 done、T002 已实现待评估，回退会丢失真实进度；`next_action` 保持 `eval T002`。
- 改了哪些文件：`spec.md`、`roadmap.md`、`state.yaml`、本文件。**未改** README / standards / 代码。
- 待办（需要用户或有权限的角色处理，Planner 无权改）：
  - `repo-conventions.md` §8 末条「docker 可用（29.9.1）」**已过时**（daemon 默认未运行、镜像拉不到），建议改为「docker CLI 存在；daemon 需手动启动且 registry 不可达」。
  - README「一个任务的生命周期」第 3 步仍写 `ansible-lint`，与 spec C10 新口径不一致（README 属需求原文，建议仅加注）。
- 下一步：`eval T002`（`/h-eval`）。

---

## [2026-10-19] Generator · T002 实现完成（build）→ ready_for_eval

- 时间：2026-10-19
- 角色：Generator（harness-generator 会话）
- 当前任务：`T002`（主机准备 role `base`）
- 本次做了什么：
  1. 写契约 `contracts/T002.md`（A1–A10 可判定验收项 + **受限声明**）。
  2. **TDD**：先写 `tests/base/test_base_role.sh` + `tests/base/sandbox.yml` → 红灯 `PASS=4 FAIL=23`
     （失败原因确认为 `the role 'base' was not found`）。
  3. 实现 `roles/base`：`defaults`/`tasks/{main,files,system}`/`handlers`/`templates/*.j2`/`meta`/`README.md`。
  4. 绿灯：`make test` → T001 `PASS=27`、T002 `PASS=31`、`FAIL=0`、exit 0。
- **验证策略变更（需 Planner 归档，见下）**：roadmap 原写「molecule(docker driver) + testinfra」，
  但本环境 `molecule`/`testinfra` 装不上、dockerd 虽可手动启动却**拉不到镜像**（Docker Hub DNS 抖动 + 下载中断）、
  且**无 systemd**，主机级效果无法真实验证。经用户确认（选项 A），改为：
  **沙箱前缀 `base_root_prefix` + 真实执行文件类任务**（真实渲染 / 落盘 / 权限 / 幂等复跑）
  + `--list-tasks --tags base:system` 接线断言 + `--check --diff` 干跑。
- 怎么验证：
  ```
  make test                                                      # T001 PASS=27 + T002 PASS=31, exit 0
  tests/base/test_base_role.sh                                   # 单跑 T002 套件
  ```
- 测试/幂等结果：`make test` 连跑两次均 exit 0、`PASS=27/31 FAIL=0`；
  T002 用例内**第二次执行 `changed=0`**（真实幂等）；宿主 `/etc/sysctl.d/99-kubernetes.conf` 前后状态一致（沙箱隔离）。
- 关键设计决策：
  - 落盘路径全部由 `base_root_prefix` 派生（默认空 = 真实系统路径），故可整体重定向到沙箱做真实验证。
  - **不使用 notify/handler**：曾出现 handler 未被 `--skip-tags` 过滤、在控制机跑 `sysctl --system` 而失败的问题；
    改为 `tasks/system.yml` 中的幂等命令任务（`sysctl --system` 用 `changed_when: false`，`modprobe` 自身幂等）。
- 遗留问题 / 风险：
  - **受限声明（对应 spec R1）**：模块真实加载、sysctl 真实生效、`swapoff` 真实执行、主机名/时区真实变更、
    chrony 服务启用、firewalld/SELinux 真实状态 —— 本环境**无法真实验证**，仅接线 + 干跑断言，需真机/VM 复验。
  - **角色未接入 playbook**：`playbooks/{control-plane,node}.yml` 仍为占位，**故意不接入**——
    否则 `make smoke`（localhost）会对开发机做主机准备。接入应在 T003/T004 的真实编排中进行。
  - **待 Planner 归档**：① `roadmap.md` T002「测试方式」列仍写 molecule+testinfra；
    ② `spec.md` C10 仍写 `ansible-lint`（T001 遗留）。
  - 环境副作用：探查期手动启动过 `dockerd`（无镜像、可 `sudo pkill dockerd` 回收）。
- 下一步：`eval T002`（交 Evaluator 独立复现与打分）。

---

## [2026-10-16] Evaluator · T001 评估第 2 轮 → PASS（eval）

- 时间：2026-10-16
- 角色：Evaluator（harness-evaluator 子会话，独立复现，未改任何代码/测试/契约）
- 当前任务：`T001`（被测提交 `0e59f8b`，上一轮 `1c33f93` FAIL）
- 结论：**PASS**（报告 `reports/T001-r2.md`）；阻塞项 0，缺陷 1 MINOR + 2 NIT（均非阻塞）
- r1 五条缺陷**全部真实复现确认修复**：
  - D1（BLOCKER）：`ansible-playbook -i inventory/hosts.example playbooks/site.yml` → **exit 0**（原 exit 1）。
  - D3（MAJOR）：`Makefile:42` `test: lint smoke`；牙齿实验 `ANSIBLE_STDOUT_CALLBACK=yaml make test` → **exit 2**，脚本内 `FAIL 真实执行冒烟失败`。
  - D2（MINOR）：临时副本注释 `*.key` → 脚本 `FAIL 未被 .gitignore 忽略: secret.key`、exit 1（行为断言生效）。
  - D4（MINOR）：临时副本破坏 `add-node.yml`（不在 site.yml 内）→ `make syntax` exit 2；`make lint` 逐个校验 5 个 playbook。
  - D5（MINOR）：不显式 `-i` 时 warning 由 3 条降至 2 条，`Could not match supplied host pattern` 消失（回退 `hosts.example` 生效）。
- 打分：功能正确性 5 / 幂等 5 / 可配置 4 / 测试质量 4 / 代码结构 4 / 安全 4；产品完整度 4（加权）。
- 新增非阻塞项：**N1（MINOR）** `smoke` 实际执行 0 个 task（`grep -cE '^TASK \[' = 0`，两个 play 均 `skipping: no hosts matched`）→ 注入模块参数错误后 `make test` 仍 exit 0/PASS=27，但真实执行 exit 2；**T002 起须让冒烟真的落到主机**。N2 `make syntax PLAYBOOKS=` 空 glob 假绿；N3 提交把 Evaluator 的 `reports/T001-r1.md` 一并纳入（可审计性建议）。
- 门禁/幂等：`make lint` 与 `make test` 各连跑两次均 exit 0、`PASS=27 FAIL=0`、输出完全一致；干净环境（`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK`）复现 `PASS=27`。
- 回归/隔离：`spec.md`/`roadmap.md`/`standards/` 自 `90a32de` 未被 Generator 改动；全部破坏性探针在 `git worktree` 临时副本完成，主工作区 `git status --porcelain` 为空、HEAD=`0e59f8b`。
- 改了哪些文件：`docs/harness/state/reports/T001-r2.md`（新增）、`state.yaml`、`roadmap.md`（T001 → done）、本文件。
- 下一步：`build T002`（主机准备 role base）；T002 须落实 N1 的"真实执行"升级与 spec C10 门禁口径归档（Planner）。

---

## [2026-10-16] Generator · T001 修复 r1（响应评估 r1）

- 时间：2026-10-16
- 角色：Generator（harness-generator 会话）
- 当前任务：`T001`
- 本次做了什么（逐条响应 `reports/T001-r1.md`）：
  - **D1（BLOCKER）**：`ansible.cfg` 删除 `stdout_callback = yaml`（`community.general` 已移除该 callback）。
  - **D3（MAJOR，假绿根因）**：新增真实执行冒烟 —— `Makefile` 的 `smoke` 目标 + 测试脚本内检查，`test: lint smoke`。
    牙齿验证：`ANSIBLE_STDOUT_CALLBACK=yaml` 模拟旧配置时冒烟 exit 1。
  - **D2（MINOR）**：`.gitignore` 断言改为行为断言 `git check-ignore -q --no-index <探针>`。
  - **D4（MINOR）**：`make syntax` 遍历 `playbooks/*.yml` 全量校验。
  - **D5（MINOR）**：`ansible.cfg` 的 inventory 增加回退 `inventory/hosts.ini, inventory/hosts.example`。
- 改了哪些文件：`ansible.cfg`、`Makefile`、`tests/skeleton/test_skeleton.sh`、`contracts/T001.md`（§10）、`state.yaml`、本文件。**未改 spec/reports**。
- 怎么验证：
  ```
  make test                                                       # PASS=27 FAIL=0, exit 0
  ansible-playbook -i inventory/hosts.example playbooks/site.yml  # exit 0（原为 exit 1）
  ```
- 测试/幂等结果：`make test` 连续两次 `PASS=27 FAIL=0`；真实运行 exit 0。
- 遗留问题 / 风险：`spec.md` C10 的 `ansible-lint` 口径仍待 Planner 归档（不影响本轮）；`host_key_checking=False`、`deprecation_warnings=False` 为已知权衡（评估 §5 非阻塞）。
- 下一步：`eval T001 (r2)`（交 Evaluator 复查）。

---

## [2026-10-16] Evaluator · T001 评估第 1 轮 → FAIL（eval）

- 时间：2026-10-16
- 角色：Evaluator（harness-evaluator 子会话，独立复现）
- 当前任务：`T001`（被测提交 `1c33f93`）
- 结论：**FAIL**（报告 `reports/T001-r1.md`）
- 复现摘要：A1–A6 静态验收**全部 PASS**（`./tests/skeleton/test_skeleton.sh` PASS=25/FAIL=0；`--syntax-check` exit 0；`yamllint -c .yamllint .` exit 0；`make help` 列出目标；无密钥入库；inventory 三分组齐全）；`make lint`/`make test` 连跑两次均 PASS=25/exit 0。
- **阻塞缺陷 D1（`ansible.cfg:12`）**：`stdout_callback = yaml` 在本环境（ansible-core 2.20.5 / community.general 12.6.0）使**任何真实 `ansible-playbook` 运行 exit 1**（`ERROR: ...community.general.yaml callback plugin has been removed`）。`--syntax-check` 不加载 callback → 门禁假绿（D3）。
- 修复方向：删该行，或改 `callback_result_format = yaml`（本地已验两种均可 exit 0）；并补真实执行 smoke（对 localhost 跑一次占位 playbook）。
- 其余改进项：D2 测试 `.gitignore` 断言为弱子串匹配（注释掉 `*.key` 仍 PASS）；D4 `make syntax` 只查 `site.yml`；D5 默认 inventory 缺失静默降级。
- 改了哪些文件：`docs/harness/state/reports/T001-r1.md`（新增）、`state.yaml`、本文件。
- 下一步：`build T001 (fix r1)`。

---

## [2026-10-16] Generator · T001 实现完成（build）

- 时间：2026-10-16
- 角色：Generator（harness-generator 会话）
- 当前任务：`T001`（项目骨架与工具链）
- 本次做了什么：
  1. 写契约 `contracts/T001.md`（A1–A6 可判定验收项）。
  2. **TDD**：先写 `tests/skeleton/test_skeleton.sh` → 红灯 `PASS=1 FAIL=24`。
  3. 实现骨架：`ansible.cfg`、`.yamllint`、`.gitignore`、`Makefile`、`inventory/hosts.example`、
     `group_vars/{all,k8s_master,k8s_node,etcd}/main.yml`、
     `playbooks/{site,control-plane,node,add-node,upgrade}.yml`、`roles/README.md`。
  4. 绿灯：`make test` → `PASS=25 FAIL=0`；连续两次一致。
- 改了哪些文件：上述骨架 + 契约/状态/roadmap；**未写任何 role 逻辑**。
- 怎么验证：
  ```
  make lint     # yamllint + ansible-playbook --syntax-check
  make test     # lint + tests/skeleton/test_skeleton.sh
  ```
- 测试/幂等结果：红→绿通过；重跑结果一致；本任务无运行时幂等要求。
- 遗留问题 / 风险：
  - **验收口径变更（待 Planner 归档）**：环境无 `ansible-lint`（包源取不到），T001 静态门禁改为
    `--syntax-check` + `yamllint`。已更新 `roadmap.md` T001 与 `acceptance-criteria.md` §5，并新增
    `repo-conventions.md` §8 环境说明；但 `spec.md` C10 仍写 `ansible-lint`，**Generator 无权改 spec**，待 Planner 同步。
  - 环境：`ansible-playbook` 不在 PATH，需 `PYTHONPATH=/home/zhangsan/ansible`；`Makefile` 已自动兜底 `$HOME/ansible`。
- 下一步：`eval T001`（交 Evaluator 独立复现与打分）。

---

## [2026-10-16] Planner · 规划完成（plan）

- 时间：2026-10-16
- 角色：Planner（子会话）
- 当前任务：无（`active_task: T001`，尚未开始实现）
- 本次做了什么：
  1. 读 `AGENTS.md` → `state.yaml` → `roles/planner.md` → 根 `README.md` → `standards/repo-conventions.md` → 现有 `roadmap.md` 草案。
  2. 产出 `docs/harness/state/spec.md`（v1 定稿）：目标 G1–G13、非目标 N1–N7、约束 C1–C12、组件清单、
     关键数据流与三类对外接口、验收总纲 A1–A16、风险 R1–R6、开放问题 Q1–Q3、默认决策 D1–D3、需求→落点对照表。
     → **README 的每条「项目目标」「实现要求」均已逐条覆盖并标注落点任务。**
  3. 复核并细化 `roadmap.md`（取代 draft）：16 个任务 T001–T016，每条含可判定验收摘要 + spec 验收项引用、
     依赖、测试方式、QAgate（全 normal）；补齐依赖图、关键路径、里程碑 M1–M7、已知限制。
  4. 更新 `state.yaml`：`phase: BUILDING`、`active_task: T001`、`next_action: "build T001"`、
     `planned_tasks: 16`、`critical_path`、扩展 `defaults`（含 k8s_min_version/kube_proxy/cilium_mode/
     supported_os/artifact_source/upgrade_policy/harness_scope_note）、`updated`。
- 改了哪些文件：`docs/harness/state/spec.md`、`docs/harness/state/roadmap.md`、
  `docs/harness/state/state.yaml`、`docs/harness/state/handoff.md`。**未改任何代码。**
- 怎么验证：检查 `spec.md` §9「需求→落点对照」覆盖 README 全部条目；检查 `roadmap.md` 每条验收摘要含可判定命令/断言、
  依赖无环且拓扑有序；`state.yaml` 字段与角色卡要求一致。
- 测试/幂等结果：不适用（本任务仅规划，无代码/测试产出）。
- 遗留问题 / 风险：
  - **R1（高）**：真实多节点 VM 环境可能缺失，T005/T006 的 VIP 漂移与 T014/T015 的加节点/升级端到端可能只能用容器近似
    → 必须在契约与评估报告中显式声明局限，不得声称等价于真实 HA。
  - **D1 假设**：环境支持 VRRP（同二层网段）。若为云环境不支持 VRRP，需切 `ha_mode: kube-vip`。
  - **开放问题**：Q1 etcd 备份/恢复是否立项（默认不立项，仅升级前备份）；Q2 是否需要完整 air-gap 离线包（默认仅代理+本地制品目录）；
    Q3 是否需跨多个 minor 连续升级与自动回滚（默认仅相邻 minor + 手工回滚）。
  - **范围说明**：README 的「harness 系统」章节已由 `AGENTS.md` + `docs/harness/` 交付，未纳入本 roadmap；如发现 harness 缺陷应新增独立任务。
- 下一步：`build T001`（项目骨架与工具链）——Generator 先写契约 `state/contracts/T001.md`，**先写会失败的测试再实现**；
  验收：`ansible-lint` 0 error、`--syntax-check` 通过、`make help` 列出 lint/syntax/test、仓库不含密钥类文件。

---

## 历史

- [INIT] 空。会话结束后由当前角色更新。
