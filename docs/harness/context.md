# 上下文驱动方式（Context Driving）与 Token 经济

> 需求 2 的核心答案：**如何用上下文驱动 harness**。原则一句话——*把地图读进上下文，把细节留在文件里，按需只读当前那一片。*

## 1. 驱动的三种粒度

### A. 一次性驱动（新手/最快）
直接用一条自然语言驱动语，Agent 依 `AGENTS.md` 自解析：
```text
plan        # 规划
build       # 实现下一个任务
eval        # 评估当前任务
status      # 看进度
```

### B. 命令驱动（推荐，最省 token）
用 OpenCode 命令，把"完整指令"预置在文件里，用户只敲一个词：
```text
/h-plan   /h-build   /h-eval   /h-status
```
命令体本身就规定「读哪些文件、做什么、写哪个产物」，所以每次调用的**输入 token 固定且最小**。

### C. Agent 驱动（角色隔离最强）
切换到角色 agent，其 system prompt 即角色卡，权限也被限定：
```text
（在 OpenCode 中选择 agent）harness-planner / harness-generator / harness-evaluator
```

## 2. 每个阶段"喂进上下文"的确切内容

| 阶段 | 必须加载 | 明确不加载 |
| --- | --- | --- |
| PLANNING | `README.md`、`standards/repo-conventions.md`、角色卡 planner | 任何代码/playbook 全文 |
| BUILDING | `state.yaml`、`roadmap.md` 当前行、`contracts/<task>.md`、角色卡 generator、**当前任务涉及的少量源文件** | 其它任务的契约/报告、完整 `spec.md`（除非契约引用） |
| EVALUATING | `state.yaml`、`contracts/<task>.md`、`handoff.md`、`standards/acceptance-criteria.md`、角色卡 evaluator、**被测物本身** | Generator 的自我评价长文、其它任务历史 |

## 3. 上下文重置（跨会话续做）配方
1. 结束会话前：更新 `state.yaml`（phase/active_task/contract_status/next_action）、`roadmap.md`、`handoff.md`。
2. 新会话开始：只读 `AGENTS.md` → `state.yaml` → 当前角色卡 → 当前任务行 → 契约。通常 **< 6 个文件**。
3. `handoff.md` 的硬要求：任何人只凭它 + `state.yaml` 就能继续，不需要翻聊天记录。

## 4. Token 节约的 8 条军规
1. **地图与手册分离**：`AGENTS.md` 只放地图；细节在 `docs/harness/`。
2. **定位优先**：`grep`/`glob` 找行，再 `read` 局部（带 `offset/limit`），别整篇读。
3. **读状态先于读实现**：永远先 `state.yaml`，它告诉你"现在该读什么"。
4. **命令取代长提示**：把常用长指令沉淀成 `.opencode/commands/h-*.md`。
5. **大输出落地**：运行日志、`ansible-playbook` 输出重定向到文件，只把摘要/失败片段带回对话。
6. **用工具代替阅读**：`ansible-playbook --syntax-check`、`--list-tasks`、`ansible-lint` 比人肉读 playbook 准且省。
7. **契约即聚焦**：一个任务只碰契约列出的文件，天然限制上下文体积。
8. **单任务单会话 + 硬重置**：不把旧任务历史拖进新任务。

## 5. "上下文"是什么（心智模型）
一个 Agent 每步能看到的只有三类东西：
- **静态指引**：`AGENTS.md` + 角色卡 + 判据（相对稳定）；
- **动态状态**：`state/` 里的文件（每次会话初读，贯穿全程）；
- **当前工作面**：本任务要改的文件与要跑的测试（最易变、最占 token）。

harness 的设计就是：**让这三类各自最小化、且互不污染。** 静态指引只在你调用某角色时载入；动态状态被刻意写短；工作面被契约框定。

## 6. 反模式（会导致 token 爆炸或跑偏）
- ❌ 一上来 `read` 整个仓库 / 整篇 `spec.md`。
- ❌ 把评估结论写在聊天里而不写 `reports/`。
- ❌ 多个任务并行改同一批文件。
- ❌ 让 Generator 自己宣布 PASS。
- ❌ 同一个会话里从 T001 一路做到 T016（必然失焦）。
