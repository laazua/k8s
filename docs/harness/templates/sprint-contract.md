# 任务契约 · {{TASK_ID}}

- 任务标题：{{TITLE}}
- 契约状态：`proposed | agreed | ready_for_eval | accepted | changes_requested`
- 负责人（Generator）：<agent/session>
- 复核（Evaluator）：<agent/session>
- 更新时间：{{DATE}}

## 1. 目标（本任务交付什么）
<一两句；只描述可交付结果，不写实现细节>

## 2. 非目标（明确不做什么）
- <防止范围蔓延>

## 3. 依赖
- 依赖任务：<T00X, ...>
- 前置条件：<inventory/环境/变量>

## 4. 可验证验收项（每条必须可判定）
> 可自动化的写成测试；不可自动化的写成"步骤 + 期望输出"。

| # | 验收项 | 验证方式（命令/测试） | 期望 | 判定 |
| --- | --- | --- | --- | --- |
| A1 |  |  |  | ☐ |
| A2 |  |  |  | ☐ |

## 5. 幂等与例外
- 幂等期望：连跑两次第二次 `changed=0`。
- 声明例外（若有）：<任务 path + 原因>

## 6. 测试计划（TDD：先红后绿）
- 先写的失败测试：<文件/命令 + 预期失败信息>
- 目标命令：`ansible-lint` / `--syntax-check` / `molecule test` / <断言脚本>

## 7. 风险与假设
- <...>

## 8. 双方确认
- Generator：<签名/时间>
- Evaluator：<签名/时间>
