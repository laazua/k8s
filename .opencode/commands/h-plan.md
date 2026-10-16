---
description: 规划——把 README 需求扩成 spec 与 roadmap
agent: harness-planner
---

以 harness **Planner** 角色执行「plan」。

步骤：
1. 读 `AGENTS.md` → `docs/harness/state/state.yaml` → `docs/harness/roles/planner.md`。
2. 读根 `README.md` 与 `docs/harness/standards/repo-conventions.md`。
3. 产出/更新 `docs/harness/state/spec.md`（产品/架构层，覆盖 README 每条要求）与 `docs/harness/state/roadmap.md`（可判定验收摘要、依赖、测试方式、QAgate）。
4. 更新 `state.yaml`：`phase: BUILDING`、`active_task` 指向第一个任务、`next_action`、`planned_tasks`、`critical_path`、`defaults`、`updated`。
5. 追加摘要到 `docs/harness/state/handoff.md`。

补充要求（可选）：$ARGUMENTS

最后用 5 行内摘要报告：任务数、关键路径、默认假设、下一个任务。
