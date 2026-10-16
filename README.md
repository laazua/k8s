# k8s

## 说明
项目目标:
  - 二进制的形式部署k8s集群的脚本
  - 通用部署：
    1. 通过配置可以部署任意版本的k8s集群
    2. 可以在任意发行版本的linux主机上进行部署
  - 后续可通过该项目脚本对集群进行版本升级

实现要求:
  - 用 ansible 部署k8s集群(二进制部署)
  - 项目结构用 ansible role 的形式
  - CRI: containerd
  - CNI: Cilium
  - 集群的master节点采用高可用的方式进行部署
  - 后续所有的应用都只能限制部署在node节点上
  - 后续可以方便往集群中添加新的节点
  - 使用tdd开发模式(测试驱动开发)
  - 部署过程中，如果下载二进制包或者依赖网络不同，可以进行代理设置

harness系统：
  1. 根据上面的项目目标和实现要求给出一套 AI agent 驱动开发的harness系统,要求给出完整的harness系统可以直接使用.
  2. 给出具体如何通过上下文对harness系统进行驱动
  3. 参考官方：https://www.anthropic.com/engineering/harness-design-long-running-apps
  4. harness放置位置docs/harness/
  5. AGENTS.md作为驱动harness的唯一入口(AI Agent项目地图)
  6. 实现的harness系统驱动开发过程中要尽量节约token

---

## harness 使用说明

本仓库用三角色 harness（**Planner → Generator → Evaluator**）驱动开发。
唯一入口是根目录的 `AGENTS.md`（AI Agent 项目地图），细节在 `docs/harness/`。

### 快速开始（3 步）
在**项目根目录**启动 OpenCode 开会话：

1. `/h-plan` —— 规划：读本 README，产出 `docs/harness/state/spec.md` 与 `roadmap.md`；
2. `/h-build` —— 实现：认领下一个任务，**先写测试再实现**（TDD）；
3. `/h-eval` —— 评估：独立 QA 复现验证，给出 `PASS` / `FAIL`。

循环「build → eval →（FAIL 则修复）→ 下一个任务」，随时用 `/h-status` 查看进度。

### 驱动方式
| 命令 | 驱动语 | 说明 |
| --- | --- | --- |
| `/h-plan` | `plan` | 规划 spec 与 roadmap |
| `/h-build` | `build` / `next` | TDD 实现当前任务 |
| `/h-eval` | `eval` | 独立评估当前任务 |
| `/h-status` | `status` / `resume` | 查看进度与下一步 |

不用斜杠命令也可以：直接用自然语言说出驱动语（`plan` / `build` / `eval` / `status`），
Agent 会依 `AGENTS.md` 加载对应角色卡执行。也可直接切换到角色 agent：
`harness-planner` / `harness-generator` / `harness-evaluator`。

### 一个任务的生命周期
1. `state.yaml.active_task` 指向 `T00N`（来自 `roadmap.md`）；
2. Generator 写契约 `state/contracts/T00N.md`（做什么 + 可验证验收项）；
3. **TDD**：先写会失败的测试（红）→ 实现到通过（绿）→ 自测（`ansible-lint`、`--syntax-check`、幂等复跑）；
4. Generator 写 `state/handoff.md`，置 `contract_status: ready_for_eval`；
5. Evaluator 独立复现、按**硬指标**打分，写 `state/reports/T00N-rN.md`；
6. `FAIL` → 按报告修复后复查；`PASS` → 勾选 `roadmap.md`、推进 `state.yaml`，**重置上下文**进入下一个任务。

### 文件位置
- 唯一入口 / 地图：`AGENTS.md`
- harness 文档：`docs/harness/`（`README.md` / `architecture.md` / `workflow.md` / `context.md` / `roles/` / `standards/` / `templates/`）
- 状态（唯一事实来源）：`docs/harness/state/`（`state.yaml` / `roadmap.md` / `spec.md` / `handoff.md` / `contracts/` / `reports/`）
- OpenCode 驱动：`.opencode/commands/h-*.md`、`.opencode/agents/harness-*.md`

> 说明：OpenCode 只从「当前工作目录及其祖先目录」发现 `.opencode/`，
> 因此 `.opencode/` 必须留在项目根目录（从项目根启动会话）才能生效。

### Token 经济
- **一个任务一个会话**；跨会话只靠 `state.yaml` + `handoff.md`；
- 按需加载：`AGENTS.md` → `state.yaml` → 当前角色卡 → 当前任务行（通常 < 6 个文件）；
- 用 `grep` 定位而非通读；大输出写入文件再摘要。
