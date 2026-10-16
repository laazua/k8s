# 仓库约定（Repo Conventions）

> 面向 Planner/Generator/Evaluator 的共享事实。保持简短、稳定。

## 1. 目标与硬约束（来自 README）
- 以**二进制形式**部署 k8s 集群，用 **Ansible**，项目结构用 **Ansible role**。
- **通用部署**：任意 k8s 版本（变量化 `k8s_version` 等）、任意 Linux 发行版（按 `ansible_os_family`/`ansible_distribution` 分支）。
- **CRI = containerd**；**CNI = Cilium**。
- **master 高可用**（≥3 控制面；apiserver 前置 VIP/负载均衡；etcd 集群奇数节点）。
- **工作负载只允许落在 node**（master 打 `NoSchedule` 污点 + 角色标签；业务用 nodeSelector/tolerations）。
- **可加节点**（独立 scale 剧本）与**可升级**（版本升级剧本 + 回滚）。
- **代理支持**：下载二进制/依赖时可设 `http_proxy`/`https_proxy`/`no_proxy`，支持离线缓存。
- **TDD**：先测试后实现。

## 2. 目录约定（建议，Generator 可细化）
```
ansible.cfg
inventory/                 # 示例 inventory（hosts 分组：k8s_master, k8s_node, etcd）
group_vars/all/            # 版本、代理、网络 CIDR、VIP 等全局变量
group_vars/k8s_master/     # 控制面变量
group_vars/k8s_node/       # 工作节点变量
roles/<role_name>/         # 每个子系统一个 role（tasks/handlers/templates/files/defaults/meta）
playbooks/                 # site.yml, control-plane.yml, node.yml, add-node.yml, upgrade.yml
tests/                     # molecule/ 或测试脚本
docs/                      # 含 docs/harness/
```

## 3. 变量与可配置
- 所有版本号、镜像、二进制来源、CIDR、VIP、端口、路径**必须变量化**并有合理默认（放 `defaults/main.yml`）。
- 覆盖优先级：`group_vars` > role `defaults`。禁止在任务里硬编码版本/路径。
- 代理集中定义：`proxy_env: { http_proxy: ..., https_proxy: ..., no_proxy: ... }`，下载任务统一引用。

## 4. Ansible 编码规范
- 使用 FQCN（`ansible.builtin.*`、`ansible.posix.*`）。
- 任务要有 `name`；role 内用 `tags` 便于单跑。
- 优先幂等模块；必须用 `command`/`shell` 时加 `creates`/`removes`/`changed_when`/`register`+`when`。
- handler 用于重启服务；变更敏感文件用 `notify`。
- 断言用 `ansible.builtin.assert`。
- 禁明文密钥：用 `ansible-vault` 或运行时生成；`.gitignore` 排除 `*.key`、`kubeconfig`、`vault-password`。
- `ansible-lint` 必须 0 error（warning 需评估）。

## 5. 测试策略（TDD）
| 层 | 工具（建议） | 用途 |
| --- | --- | --- |
| 语法 | `ansible-playbook --syntax-check` | 快速拦截 |
| 规范 | `ansible-lint` | 规范/反模式 |
| 单元/集成 | **molecule**（`docker`/`libvirt` driver） | 起容器/VM 跑 role 并断言 |
| 主机断言 | **testinfra** / `goss` | 文件、服务、端口、内核参数 |
| 集群断言 | `kubectl` 断言脚本 | `get nodes` Ready、pod 就绪、DNS、跨节点网络 |
| 幂等 | 同剧本连跑两次 | 第二次 `changed=0`（例外须声明） |
| 端到端 | 多节点 VM（molecule/libvirt 或 CI） | HA、加节点、升级 |

> 无真实集群时的最小要求：语法 + lint + molecule（容器内验证 role 逻辑与断言脚本）必须通过。

## 6. 安全
- 证书/密钥由 role 生成（kubeadm-less 的 PKI role）或经 vault 注入；不落明文到 git。
- 危险操作（`reset`、覆盖 etcd、`swapoff`、改内核参数）必须有 dry-run 或回滚说明。
- 默认启用最小权限；apiserver 授权模式、`--anonymous-auth=false` 等安全默认作为验收项。

## 7. 提交与分支
- 分支：`feat/T00N-<slug>`（或直接在 main 上按任务提交，视团队）。
- 提交信息：`<task-id>: <祈使句摘要>`。
- 一个任务一组聚焦提交；含代码+测试+契约+handoff+state 更新。

## 8. 环境说明（本仓库当前验证环境）
- **Ansible**：`/home/zhangsan/ansible`（ansible-core 2.20.5 + ansible 社区包）。调用需 `PYTHONPATH=/home/zhangsan/ansible`，可执行文件在 `/home/zhangsan/ansible/bin`。`Makefile` 已自动探测：优先 `$ANSIBLE_PLAYBOOK` → `PATH` → `$HOME/ansible`。
- **yamllint**：`/home/zhangsan/.local/bin/yamllint`（1.38.0），在用户 PATH 中。
- **ansible-lint**：当前包源与网络**不可获取**（`No matching distribution found`）。故静态门禁由 `ansible-playbook --syntax-check` + `yamllint` 承担；**若日后环境提供 `ansible-lint`，应恢复为硬门禁**。
- **容器/虚拟化**：`docker` 可用（29.9.1）；无 `podman`/libvirt。molecule 的**多节点真实**验证需另行准备环境（对应 `spec.md` 风险 R1）。
