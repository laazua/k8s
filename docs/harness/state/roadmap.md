# 任务清单（Roadmap）· k8s 二进制 Ansible 部署

> 状态：**已复核定稿（v1.2，Planner，2026-10-19）**，取代 v1.1。上游：`spec.md`（G1–G13 / A1–A16 / C1–C13 / D1–D3）。
> v1.2 变更：按评估报告 `T002-r1` 的 D4 更正「验证环境」事实（PID1=systemd、免密 sudo 可用、registry 不可达）。
> v1.1 变更：① T002「测试方式」由 molecule+testinfra 改为**沙箱前缀真实执行 + 接线/干跑断言**（验收摘要不变，受限项见契约）；
> ② 新增「验证环境」说明——容器/VM 类测试方式在当前环境不可执行，须按 R1 降级并显式声明。
> 每行格式：`ID | 状态 | 标题 | 交付物 | 验收摘要（可判定） | 依赖 | 测试方式 | QAgate`
> 状态：`todo | in-progress | done | blocked`。QAgate：`normal`（逐任务独立评估）| `light`（阶段末统一评估）。
> **TDD 硬门禁**：任何任务在契约中必须先有会失败的测试；无测试不得置 `ready_for_eval`。
> 相关 spec 验收项在验收摘要中以 `[An]` 标注。

## 任务表

