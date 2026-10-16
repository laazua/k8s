# 规格（spec.md）· k8s 二进制 Ansible 部署

> 状态：**已定稿（v1，Planner）**。层级：产品 / 高层架构。**不含实现细节**（目录名、变量名、逐行任务由 Generator 决定）。
> 上游：根 `README.md`。下游：`roadmap.md`、`contracts/T00N.md`。
> 覆盖标记：每条 README 要求后标注其落点任务（`→ T0NN`）。

---

## 1. 目标（Goals）

| # | 目标（源自 README） | 落点 |
| --- | --- | --- |
| G1 | 以**二进制形式**部署 k8s 集群的**脚本化**方案（非 kubeadm、非包管理） | T007/T008 → T012 |
| G2 | **通用部署 · 任意 k8s 版本**：仅改配置即可切换版本 | T003/T007/T008（版本变量化） |
| G3 | **通用部署 · 任意 Linux 发行版**：主流发行版开箱可用 | T002（按 os_family 分支） |
| G4 | 交付的**项目结构为 Ansible role 形式** | T001（骨架）+ 全程 |
| G5 | **CRI = containerd** | T008 |
| G6 | **CNI = Cilium** | T010 |
| G7 | **master 高可用**（≥3 控制面 + apiserver VIP/LB + 奇数 etcd） | T005/T006/T007 |
| G8 | **业务工作负载只允许落在 node 节点** | T013 |
| G9 | **可方便新增节点**（不改动既有集群） | T014 |
| G10 | **可升级集群版本**（并有回滚路径） | T015 |
| G11 | 下载二进制/依赖时**支持代理设置**（网络受限环境可部署） | T003 |
| G12 | 开发过程采用 **TDD**（先测试后实现） | 全部任务（硬门禁） |
| G13 | 交付一套可直接使用的 **AI agent 驱动 harness**（三角色 + 上下文驱动 + token 经济） | **已满足**（`AGENTS.md` + `docs/harness/` 已存在）；本 spec 不重复规划 |

> 注：G13 属 README「harness 系统」章节，仓库中已实现。本 roadmap 只规划 G1–G12 的**产品实现**；
> 若后续发现 harness 缺陷，以**新任务**追加，而非混入本 roadmap。

## 2. 非目标（Non-Goals）

- **N1** 不使用 kubeadm / k3s / k0s / 发行版包管理器部署核心组件（明确走二进制 + systemd）。
- **N2** 不负责基础设施制备（不创建 VM、不配交换机/防火墙、不做云 provider 资源编排）。
- **N3** 不交付业务应用、CI/CD、监控/日志栈（Prometheus/ELK 等）——仅保证其**可被调度到 node**。
- **N4** 不提供 GUI / 控制台 / Operator 化集群生命周期管理。
- **N5** 不支持非 Linux 主机；Windows 节点不在范围。
- **N6** 不做 k8s 大版本（major）跨代升级的保证（默认只保证 minor 内/相邻 minor）。
- **N7** 不做多集群联邦、Service Mesh 应用层配置。

## 3. 约束（Constraints）

**C-功能**
1. 任意 k8s 版本：目标支持 k8s **≥ v1.24**（CRI 直连 containerd，无 dockershim 依赖）；版本、二进制 URL、sha256 全部可配置。
2. 任意发行版：**一级支持** RedHat 家族（RHEL/CentOS/Rocky/Alma）与 Debian 家族（Ubuntu/Debian）；其余发行版「尽力而为」，差异点必须在文档声明。
3. 高可用：控制面 ≥3；etcd 成员数**奇数**（默认 3）；apiserver 前有 **VIP**。
4. 调度：控制面必须带不可调度语义（污点/标签），业务**默认只能**落到 node。
5. 扩展与升级：加节点与升级都是**独立可重复执行**的入口，且不要求重建集群。
6. 代理：下载路径必须支持 http/https 代理与 no_proxy，并在代理不可达时给出明确失败信息。

