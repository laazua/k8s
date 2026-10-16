# AGENTS.md — k8s 二进制部署项目 · AI 开发地图（唯一入口）

> 这是 AI Agent 进入本仓库的**唯一入口**。任何会话都从本文件开始。
> **不要通读全仓库。** 按下面「按需加载」只读当前角色 + 当前任务需要的文件。这是 token 预算的第一原则。

---

## 0. 项目一句话
用 Ansible 以**二进制方式**、**通用可配置**地部署高可用 Kubernetes 集群：CRI=containerd，CNI=Cilium，master 高可用，业务只调度到 node，可加节点、可升级，支持下载代理，采用 **TDD**。

## 1. 你要做什么（harness 驱动）
本仓库用三角色 harness 驱动开发：**Planner → Generator → Evaluator**。你不发明流程，只按用户的驱动语执行：

| 驱动语 | 你要做的 | 对应命令 |
| --- | --- | --- |
| `plan` | 读根 `README.md` → 产出/更新 `spec.md` + `roadmap.md` | `/h-plan` |
| `build` / `next` | 认领 roadmap 下一个任务，先写测试再实现 | `/h-build` |
| `eval` | 以挑剔 QA 身份独立验证当前任务 | `/h-eval` |
| `status` | 汇报进度与下一步（只读 state） | `/h-status` |
| `resume` | 从 state 恢复，继续未完成工作 | `/h-status`（看 next_action）|

> 也支持自定义 agent：`harness-planner` / `harness-generator` / `harness-evaluator`（见 `.opencode/agents/`）。

## 2. 每次会话的加载顺序（严格）
按序读取，读到足够就开始干活，**不要多读**：

1. 本文件 `AGENTS.md`
2. `docs/harness/state/state.yaml` —— 当前阶段 / 活动任务 / 下一步
3. 当前角色卡：`docs/harness/roles/{planner|generator|evaluator}.md`
4. `docs/harness/state/roadmap.md` 中**当前任务那一行**（用 grep 定位，别整篇读）
5. 若处于 build/eval：`docs/harness/state/contracts/<task-id>.md`

其余文档**仅在文中明确指到时**再读。

## 3. 文件地图（按需加载）
```
AGENTS.md                         # 本文件：唯一入口 / 地图
README.md                         # 需求原文（planner 读）

docs/harness/
  README.md                       # harness 总览 + 如何驱动（人类可读）
  architecture.md                 # 三角色架构与设计取舍（含官方参考）
  workflow.md                     # 状态机 / 阶段 / 门禁 / 转换
  context.md                      # 上下文驱动方式 + token 经济规则
  roles/planner.md                # 角色卡
  roles/generator.md
  roles/evaluator.md
  standards/repo-conventions.md   # 仓库约定（ansible/TDD/测试策略/安全）
  standards/acceptance-criteria.md# 评估硬指标（evaluator 打分依据）
  templates/sprint-contract.md    # 任务契约模板
  templates/evaluation-report.md  # 评估报告模板
  templates/handoff.md            # 交接工件模板
  state/                          # ★ 唯一事实来源（single source of truth）
    state.yaml                    #   机器可读状态（先读它）
    roadmap.md                    #   任务清单与状态
    spec.md                       #   产品/架构规格（planner 产出）
    handoff.md                    #   最近一次交接摘要（跨会话/重置）
    contracts/<task-id>.md        #   任务契约
    reports/<task-id>-rN.md       #   评估报告

.opencode/
  agents/harness-*.md             # OpenCode 角色 agent（薄封装，指向 docs/harness）
  commands/h-*.md                 # 驱动命令 /h-plan /h-build /h-eval /h-status
```

## 4. 铁律（违反即视为任务失败）
1. **Token 第一**：只读需要的文件；用 `grep`/`glob` 定位而不是通读；大输出写进文件再摘要。
2. **TDD 强制**：先写会失败的测试，再写实现；没有测试的任务不允许标记完成。
3. **单一事实来源**：一切状态写在 `docs/harness/state/`，不写在对话里。会话结束前必须更新 `state.yaml` + `roadmap.md` + `handoff.md`。
4. **角色隔离**：Generator 不给自己打分；Evaluator 不改代码；只有 Planner 写 spec/roadmap。
5. **任务单点推进**：一次只做一个任务（`state.yaml.active_task`），做完通过评估再做下一个。
6. **可复现**：任何验证必须能从干净环境重跑（幂等）。
7. **安全**：不提交密钥/私钥/kubeconfig；证书由 role 生成。

## 5. 当前状态（由 harness 维护，勿手改尾部指针）
> 权威内容在 `docs/harness/state/state.yaml`。此处仅作快速跳转：
> 阶段 → 见 state.yaml `phase`；活动任务 → 见 `active_task`；下一步 → 见 `next_action`。

## 注意事项
- 在回复前加上: [主人]
- 所有的回复都要用中文
