# Harness 系统 · 总览与驱动手册

> 本目录是 **AI Agent 驱动开发的 harness 系统**。本文件面向人类与新手 Agent，解释「它是什么、怎么用」。日常驱动请从根 `AGENTS.md` 进入。

## 1. 这是什么
一套把「用 Ansible 二进制部署高可用 k8s 集群（TDD）」这类**长周期、可验证**的工程任务，交给 AI Agent 稳定完成的**多角色循环框架**。灵感来自 Anthropic 的 *harness design for long-running application development*：用 **Generator/Evaluator 对抗循环**提升质量，用**结构化交接工件**跨会话传递状态，用**契约**把「完成」的可验证定义提前敲定。

三个角色：

```
        ┌────────────┐    spec.md + roadmap.md
        │  Planner   │───────────────────────────┐
        └────────────┘                            ▼
                                            ┌───────────┐
              contract 协商                  │  State    │  ← 唯一事实来源
        ┌───────────────────────────────────▶│  Store    │
        │                                    └───────────┘
        ▼                                          ▲
   ┌────────────┐   handoff + 自测通过         │
   │ Generator  │──────────────────────────────┘
   └────────────┘            │
        ▲                    ▼  交给 QA
        │            ┌────────────┐
        └── 反馈 ────│ Evaluator  │──► reports/<task>-rN.md（PASS/FAIL）
                     └────────────┘
```

- **Planner**：把 1 句话需求扩成完整 spec + 任务清单（只到产品/架构层，不写实现细节，避免错误级联）。
- **Generator**：一次一个任务，**先测试后实现**（TDD），自测后交出 `handoff`。
- **Evaluator**：独立、挑剔地复现与验证，按硬指标打分，输出可执行的缺陷清单（含 `文件:行号` 与复现步骤）。

## 2. 为什么这样设计（对应三个失败的根因）
| 问题 | 对策 |
| --- | --- |
| 长任务上下文塞满后失焦 / "上下文焦虑" | **上下文重置**：每个任务一个干净上下文，用 `handoff.md` 交接（不是 compaction 原地摘要） |
| Agent 自评永远说好话 | **角色隔离**：Evaluator 独立打分，硬阈值，任一不达标即 FAIL |
| 目标和"完成"定义模糊，越做越偏 | **任务契约**：动手前先约定做什么 + 怎么验证，双方签字 |

## 3. 目录结构
见根 `AGENTS.md` 的「文件地图」。核心：`state/` 是唯一事实来源；`roles/` 是角色卡；`standards/` 是判据；`templates/` 是产物格式。

## 4. 怎么驱动（3 步上手）
在 OpenCode 中，从项目根开会话，第一次先规划：

```text
/h-plan
```

然后循环「实现 → 评估 → 修复 → 下一任务」：

```text
/h-build      # 认领并实现下一个任务（先写测试）
/h-eval       # 独立评估当前任务，产出 PASS/FAIL
/h-build      # 若 FAIL：按反馈修复
/h-status     # 随时查看进度与下一步
```

不用命令也可以，直接用自然语言驱动语：`plan` / `build` / `eval` / `status` / `resume`。Agent 会依 `AGENTS.md` 加载对应角色卡执行。

## 5. 一个任务的完整生命周期
1. `state.yaml.active_task` 指向 `T00N`（来自 `roadmap.md`）。
2. Generator 写 `contracts/T00N.md`（做什么 + 可验证的验收项），可邀请 Evaluator 复核。
3. Generator **先写测试**（molecule / ansible-test / 断言脚本），跑出红灯，再实现到绿灯。
4. Generator 自测 + 写 `handoff.md`，把 `contract_status` 置 `ready_for_eval`。
5. Evaluator 从干净环境复现、跑测试、探边界、查幂等与可移植性，写 `reports/T00N-rN.md`。
6. FAIL → Generator 按报告修复，`rN+1` 复查；PASS → 更新 `roadmap.md` 勾选、`state.yaml` 推进到下一任务。
7. **重置上下文**，从 `state.yaml` + `handoff.md` 开始下一个任务。

## 6. 快照判定（Definition of Done，全局）
一个任务 PASS 必须同时满足（详见 `standards/acceptance-criteria.md`）：
- `ansible-lint` / 语法检查通过；playbook 语法 `--syntax-check` 通过；
- 新写的测试真实覆盖该任务的行为，且从干净环境可复现地通过；
- **幂等**：同一 playbook 连跑两次第二次 `changed=0`（或差异可解释）；
- 满足该任务 `contract.md` 里的每一条可验证验收项；
- 未破坏既有任务（回归测试全绿）。

## 7. Token 经济（关键约束）
- `AGENTS.md` 是地图，**不是手册**；细节都在 `docs/harness/` 里按需加载。
- 每个任务尽量一个**干净会话**；跨会话只靠 `state.yaml` + `handoff.md`（两者都被刻意写得很短）。
- 用 `grep`/`glob` 定位，用 `--syntax-check`/`--list-tasks` 代替通读 playbook。
- 大日志写文件，只把摘要带回对话。
