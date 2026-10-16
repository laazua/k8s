---
description: 评估——独立验证当前任务并打分
agent: harness-evaluator
---

以 harness **Evaluator**（独立 QA）角色执行「eval」。你**不得修改代码/测试/契约**。

步骤：
1. 读 `AGENTS.md` → `docs/harness/state/state.yaml` → `docs/harness/roles/evaluator.md`。
2. 读 `contracts/<task-id>.md`、`handoff.md`、`docs/harness/standards/acceptance-criteria.md`，以及被测物本身。
3. 独立复现：跑契约测试、**幂等连跑两次**、探边界/负例、抽查可配置与可移植、跑既有回归。
4. 按六项硬指标打分（附证据）；写 `docs/harness/state/reports/<task-id>-rN.md`，给出显式 PASS/FAIL。
5. 更新 `state.yaml`：PASS 则推进 `active_task`、`contract_status: accepted`、`phase: BUILDING`，并在 `roadmap.md` 勾选；FAIL 则 `contract_status: changes_requested`、`next_action: build <id> (fix rN)`。

默认怀疑，不放过真问题；每条缺陷给 `文件:行号` + 复现 + 期望/实际。

补充要求（可选）：$ARGUMENTS

最后用 5 行内摘要报告：结论、缺陷数、阻塞项、给 Generator 的下一步。
