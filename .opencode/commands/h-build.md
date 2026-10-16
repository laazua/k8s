---
description: 实现——认领下一个任务并 TDD 实现
agent: harness-generator
---

以 harness **Generator** 角色执行「build」。

步骤：
1. 读 `AGENTS.md` → `docs/harness/state/state.yaml` → `docs/harness/roles/generator.md`。
2. 认领 `active_task`；`grep` 定位 `docs/harness/state/roadmap.md` 中该行；读/建 `docs/harness/state/contracts/<task-id>.md`。
3. 遵守 TDD：先写会失败的测试（红）→ 最小实现到通过（绿）→ 自测（`ansible-lint`、`--syntax-check`、幂等复跑）。
4. 写 `docs/harness/state/handoff.md`；更新 `state.yaml`（`contract_status: ready_for_eval`、`phase: EVALUATING`）与 roadmap（保持 in-progress，勿自行勾选完成）。
5. 不要给自己判 PASS。

只做当前这一个任务。若契约不清或任务过大，记 `NEEDS_REPLAN` 并停止。

补充要求（可选）：$ARGUMENTS

最后用 5 行内摘要报告：做了什么、测试结果、幂等结果、遗留项、是否 ready_for_eval。
