# tests/add-node — T014 加节点流程验收

`make test-add-node` → `tests/add-node/test_add_node_flow.sh`

## 测什么

在**同一宿主**上搭一个「既有集群」+ 一台「未初始化的新节点」，然后**真实执行**
`playbooks/add-node.yml -l node2`：

| 组 | 内容 |
| --- | --- |
| 既有集群 | 真实 etcd（TLS，12379）+ 真实 kube-apiserver（16443）+ 既有 worker `node1`（containerd + kubelet，20250/20248） |
| 新节点 | 独立 root `$SB/node2`：独立 containerd socket/state/root + kubelet（20251/20249，节点名 `node2`） |
| 断言 | 新节点由真实 kubelet 注册、Ready 条件有 reason、kubelet.conf 身份 `system:node:node2`、RBAC `get nodes=yes` / `create serviceaccounts=no` |
| 幂等 | **同一命令**连跑两次，第二次 `changed=0`，证书/配置哈希与 kubelet PID 不变 |
| 零影响 | node1 kubelet / apiserver / etcd PID + 启动时间不变；node1 配置/证书哈希不变；集群 `etc/kubernetes` 全树哈希不变 |
| fail-fast | 非 `k8s_node` 主机、缺 CA 证书/私钥、preissued 缺证书、kubelet 版本不兼容、verify 缺 kubeconfig |
| `--check` | rc=0、`changed=0`、产物哈希不变 |
| 宿主 | 不写 `/etc/kubernetes`、`/etc/systemd/system`；不 `systemctl start/stop`；退出恢复 `kernel.panic*` 与本次新建 `kubepods*` slice |

## 沙箱布局

```
$SB/                       # 集群根（pki / etcd / apiserver / admin.conf / addons）
$SB/node1/                 # 既有 worker（独立 root，端口 20250/20248）
$SB/node2/                 # 新 worker（独立 root，端口 20251/20249；由 add-node 装配）
```

- `sandbox_stack.yml`：kubectl + pki（只为 `[k8s_existing_node]` 预签 node1 证书）+ etcd + apiserver。
  **故意不为 node2 预签证书**，否则「首跑 changed>0」不可判定。
- `sandbox_node1.yml` / `sandbox_node1_kubelet.yml`：既有 worker 的 containerd 段与 kubelet 段
  （证书从集群 PKI 复制到节点，模拟分发）。分两段是因为沙箱没有 systemd：kubelet role 的
  validate 要求 CRI socket 已存在，测试在段间从渲染出的 unit 拉起 containerd（T008 同一范式）。
- `sandbox_node2_containerd.yml`：**预置**新节点的 containerd 运行时（同一 role/变量），测试随后从
  渲染出的 unit 拉起它。原因：沙箱不启 systemd，而 `kubelet` role 的 validate 要求 CRI socket
  已存在；生产里由 containerd 的 systemd 服务先于 kubelet 启动。add-node 首跑时 containerd 段
  因此全部 `changed=0`，不影响「首跑签发证书 + 装配 kubelet + 注册」的判定。
- `sandbox_add_node_nonmember.yml`：把 `roles/add-node` 应用到不在 `[k8s_node]` 的主机 → 必须失败。
- 新节点自身由 `playbooks/add-node.yml` 装配（测试不另写 play），参数见脚本生成的
  `$SB/addnode-vars.json`。

## 为什么沙箱把 CA 私钥预置到新节点

默认 `add_node_cert_mode=sign` 在节点本地签发 kubelet 证书（`pki` 的 `tasks_from: cert`），
需要 CA 私钥。沙箱把集群 `ca.crt`+`ca.key` 复制到 `$SB/node2/etc/kubernetes/pki/` 模拟运维分发。
**生产推荐 `add_node_cert_mode=preissued`**（控制面签发后分发，节点无 CA 私钥），见契约 §5。

## 已知限制

无镜像 → 系统 Pod 不 Running（只断言清单/对象/RBAC，固定 2 条 SKIP，不计 PASS）；「新节点」是
同宿主的第二套运行时，不覆盖真实跨主机 join；沙箱不启 systemd：node1 拆成 containerd/kubelet
两段、node2 的 containerd 在 add-node 前预置并由测试拉起（同一 role/变量），handler 重启路径
未验证；`base` 以 `add_node_manage_host=false` 整体跳过；`--check` 只真实执行 add-node 自身的
只读判定（containerd/kubelet 在 check 模式整体跳过，见契约 §7/§9）。
详见契约 `docs/harness/state/contracts/T014.md` §5/§9。
