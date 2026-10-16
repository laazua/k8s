---
description: 状态——只读汇报当前进度与下一步
---

只读汇报 harness 状态，**不要修改任何文件、不要执行实现或评估**。

步骤：
1. 读 `AGENTS.md` → `docs/harness/state/state.yaml`。
2. 读 `docs/harness/state/handoff.md`。
3. 如需细节，`grep` 定位 `docs/harness/state/roadmap.md` 中当前任务行（勿通读）。

输出（≤12 行）：
- 阶段 `phase` / 活动任务 `active_task` / 契约状态 `contract_status` / 评估轮数 `eval_round`
- 进度：`done_tasks` / `planned_tasks`
- 最近一次交接要点
- 阻塞项 `blockers`
- **下一步**：`state.yaml.next_action`，并给出对应驱动命令（`/h-plan` `/h-build` `/h-eval`）。

补充要求（可选）：$ARGUMENTS
