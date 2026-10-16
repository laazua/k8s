# 工作流 / 状态机

## 1. 状态机
```
INIT ──plan──▶ PLANNING ──spec+roadmap 就绪──▶ BUILDING ──┐
                                                  ▲        │
                                                  │        ▼
                                         反馈(FAIL)│   EVALUATING
                                                  │        │
                                                  └────────┤
                                                       PASS│
                                                           ▼
                                            还有任务? ──是──▶ BUILDING
                                                │否
                                                ▼
                                              DONE
```

状态字段以 `state/state.yaml.phase` 为准：`INIT | PLANNING | BUILDING | EVALUATING | DONE`。

## 2. 阶段说明与门禁（gate）

### PLANNING（Planner）
- 输入：根 `README.md`、`standards/repo-conventions.md`。
- 输出：`state/spec.md`（产品/架构层规格）、`state/roadmap.md`（任务清单，含验收摘要、依赖、测试方式）。
- 门禁：spec 覆盖 README 全部"实现要求"；每个 roadmap 任务都有可验证的验收摘要与测试方式。
- 转换：写完把 `phase` 置 `BUILDING`，`active_task` 指向第一个未完成任务。

### BUILDING（Generator）——每个任务
1. 读 `state.yaml` → `active_task`；在 `roadmap.md` grep 到该行；读其依赖任务状态。
2. 写/更新 `state/contracts/<task>.md`（用 `templates/sprint-contract.md`）：
   - 交付物、**可验证验收项**（逐条可勾选、可自动或明确手工验证）、测试方式、非目标。
   - `contract_status: proposed` → 若需要，请求 Evaluator 以只读方式复核 → `agreed`。
3. **TDD**：先写测试（molecule/断言脚本），确认红灯；再实现到绿灯。
4. 自测：`ansible-lint`、`--syntax-check`、幂等复跑。
5. 写 `state/handoff.md`（用 `templates/handoff.md`），`state.yaml.contract_status: ready_for_eval`，`phase: EVALUATING`。

### EVALUATING（Evaluator）
1. 读 `state.yaml`、`contracts/<task>.md`、`handoff.md`；**不读** Generator 的辩解理由以外的东西（避免被带偏，独立复现）。
2. 从干净环境复现：跑测试、探边界、查幂等（连跑两次）、查可配置/可移植（改一个版本/发行版变量）。
3. 按 `standards/acceptance-criteria.md` 打分，写 `reports/<task>-rN.md`（用模板）。
4. 结论：
   - `PASS` → 更新 `state.yaml`（`active_task` 推进、`phase: BUILDING`）、在 `roadmap.md` 勾选该任务、追加一行"经验"到 `handoff.md`。
   - `FAIL` → `state.yaml.contract_status: changes_requested`，`phase: BUILDING`，报告中每条缺陷含 `文件:行号` + 复现 + 期望，供 Generator 直接执行。

### 回退规则
- 同一任务连续 2 轮 FAIL：停下，回到 PLANNING 级别处理（拆分任务 / 澄清契约），并在 `handoff.md` 记录原因。禁止第 3 轮盲目重试。

## 3. 任务契约的写法（关键）
契约把"高层 spec"与"可测实现"之间的鸿沟补上。每条验收项必须是**可判定的**：
- 反例（不可判定）："部署要稳"。
- 正例（可判定）："对 3 台 master 跑 `kubeadm-less` 二进制剧本后，`kubectl get nodes` 中 3 个 master 均为 `Ready`；再跑一次该剧本书 `changed=0`（etcd/haproxy 的 ping 探针任务除外，需说明）"。

## 4. 会话与上下文重置
- **一个任务一个会话**（TDD 循环可在同一会话内完成；跨任务必须重置）。
- 重置后新会话的加载顺序见 `AGENTS.md` 第 2 节；`handoff.md` 必须自包含到"仅凭它 + state 就能续做"。
- 若同一会话内被迫塞满（接近上下文上限），立即写 handoff 并重启会话，不要"边摘要边硬撑"。

## 5. 提交约定（git）
- 每个任务一个提交（或一组聚焦提交），信息格式：`<task-id>: <祈使句摘要>`，例：`T008: implement kubelet+containerd role with TDD`。
- 提交内必须包含：代码、测试、契约、handoff 更新、state/roadmap 更新。
- 评估报告 PASS 后可合并；FAIL 的报告随修复提交一起保留历史。