**C-工程**
7. **TDD 强制**：每个任务先提交失败的测试，再提交实现；无测试不得标记完成。
8. **幂等**：任意剧本可重复执行；第二次 `changed=0`（例外须在契约中声明并说明理由）。
9. **可复现**：从干净环境按文档可重跑得到相同结果。
10. **静态质量**：`ansible-lint` 0 error；`--syntax-check` 全通过；使用 FQCN。
11. **安全**：密钥/证书/kubeconfig 不入库；证书由 role 生成；apiserver 安全默认（如 `--anonymous-auth=false`、最小授权模式）。
12. **Token 经济**：一个任务一个会话；跨会话只依赖 `state.yaml` + `handoff.md`（harness 铁律）。

## 4. 组件清单（Component Inventory）

| 层 | 组件 | 职责（架构层） |
| --- | --- | --- |
| 基础设施前置 | 主机准备 | 内核模块、sysctl、swap 关闭、时区/chrony、主机名与 hosts、防火墙/SELinux 策略 |
| 制品分发 | 下载与代理 | 按 URL+校验和取二进制/镜像包，支持代理、支持缓存/跳过已存在 |
| 安全 | PKI | 自建 CA 与全部组件证书（apiserver/kubelet/etcd/front-proxy/SA/admin） |
| 数据面 | etcd 集群 | 外部 etcd（二进制 + systemd），奇数成员，健康检查 |
| 高可用 | LB + VIP | apiserver 负载均衡 + 虚拟 IP 漂移（keepalived/haproxy 或 kube-vip） |
| 控制面 | apiserver / controller-manager / scheduler | 二进制 + systemd，经 VIP 暴露 |
| 运行时 | containerd (+runc, CNI plugins) | CRI 端点，systemd cgroup 驱动 |
| 节点 | kubelet / kube-proxy | 节点注册、Pod 生命周期、Service 转发 |
| 网络 | Cilium | Pod 网络、跨节点连通、网络策略 |
| 集群内附加 | CoreDNS / kubeconfig / RBAC | 集群可用性最小集合 |
| 交付物 | Ansible roles + playbooks | site（全量）/ control-plane / node / add-node / upgrade |

## 5. 关键数据流与接口（架构层）

- **配置流**：inventory（分组：控制面/etcd/节点）→ `group_vars`（版本、CIDR、VIP、代理、路径）→ role `defaults` 兜底 → 模板化到组件配置/证书 SAN/systemd unit。
- **部署流**：前置准备 → 制品下载 → PKI → etcd → LB/VIP → 控制面 → 运行时 → kubelet/kube-proxy → CNI → 附加组件 → 冒烟验证。
- **扩展流**：新节点仅需加入 node 分组 → 走「运行时 + kubelet + CNI join」路径，不触碰既有控制面。
- **升级流**：按「控制面 → 节点」顺序滚动替换二进制并重启，保留旧二进制以便回滚。
- **对外接口**（三类使用者接口）：① inventory + 变量（配置面）；② playbook 入口（操作面：安装/加节点/升级）；③ 验证脚本（断言面：集群状态可判定）。

## 6. 验收总纲（Acceptance Outline）

任一条验收都必须是**可判定的命令或明确手工步骤**，不接受「稳定/良好」类描述。

| A# | 验收项 | 判定方式（概要） |
| --- | --- | --- |
| A1 | 骨架与静态质量 | `ansible-lint` 0 error + `--syntax-check` 通过 |
| A2 | 主机准备幂等 | 连跑两次 `changed=0`；内核/sysctl/swap 断言通过 |
| A3 | 制品获取与代理 | 给定 url+sha256 下载校验成功；设代理时请求走代理；重复执行跳过下载 |
| A4 | PKI 正确性 | 各证书 SAN 覆盖 VIP/所有 master/节点名；私钥权限 600；重跑不覆盖有效证书 |
| A5 | etcd 集群 | 3 成员健康，成员列表=3，重启后自愈 |
| A6 | 高可用 | VIP 存在且可漂移；`https://VIP:6443/healthz` 返回 ok |
| A7 | 控制面 | 三组件 systemd active；`kubectl get --raw /healthz` ok；安全默认生效 |
| A8 | 运行时与节点 | `crictl info` 正常；kubelet active；节点 Ready |
| A9 | Service 转发 | ClusterIP 可达 |
| A10 | CNI | `cilium status` healthy；跨节点 Pod 互通 |
| A11 | 附加组件 | CoreDNS Running；集群内 DNS 解析成功 |
| A12 | 集群冒烟 | 全部节点 Ready；系统 Pod 全 Running |
| A13 | 调度约束 | 控制面不可调度；示例工作负载仅落在 node |
| A14 | 加节点 | 对新 node 执行剧本后 Ready，且可重复执行 |
| A15 | 升级与回滚 | 升级一个 minor 版本后集群 Ready；回滚路径经实际执行验证 |
| A16 | 端到端 | 从干净 inventory 一条命令得到可用 HA 集群，全流程文档可复现 |

