# 验收硬指标（Acceptance Criteria）

> Evaluator 打分依据。每项 1–5 分，有**硬阈值**；**任一项低于阈值 → 整体 FAIL**。
> 打分必须附证据（命令输出片段或 `文件:行号`）。无证据的分数无效。

## 1. 功能正确性（Functional Correctness）｜阈值 ≥ 4
- 契约中每条验收项是否真实成立（不是"代码看起来写了"）。
- 端到端：相关 role/playbook 在干净环境真实跑通；集群类任务要 `kubectl` 层的证据。
- 反例：函数存在但没被调用；route 顺序导致永远走到 422；handler 没触发。

## 2. 幂等与可重入（Idempotency）｜阈值 = 5（硬性）
- 同一 playbook 连跑两次，第二次 `changed=0`。
- 例外（如探针类、证书过期轮换）必须在契约中显式声明，否则视为 FAIL。
- `--check` 模式不应报意外变更。

## 3. 可配置与可移植（Configurability & Portability）｜阈值 ≥ 4
- 版本/发行版/代理/CIDR 等是否真的变量化（抽查改成另一值能否成立）。
- 无硬编码版本/路径/发行版假设。
- 至少在 2 个 `ansible_os_family` 分支上有明确策略（可含"该分支暂不支持"的显式报错）。

## 4. 测试质量（Test Quality）｜阈值 ≥ 4
- **TDD 证据**：存在先失败后通过的测试；测试断言**行为**而非实现细节。
- 覆盖正常路径 + 至少一个边界/失败路径。
- 测试可从干净环境复现地运行（有明确命令）。
- 反例：只断言"文件存在"却不断言内容/权限；测试自身 flaky。

## 5. 代码与结构质量（Code & Structure）｜阈值 ≥ 4
- 符合 `repo-conventions.md`：role 结构、FQCN、命名、tags、变量分层。
- 静态门禁：`ansible-playbook --syntax-check` 全通过、`yamllint` 无 error（必选）；`ansible-lint` 若环境可用则须 0 error。
- 可读、无重复（抽 common）、无死代码。
- 变更范围聚焦于本任务契约。

## 6. 安全性（Security）｜阈值 ≥ 4
- 无明文密钥/私钥/kubeconfig 进入仓库。
- 破坏性操作有 dry-run/回滚；下载有校验（hash）。
- 安全默认到位（如 apiserver `--anonymous-auth=false`、授权模式合理、文件权限 600）。

## 加权项（不设硬阈值，用于比较）
- **产品完整度（Product Completeness）**：相对 `spec.md` 的覆盖度与深度；对照 README 的每条实现要求。

## 总体判定
```
FAIL  if any(core_criterion < threshold)
PASS  otherwise
```
> 若 PASS 但存在非阻塞改进项：在报告中列出，供后续任务吸收，不阻塞推进。

## 校准示例（few-shot，供 Evaluator 对齐口味）
- 幂等项：某 role 用 `command: systemctl restart containerd` 无 `changed_when` → 第二次仍报 changed → **幂等 = 2，FAIL**。
- 功能项：`PUT /frames/reorder` 路由定义在 `/{frame_id}` 之后，被当作 id 解析返回 422 → **正确性 = 2，FAIL**。
- 测试项：只测 "role 能跑" 无任何断言 → **测试质量 = 2，FAIL**。
- 可配置项：`k8s_version=1.30.0` 硬编码在 task 里 → **可配置 = 2，FAIL**。