| ID | 状态 | 标题 | 交付物 | 验收摘要（可判定） | 依赖 | 测试方式 | QAgate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T001 | done | 项目骨架与工具链 | `ansible.cfg`、`inventory/` 示例（k8s_master/etcd/k8s_node 分组）、`group_vars/`、`roles/` 空壳与命名约定、`playbooks/` 入口占位、`Makefile`（lint/syntax/test）、`.gitignore`（密钥/kubeconfig） | `--syntax-check` 全通过、`yamllint` 无 error、`make help` 列出 lint/syntax/test 目标、`git status` 不含任何密钥类文件 [A1]（`ansible-lint` 环境不可得，见 `repo-conventions.md` §8） | — | 静态：lint + syntax | normal |
| T002 | done | 主机准备 role（base） | `roles/base`（内核模块/sysctl/swapoff/时区-chrony/hosts/hostname/防火墙策略，按 os_family 分支，支持 RedHat+Debian） | 断言：swap off、目标内核模块已加载、关键 sysctl 值生效、NTP 同步、主机名与 hosts 正确；**同一 playbook 连跑两次第二次 `changed=0`**（例外需在契约声明）[A2]。**系统级项为本环境受限项**（须真机复验，契约 §5 已声明） | T001 | 沙箱前缀真实执行（内容/权限/**幂等复跑 `changed=0`**）+ `--list-tasks` 接线断言 + `--check` 干跑；不依赖容器/网络 | normal |
| T003 | done | 下载与代理 role | `roles/download`（URL+sha256 校验、代理环境变量、本地缓存/制品目录、已存在跳过） | 给定 url+sha256 能下载并校验成功；sha256 不符时任务**失败**；已存在则跳过（不改动）；设 `http_proxy` 时请求经代理（可用本地 mock 代理断言）；重复执行 `changed=0` [A3, C6] | T001 | 本地 HTTP mock + 断言脚本 + 幂等复跑 | normal |
| T004 | done | PKI / 证书 role | `roles/pki`（自建 CA、apiserver/kubelet/etcd/front-proxy/SA/admin 证书） | 每个证书 `openssl x509 -text` 的 SAN 覆盖 VIP 与全部 master/节点名；私钥权限 600；**重跑不覆盖仍有效的既有证书**（内容哈希不变）[A4] | T003 | 断言脚本（openssl 校验 SAN/有效期/权限）+ 幂等复跑 | normal |
| T005 | done | etcd 集群 role | `roles/etcd`（二进制 + systemd，奇数成员） | 3 成员 etcd `endpoint health` 全部 healthy、`member list` 为 3；重启任一成员后集群恢复 healthy [A5] | T004 | 集群断言脚本 + 重启演练 | normal |
| T006 | todo | 控制面高可用 role（LB + VIP） | `roles/haproxy`、`roles/keepalived`（`ha_mode=kube-vip` 可切换） | VIP 可达且 `curl -k https://<VIP>:6443/healthz` 返回 ok；停掉持有 VIP 的 master 后 VIP 漂移到另一 master 且仍返回 ok [A6, D1] | T002, T003 | 集群断言 + 故障注入（停/起节点） | normal |
| T007 | todo | 控制平面组件 role | `roles/kube-apiserver`、`roles/kube-controller-manager`、`roles/kube-scheduler` | 三组件 systemd active+enabled；`kubectl get --raw /healthz` 与 `/readyz` 为 ok；apiserver 安全默认生效（`--anonymous-auth=false`、RBAC 授权）[A7, C11] | T004, T005, T006 | 集群断言 + 配置文件/进程参数断言 | normal |
| T008 | todo | 运行时与节点组件 role | `roles/containerd`、`roles/kubelet`（+runc、CNI plugins、cgroup driver=systemd） | containerd、kubelet systemd active；`crictl info` 返回正常且 CRI 端点可连通；kubelet 启动后节点出现在 `kubectl get nodes`（可能 NotReady，CNI 未就绪）[A8] | T002, T003, T004 | molecule（容器内验证配置）+ 集群断言 | normal |
| T009 | todo | kube-proxy role | `roles/kube-proxy`（DaemonSet 或二进制二选一，契约内声明） | kube-proxy 在全部 node 运行；创建 Service 后 ClusterIP 可访问 [A9] | T008 | 集群断言（起临时 Pod 访问 ClusterIP） | normal |
| T010 | todo | Cilium CNI role | `roles/cilium`（helm/manifest + 变量化版本与参数，默认 VXLAN、保留 kube-proxy） | `cilium status` healthy；**跨节点**两个 Pod 互相 ping/HTTP 成功（容器内 netns）；`kubectl get nodes` 全部 Ready [A10, D2] | T009 | 集群断言 + 跨节点连通性测试 | normal |
| T011 | todo | kubeconfig / RBAC / 核心附加组件 role | `roles/cluster-addons`（admin&kubelet kubeconfig、CoreDNS、必要 RBAC） | admin kubeconfig 可用于本机 `kubectl`；CoreDNS 全部 Pod Running；集群内 DNS 解析（起 tmp Pod `nslookup kubernetes.default`）成功 [A11] | T010 | 集群断言 + DNS 解析测试 | normal |
| T012 | todo | 集群验证与冒烟测试套件 | `tests/e2e/` 冒烟脚本 + 使用说明 | 一条命令完成：全部节点 Ready、全部系统 Pod Running、集群内 DNS 解析成功、跨节点 Pod 互通，输出明确的 PASS/FAIL 汇总 [A12] | T011 | 端到端冒烟脚本（可重复执行） | normal |
| T013 | todo | 调度约束：业务仅落 node | `roles/taints`（或并入 base 的独立 tag）+ 示例工作负载 | 控制面节点带 `NoSchedule` 污点与角色标签；一个**不带 toleration** 的示例工作负载多个副本全部调度到 node（0 副本落在 master）[A13, G8] | T012 | 集群断言（`kubectl get pods -o wide` 校验节点分布） | normal |
| T014 | todo | 加节点流程 | `playbooks/add-node.yml` + 文档 | 对一个未初始化的新 node 执行剧本后该节点 Ready 且系统 Pod 正常；**重复执行 `changed=0`**；既有控制面/节点无重启无配置变更 [A14, G9] | T012（T008 的 node 路径复用） | 端到端（新增 VM/容器作为 node） | normal |
| T015 | todo | 版本升级与回滚 | `playbooks/upgrade.yml` + 回滚说明 | 将集群升级一个 minor 版本（升级前自动备份 etcd/证书）：升级后全部节点 Ready 且版本号已变更；按文档执行回滚后回到原版本且集群仍 Ready [A15, G10, D3] | T014 | 端到端（升级 + 回滚实跑，各一次） | normal |
| T016 | todo | 端到端验收与使用文档 | `tests/e2e/` 全流程脚本、`docs/` 使用手册（inventory 填写、变量说明、代理/离线、加节点、升级、回滚、已知限制） | 从干净 inventory 按 README 快速开始流程可一条命令得到可用 HA 集群；文档覆盖全部可配置项与已知限制；**T013/T014/T015 的验收在同一轮全流程中全部复现通过** [A16] | T013, T015 | 端到端全流程（干净环境重跑） | normal |

> 注：T013 与 T014 **可并行**（互不依赖）；T016 依赖二者完成，故为主线的终点。

## 依赖与并行

```
T001 ─┬─ T002 ─┐
      └─ T003 ─┴─ T004 ─┬─ T005 ─┐
                        │         ├─ T007 ──┐
              T002 ─────┴─ T006 ──┘         │
                        └─ T008 ─── T009 ───┴─ T010 ── T011 ── T012 ─┬─ T013 ─┐
                                                                     └─ T014 ─┴─ T015 ── T016
```

- 起点即可并行：**T002 与 T003**（均只依赖 T001）。
- T005 与 T008 在 T004 后可并行（etcd vs 运行时，互不依赖）。
- T006 只依赖 T002/T003，可与 T005 并行，但必须在 T007 之前完成。
- T013 / T014 在 T012 后并行。
- 无环（已按拓扑序排列）。

## 关键路径

`T001 → T002 → T003 → T004 → T006 → T007 → T008 → T009 → T010 → T011 → T012 → T014 → T015 → T016`

（T005 与 T006 并行，取较长的 T006 分支；T013 为旁路，由 T016 收敛。）

## 里程碑

| 里程碑 | 达成条件 | 任务 |
| --- | --- | --- |
| M1 骨架可用 | lint/syntax 通过、目录与变量约定固定 | T001 |
| M2 基础能力就绪 | 主机准备、制品分发、PKI 三件套可独立验证 | T002–T004 |
| M3 控制面 HA 就绪 | etcd 集群 + VIP 漂移 + 三组件可跑 | T005–T007 |
| M4 单节点可加入集群 | 运行时/kubelet/kube-proxy 就绪 | T008–T009 |
| M5 集群可用（Ready） | CNI 通、DNS 通、冒烟全绿 | T010–T012 |
| M6 需求闭环 | 仅落 node、加节点、升级回滚全部实证 | T013–T015 |
| M7 交付 | 端到端可从干净环境复现 + 文档完整 | T016 |

## 备注与已知限制

- **验证环境（v1.2 勘定，影响 T005/T006/T008/T014/T015/T016）**：PID1 = systemd（`is-system-running` = running）、**免密 sudo 可用**；但 docker **registry 不可达**（`docker pull` i/o timeout，无镜像）、`molecule`/`testinfra`/`ansible-lint` 不可安装。
  因此表中「molecule / docker / libvirt」类**测试方式当前不可执行**：这类任务一律改为「**可执行部分真实跑 + 不可执行部分显式受限 + 给出真机复验步骤**」；
  **验收摘要不因此弱化**，只是把验证拆成「已验 / 受限未验」两栏如实标注（对应 spec C13 / R1）。
- **主机级变更禁令**：虽然具备 root（免密 sudo）与 systemd，但本机是共享开发机，**禁止**执行 `swapoff`/`sysctl --system`/改主机名/装包等破坏性变更；
  这类效果一律按受限项处理，需在真机/VM 复验。
- 若环境无 libvirt/多 VM：T005/T006 的「故障漂移」、T014/T015 的端到端需以容器近似完成，**必须在契约与评估报告中显式声明局限**（对应 spec R1），不得声称等价于真实 HA。
- 容器近似无法验证内核相关的 Cilium 数据面能力（spec R4），需在文档的已知限制中列出。
- QAgate 一律 `normal`：每条验收都是可判定命令，无需降级为阶段末统一评估。
- 允许在契约中微调交付物文件名/位置，但**验收摘要不得弱化**；若需弱化，必须回到 Planner 修订 roadmap。
