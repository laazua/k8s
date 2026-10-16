# Harness 架构与设计取舍

## 1. 参考
- Anthropic, *Harness design for long-running application development* — https://www.anthropic.com/engineering/harness-design-long-running-apps
- Anthropic, *Effective harnesses for long-running agents* — https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- Anthropic, *Building effective agents* — 原则：**能用简单方案就别上复杂方案，按需加复杂度**。

## 2. 三个根因 → 三个机制
长周期 Agentic 编码有三类稳定失败模式，本 harness 逐一对应：

1. **上下文失焦 / 上下文焦虑**
   - 现象：任务越做越长，模型开始"提前收尾"或前后不一致。
   - 机制：**上下文重置（context reset）**。每个任务用干净会话，靠 `handoff.md` 传递状态。区别于 compaction（原地摘要、保留同一 Agent）——重置给模型"干净的白板"，代价是交接工件必须自包含。

2. **自评偏乐观**
   - 现象：Agent 给自己的产出打分偏高，哪怕质量平庸。
   - 机制：**Generator/Evaluator 隔离**。评审者独立、被调成"挑剔"的。调一个独立评审者比让作者自我批判容易得多。

3. **"完成"定义漂移**
   - 现象：越到后期越偏，交付物与真实需求脱节。
   - 机制：**任务契约（sprint contract）**。动手前把"做什么 + 怎么验证"写成可测条目，双方确认。

## 3. 角色职责边界（强隔离）
| 角色 | 可写 | 不可写 |
| --- | --- | --- |
| Planner | `state/spec.md`、`state/roadmap.md` | 代码、测试、评估报告 |
| Generator | 代码、测试、`contracts/*.md`（提案）、`handoff.md`、`state.yaml` 的构建类字段 | `spec.md`、`roadmap.md` 的验收定义、`reports/*` |
| Evaluator | `reports/*.md`、`state.yaml` 的评估类字段 | 代码、测试、契约的验收项 |

> 隔离是**结构性**的：不是靠提示词礼貌请求，而是靠"谁能写哪个文件"的硬规则（见各角色卡的权限段）。

## 4. 为什么是"文件通信 + 单向流转"
- Agent 之间通过文件通信：一个写、另一个读并回写，链式交接。文件是**可审计、可重放、可 diff** 的，天然契合 git。
- 单向流转（spec → contract → code → report → state）避免多 Agent 同时改同一处导致的发散。
- `state/` 是唯一事实来源：任何"现在到哪了"的问题只答这里。

## 5. 针对本项目的专门约束（写进判据）
本项目不是通用 Web App，而是基础设施编排，故 harness 额外强调：
- **幂等**是一等公民（基础设施可重入），是评估硬阈值。
- **可移植/可配置**：任意 k8s 版本、任意 Linux 发行版、可代理下载 → 评估要覆盖"改配置能否成立"。
- **测试即安全网**：Ansible 的测试用 molecule / testinfra / 断言脚本，不靠"看起来对"。
- **危险操作**：涉及证书、etcd、master 的变更要有回滚与 dry-run。

## 6. 简化原则（何时砍掉组件）
每个组件都编码了"假设模型做不到某件事"。随模型变强，假设会过时。本项目约定：
- 一个任务的**评估循环不超过 2 轮**未过 → 说明契约不清或任务过大，回退到 Planner 拆分/澄清，而不是无限重试。
- 若某类任务在 Generator 单跑下已稳定达标（评估几乎总能 PASS），可在 `roadmap.md` 里把该类任务标 `QAgate: light`，跳过逐任务评估，留到阶段末统一评估。

## 7. 与 OpenCode 的映射
- `AGENTS.md`：自动加载的唯一入口/地图。
- `.opencode/agents/harness-*.md`：三个角色 agent（薄封装，system prompt 指向 `docs/harness/roles/*`）。
- `.opencode/commands/h-*.md`：驱动命令，让「驱动 = 一句话」。
- `docs/harness/state/`：跨会话状态，随 git 持久化。

这样既满足「harness 放 `docs/harness/`」「`AGENTS.md` 是唯一入口」，又让它在 OpenCode 里开箱即用；即便换到别的 Agent 工具，`docs/harness/` 也是自包含可用的。
