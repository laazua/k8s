# 任务清单（Roadmap）· k8s 二进制 Ansible 部署

> 状态：**已复核定稿（v1.4，Planner，2026-11-12）**，取代 v1.3。上游：`spec.md`（G1–G13 / A1–A16 / C1–C14 / D1–D3 / R7）。
> v1.4 变更：T012 → done（r1 = PASS）；新增 **T017**（e2e real 模式健壮性修复），作为 T016 的强制前置；
> 全量测试成本更新为 12 套件 / 1799 断言 / ~56 分钟。
> v1.3 变更：T009 → done；T010 验收按 spec v1.5 / R1 v1.4 **无镜像范式**重述（目标验收保留 + 受限项声明 + netns/veth VXLAN 下沉验证）。
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
| T006 | done | 控制面高可用 role（LB + VIP） | `roles/haproxy`、`roles/keepalived`（`ha_mode=kube-vip` 可切换） | VIP 可达且 `curl -k https://<VIP>:6443/healthz` 返回 ok；停掉持有 VIP 的 master 后 VIP 漂移到另一 master 且仍返回 ok [A6, D1] | T002, T003 | 集群断言 + 故障注入（停/起节点） | normal |
| T007 | done | 控制平面组件 role | `roles/kube-apiserver`、`roles/kube-controller-manager`、`roles/kube-scheduler` | 三组件 systemd active+enabled；`kubectl get --raw /healthz` 与 `/readyz` 为 ok；apiserver 安全默认生效（`--anonymous-auth=false`、RBAC 授权）[A7, C11] | T004, T005, T006 | 集群断言 + 配置文件/进程参数断言 | normal |
| T008 | done | 运行时与节点组件 role | `roles/containerd`、`roles/kubelet`（+runc、CNI plugins、cgroup driver=systemd） | containerd、kubelet systemd active；`crictl info` 返回正常且 CRI 端点可连通；kubelet 启动后节点出现在 `kubectl get nodes`（可能 NotReady，CNI 未就绪）[A8] | T002, T003, T004 | molecule（容器内验证配置）+ 集群断言 | normal |
| T009 | done | kube-proxy role | `roles/kube-proxy`（DaemonSet 或二进制二选一，契约内声明） | kube-proxy 在全部 node 运行；创建 Service 后 ClusterIP 可访问 [A9]（无镜像范式：netns 内真实 etcd/apiserver/kube-proxy + 手工 Service/EndpointSlice 指向本地 mock；`curl <ClusterIP>` 必须 200 且响应体来自 mock，端点移除→失败→恢复成功） | T008 | 沙箱 netns 真实进程 + ClusterIP 实测 + 宿主零污染断言 | normal |
| T010 | done | Cilium CNI role | `roles/cilium`（helm/manifest + 变量化版本与参数，默认 VXLAN、保留 kube-proxy） | **目标验收**：`cilium status` healthy；跨节点两个 Pod 互相 ping/HTTP 成功；`kubectl get nodes` 全部 Ready [A10, D2]。**本环境无镜像/registry 不可达 → 目标项为受限项**，实际可判定面：①渲染产物与变量一致（版本/VXLAN/`kubeProxyReplacement=false`/集群名与 ID/Pod CIDR/API endpoint），清单可解析且 `--syntax-check` 通过；②netns+veth 双节点拓扑上按渲染参数真实建立 VXLAN 隧道，跨 netns ICMP/HTTP 成功（内核数据面，非 Pod 网络）；③连跑两次 `changed=0`；④契约 §5 逐项声明「cilium-agent/Pod/Node Ready 未验证」并给真机复验步骤 | T009 | 静态/渲染断言 + netns/veth VXLAN 数据面 + 幂等复跑（无镜像范式） | normal |
| T011 | done | kubeconfig / RBAC / 核心附加组件 role | `roles/cluster-addons`（admin&kubelet kubeconfig、CoreDNS、必要 RBAC） | **目标验收**：admin kubeconfig 可用于本机 `kubectl`；CoreDNS 全部 Pod Running；集群内 DNS 解析（`nslookup kubernetes.default`）成功 [A11]。**无镜像范式下的可判定面**：①admin/kubelet kubeconfig 由 role 签发，对**真实沙箱 apiserver** 验证 TLS 认证 + RBAC 正反例（`kubectl auth can-i` 允许/拒绝）；②CoreDNS 用**官方二进制制品**（非镜像，复用 `roles/download` + sha256）按 role 渲染的 Corefile **真实启动**，用 `dig` 验证 `kubernetes.default`/Service A 记录、上游转发与 `ready`；③连跑两次 `changed=0`；④fail-fast（kubeconfig 缺 CA/证书与 CA 不匹配、RBAC 越权自检）；⑤**受限项**：CoreDNS Pod Running / 集群内 DNS 为未验证，真机复验步骤入契约 §5 | T010 | 真实 apiserver 认证/RBAC + CoreDNS 二进制真实解析 + 幂等复跑（无镜像范式） | normal |
| T012 | done | 集群验证与冒烟测试套件 | `tests/e2e/smoke.sh`（`--static-only` / `--mode sandbox` / `--mode real`）+ `tests/e2e/test_smoke_contract.sh`（31 断言）+ `README.md`；Makefile `test-e2e` / `smoke-e2e` | **目标验收**：一条命令判定全部节点 Ready、系统 Pod 全 Running、集群内 DNS、跨节点 Pod 互通，输出 `PASS/FAIL/SKIP` + `RESULT` 与退出码 [A12, C14]。**已验（sandbox）**：真实 etcd/apiserver/containerd/kubelet → `node1` 注册且 Ready 条件有 reason；kubeconfig 身份与 RBAC 正反例；CoreDNS 真解析 `kubernetes.default=10.96.0.1`；`--mode real` 实现前三项目标项。**受限**：系统 Pod Running / kube-dns ClusterIP / 跨节点互通无镜像未验（固定 3 条 SKIP + 真机 `--mode real`） | T011 | sandbox 全链路冒烟 + 契约套件 + 重复运行一致性（30/0/3 SKIP；31/0 ×2） | normal |
| T013 | todo | 调度约束：业务仅落 node | `roles/taints`（或并入 base 的独立 tag）+ 示例工作负载 | 控制面节点带 `NoSchedule` 污点与角色标签；一个**不带 toleration** 的示例工作负载多个副本全部调度到 node（0 副本落在 master）[A13, G8] | T012 | 集群断言（`kubectl get pods -o wide` 校验节点分布） | normal |
| T014 | todo | 加节点流程 | `playbooks/add-node.yml` + 文档 | 对一个未初始化的新 node 执行剧本后该节点 Ready 且系统 Pod 正常；**重复执行 `changed=0`**；既有控制面/节点无重启无配置变更 [A14, G9] | T012（T008 的 node 路径复用） | 端到端（新增 VM/容器作为 node） | normal |
| T015 | todo | 版本升级与回滚 | `playbooks/upgrade.yml` + 回滚说明 | 将集群升级一个 minor 版本（升级前自动备份 etcd/证书）：升级后全部节点 Ready 且版本号已变更；按文档执行回滚后回到原版本且集群仍 Ready [A15, G10, D3] | T014 | 端到端（升级 + 回滚实跑，各一次） | normal |
| T016 | todo | 端到端验收与使用文档 | `tests/e2e/` 全流程脚本、`docs/` 使用手册（inventory 填写、变量说明、代理/离线、加节点、升级、回滚、已知限制） | 从干净 inventory 按 README 快速开始流程可一条命令得到可用 HA 集群；文档覆盖全部可配置项与已知限制；**T013/T014/T015 的验收在同一轮全流程中全部复现通过** [A16] | T013, T015, T017 | 端到端全流程（干净环境重跑） | normal |
| T017 | todo | e2e real 模式健壮性修复 | `tests/e2e/smoke.sh` + `test_smoke_contract.sh` 补强（不改变 sandbox 语义与既有计数） | ①`--mode`/`--image`/`--kubeconfig` 缺值 → **`rc=2` 立即退出**（不得挂起，负例测试覆盖）；②real 模式 API 不可达或 `kubectl` 查询为空 → **`FAIL`**（禁止 `0/0` 空集恒真 PASS）；③`--image` Job 创建被拒 → **`FAIL`**（不得降级 `SKIP`）；④清理失败必须影响最终 `RESULT` 或在汇总后显式报错（不得先打 `RESULT` 再静默清理）；⑤`make test-e2e` 仍全绿，sandbox 计数不回退（30/0/3 SKIP、契约 ≥31 断言） [A12, C14, R7] | T012 | 负例测试（错误 kubeconfig / 缺参 / 坏镜像）+ 契约套件连跑两次 | normal |

