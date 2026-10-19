# 交接摘要（Handoff）

> 仅凭本文件 + `state.yaml` 即可继续工作，无需翻聊天记录。
> 最新条目在最上方。

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
