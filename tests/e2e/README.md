# tests/e2e — 集群冒烟（T012）

一条命令输出 `PASS/FAIL/SKIP` 逐项结果与汇总，用于交付后快速判定集群是否可用。

```bash
# 1) 静态交付检查（秒级，不启动进程）
tests/e2e/smoke.sh --static-only

# 2) 沙箱冒烟（默认）：真实 pki → etcd → kube-apiserver → containerd → kubelet
#    → kubeconfig/RBAC → CoreDNS 官方二进制；约 5 分钟
tests/e2e/smoke.sh --mode sandbox

# 3) 真机冒烟：节点全 Ready、kube-system Pod 全 Running、kube-dns 存在；
#    可选 --image 追加集群内 DNS Job 与跨节点 Pod 检查
tests/e2e/smoke.sh --mode real --kubeconfig /etc/kubernetes/admin.conf \
  [--image registry.example.com/busybox:1.36]
```

输出协议（便于 CI 解析）：

```
PASS  节点 node1 已注册（真实 kubelet）
SKIP  系统 Pod Running（无镜像；真机用 --mode real）
RESULT=PASS
PASS=30
FAIL=0
SKIP=3
```

退出码：`0` 无 FAIL；`1` 存在 FAIL；`2` 用法错误。
`SKIP` 表示环境受限未验证，不计入通过数，但仍需在报告中保留。

## 沙箱模式覆盖

| 检查 | 说明 |
| --- | --- |
| 交付物 + 语法 | 14 个 role、5 个 playbook、12 个测试目录、`--syntax-check` |
| 控制面 | 单成员 TLS etcd healthy；`/healthz=ok`；admin `can-i '*' '*'` |
| 节点 | 真实 containerd（CRI `RuntimeReady`）+ kubelet 注册 `node1`；Ready 条件与 reason |
| 附加组件 | `kubelet.conf` 0600 root:root、身份 `system:node:node1`、RBAC apply 与 `can-i` 正反例 |
| DNS | CoreDNS 1.11.3 官方二进制按 role 渲染的 Corefile 解析 `kubernetes.default` → `10.96.0.1` |
| 受限 | 系统 Pod Running、kube-dns ClusterIP、跨节点 Pod（无镜像，SKIP） |

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `T012_TEST_CACHE` | `/tmp/opencode/k8s-cache` | 官方制品缓存（首次运行需外网，自动预取并校验 sha256） |
| `E2E_EXPECT_NODES` | `1` | real 模式要求的最小节点数 |
| `KUBECTL` | `kubectl` | real 模式使用的 kubectl |
| `ANSIBLE_PLAYBOOK` | 自动探测 | ansible-playbook 路径 |

## 安全边界

- 全部落盘在 `mktemp -d /tmp/opencode/t012.*`，`trap` 清理；不写宿主
  `/etc/kubernetes`、`/etc/systemd/system`，不调用 `systemctl` 启停服务。
- 进程由 role 渲染的 unit 的 `ExecStart` 拉起，只按沙箱路径匹配停止。
- kubelet 可能修改宿主 `kernel.panic*` 并创建 `kubepods.slice`，退出时恢复/清理。

## 真机说明（受限项必须在真机补验）

沙箱无法验证：**系统 Pod 全部 Running**、**kube-dns ClusterIP 解析**、**跨节点 Pod 互通**。
真机执行 `--mode real` 后，请把 `RESULT=PASS` 与 SKIP 列表一并记录；若提供 `--image`，
集群内 DNS Job 会自动执行，跨节点检查需按实际拓扑另行投放。