> 注：T013 与 T014 **可并行**（互不依赖）；T016 依赖 T013/T015 与 **T017** 完成，故为主线的终点。
> 注（v1.4，2026-11-12）：T012 r1 = PASS（accepted，被测 `37896d8`，六项 4/5/4/4/4/5，完整度 3）。
> 遗留 **D1–D3 已提升为阻塞 T016 的修复项**（不是 T012 返工）：D1 real 模式 API 不可达时空集恒真 PASS、
> D2 `--image` Job 创建失败降级 SKIP、D3 参数缺值死循环（实测 `rc=124`）→ 全部由 **T017** 关闭；
> D4–D9（清理静默、static+real 强制 kubeconfig、Service IP/CoreDNS 版本双源、kubepods 清理粒度、
> 静态仅查存在、meta 仅 `SKIP>=3`）中 **D4/D6/D9 纳入 T017**，其余在对应任务顺手修。
> 注（v1.3，2026-11-09）：T010 起凡涉及「Pod / 镜像 / `cilium status` / 节点 Ready」的验收，
> 一律按 **spec R1 v1.4 无镜像范式**执行：**目标验收保留在摘要中**，同时给出本环境可判定的
> 下沉验证面，并在契约 §5 逐项声明「未验证」+ 真机复验步骤；**不得**把下沉验证表述为已达成目标验收。
> 注（v1.4，2026-11-10）：T010 r1 评估 PASS，遗留非阻塞项——**D4（真机前必做）**：渲染清单需补
> operator `coordination.k8s.io/leases` RBAC 与 CNI 安装 initContainer（否则 §5.7 真机步骤可能失败）；
> **D2/D3/D5（测试卫生）**：B5 宿主快照仍有全局 vxlan 计数与采集失败静默、`pkill -f` 匹配过宽、
> cluster-id/API endpoint/version 缺动态变体 → 在 T011/T012 的测试中避免同类问题，或另立收尾任务。