## 7. 风险与开放问题（Risks & Open Questions）

**风险**
- **R1 环境风险（高）**：真实多节点 VM 稀缺，HA 漂移、加节点、升级难以完整验证。缓解：molecule/libvirt 优先，容器近似方案需在契约中声明局限，不得声称已验证。
- **R2 发行版碎片化（中高）**：cgroup v1/v2、SELinux、firewalld vs nftables、systemd 版本差异会引发非幂等失败。缓解：一级支持两个家族，差异集中收敛到 base role。
- **R3 版本矩阵（中）**：二进制 URL/校验和随版本变化，且组件兼容矩阵随版本演进。缓解：制品清单集中可配置 + 校验和必填。
- **R4 网络/Kernel 对 Cilium 的要求（中）**：内核版本不足导致数据面能力降级。缓解：前置检查 + 文档声明最低内核。
- **R5 升级不可逆（中高）**：etcd 数据格式与证书兼容性。缓解：升级前备份与显式回滚步骤（见 Q1）。
- **R6 安全默认过于宽松（低中）**：为跑通而放松认证会埋隐患。缓解：A7 将安全默认列入验收。

**开放问题（本 spec 不阻塞，由默认决策兜底）**
- **Q1** etcd 备份/恢复与灾难恢复是否属本阶段范围？（默认：**不在** roadmap 主线，仅在升级任务中要求「升级前备份」）
- **Q2** 是否需要完整 air-gap 离线包（打包所有二进制+镜像），而非仅代理？（默认：**仅代理 + 可选本地制品目录**）
- **Q3** 升级是否需支持跨多个 minor 连续升级与自动回滚？（默认：**仅相邻 minor 升级 + 手工回滚**）

## 8. 默认决策（含假设）— Planner 冻结，供下游一致引用

**D1 · HA 机制**
- 决策：默认 **keepalived（VRRP VIP）+ haproxy（apiserver 负载均衡）**；通过变量可切换为 **kube-vip**。
- 假设：环境允许使用 VRRP（同二层网段、允许 112 端口协议）。若为云环境不支持 VRRP，则使用 kube-vip 的 ARP/BGP 模式。**该差异必须可配置而非硬编码。**

**D2 · kube-proxy 与 Cilium 模式**
- 决策：默认**保留 kube-proxy**，Cilium 以 VXLAN 隧道模式运行；`kubeProxyReplacement` 作为**可选项**暴露。
- 假设：兼容性优先于性能，默认路径必须能在最广泛内核上跑通。

**D3 · 版本基线与制品来源**
- 决策：目标基线 **k8s ≥ 1.24**（默认示例取一个当前稳定 minor）；组件二进制统一从官方发布地址获取并**强制 sha256 校验**；etcd 使用官方二进制独立部署（非容器）。
- 假设：生产环境可访问官方源或已配置代理/本地制品目录；不支持无校验下载。

> 其余可配置面（CIDR、端口、路径、镜像仓库、CNI 参数）一律变量化并给默认值（见 `repo-conventions.md` §3）。

## 9. 需求 → 落点对照（覆盖自检）

| README 要求 | 覆盖 |
| --- | --- |
| 二进制部署脚本 | G1 / §4 / A12 |
| Ansible + role 结构 | G4 / §4 / A1 |
| CRI = containerd | G5 / A8（默认决策 D2 附注） |
| CNI = Cilium | G6 / A10 / D2 |
| master 高可用 | G7 / A5,A6,A7 / D1 |
| 业务只落 node | G8 / A13 |
| 可加节点 | G9 / A14 |
| 可升级 | G10 / A15 / D3 |
| TDD | G12 / C7 / 全部任务 QAgate |
| 下载代理 | G11 / A3 / C6 |
| 任意版本 | G2 / C1 / D3 |
| 任意发行版 | G3 / C2 / R2 |
| harness 系统 | G13（已满足，非本 roadmap 范围） |