## 依赖与并行

```
T001 ─┬─ T002 ─┐
      └─ T003 ─┴─ T004 ─┬─ T005 ─┐
                        │         ├─ T007 ──┐
              T002 ─────┴─ T006 ──┘         │
                        └─ T008 ─── T009 ───┴─ T010 ── T011 ── T012 ─┬─ T013 ──────────────┐
                                                                     ├─ T014 ── T015 ──────┼─ T016
                                                                     └─ T017 ──────────────┘
```

- 起点即可并行：**T002 与 T003**（均只依赖 T001）。
- T005 与 T008 在 T004 后可并行（etcd vs 运行时，互不依赖）。
- T006 只依赖 T002/T003，可与 T005 并行，但必须在 T007 之前完成。
- T013 / T014 / T017 在 T012 后三者并行。
- **T017 是 T016 的强制门禁**（A16 若在 real 模式假绿即失去意义），但不阻塞 T013/T014/T015。
- 无环（已按拓扑序排列）。

## 关键路径

`T001 → T002 → T003 → T004 → T006 → T007 → T008 → T009 → T010 → T011 → T012 → T014 → T015 → T016`

（T005 与 T006 并行，取较长的 T006 分支；T013、T017 为旁路，由 T016 收敛。）

## 里程碑

| 里程碑 | 达成条件 | 任务 |
| --- | --- | --- |
| M1 骨架可用 | lint/syntax 通过、目录与变量约定固定 | T001 |
| M2 基础能力就绪 | 主机准备、制品分发、PKI 三件套可独立验证 | T002–T004 |
| M3 控制面 HA 就绪 | etcd 集群 + VIP 漂移 + 三组件可跑 | T005–T007 |
| M4 单节点可加入集群 | 运行时/kubelet/kube-proxy 就绪 | T008–T009 |
| M5 集群可用（Ready） | CNI 通、DNS 通、冒烟全绿（sandbox 全链路可判定；真机项受限声明） | T010–T012 |
| M6 需求闭环 | 仅落 node、加节点、升级回滚全部实证 | T013–T015 |
| M7 交付 | 冒烟脚本 real 模式反证会 FAIL（T017）→ 端到端可从干净环境复现 + 文档完整 | T016, T017 |

## 备注与已知限制

- **验证环境（v1.2 勘定，影响 T005/T006/T008/T014/T015/T016）**：PID1 = systemd（`is-system-running` = running）、**免密 sudo 可用**；但 docker **registry 不可达**（`docker pull` i/o timeout，无镜像）、`molecule`/`testinfra`/`ansible-lint` 不可安装。
  因此表中「molecule / docker / libvirt」类**测试方式当前不可执行**：这类任务一律改为「**可执行部分真实跑 + 不可执行部分显式受限 + 给出真机复验步骤**」；
  **验收摘要不因此弱化**，只是把验证拆成「已验 / 受限未验」两栏如实标注（对应 spec C13 / R1）。
- **主机级变更禁令**：虽然具备 root（免密 sudo）与 systemd，但本机是共享开发机，**禁止**执行 `swapoff`/`sysctl --system`/改主机名/装包等破坏性变更；
  这类效果一律按受限项处理，需在真机/VM 复验。
- 若环境无 libvirt/多 VM：T005/T006 的「故障漂移」、T014/T015 的端到端需以容器近似完成，**必须在契约与评估报告中显式声明局限**（对应 spec R1），不得声称等价于真实 HA。
- 容器近似无法验证内核相关的 Cilium 数据面能力（spec R4），需在文档的已知限制中列出。
- **冒烟套件（v1.4）**：`make test-e2e` 已挂入 `make test`；全量 12 套件 = **1799** 断言
  （T012 实测 `rc=0` / 3347s）。sandbox 模式固定 3 条 SKIP（系统 Pod / kube-dns / 跨节点），
  **SKIP 不得计入 PASS**（spec C14）；real 模式必须在无集群/错 kubeconfig 下反证会 `FAIL`（T017）。
- QAgate 一律 `normal`：每条验收都是可判定命令，无需降级为阶段末统一评估。
- 允许在契约中微调交付物文件名/位置，但**验收摘要不得弱化**；若需弱化，必须回到 Planner 修订 roadmap。
