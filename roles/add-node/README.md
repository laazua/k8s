# role · add-node

把一台**未初始化的新 worker** 加入既有集群：只消费既有集群 CA 签发本节点 kubelet 证书，
再用 `containerd` + `kubelet` role 幂等收敛节点运行时，最后在控制端读回注册结果。

真机入口：`playbooks/add-node.yml`（`hosts: k8s_node`、`serial: 1`、tags `add-node`）。

## 职责

1. **fail-fast**（落盘前）：目标主机必须属于 `add_node_target_group`（默认 `k8s_node`），
   且不得命中 `add_node_forbidden_groups`（默认 `k8s_master` / `etcd`）；集群 CA 证书必须存在；
   `sign` 模式要求 CA 私钥、`preissued` 模式要求已分发 kubelet 证书；kubelet 与集群 minor
   版本兼容；`verify` 开启时控制端 kubeconfig/kubectl 可用。
2. **只签发、不建 CA**：`sign` 模式用 `pki` 的 `tasks_from: cert` 只签发本节点证书
   （`CN=system:node:<node>`、`O=system:nodes`），显式传 `pki_ca_rebuilt={kubernetes:false}`；
   签发前后比对 CA 证书/私钥 sha256，任何变化即失败。
3. **幂等**：证书走 pki 的「有效且匹配 → 不重签」判定；已加入的节点显式打印「已加入」并
   跳过签发；`containerd`/`kubelet` 产物走内容比较，重复执行 `changed=0` 且不重启 kubelet。
4. **最小权限**：worker 只持有 kubelet 身份；verify 在控制端用 `admin.conf` 读回，
   并断言节点上没有 `admin.conf`。
5. **零影响**：不触碰既有控制面/既有节点的任何文件或进程；不重建 CA。

## 目录与文件

| 路径 | 说明 |
| --- | --- |
| `tasks/validate.yml` | 分组/CA/证书模式/版本/verify 前置校验（只读） |
| `tasks/cert.yml` | 只签发本节点证书 + CA 哈希反证（不建 CA） |
| `tasks/verify.yml` | 控制端读回 node/Ready/reason + 权限与最小权限断言 |
| `tasks/main.yml` | 入口与 tags（`add-node:validate` / `add-node:cert`） |

## 关键变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `add_node_root_prefix` | `""` | 沙箱前缀（生产留空） |
| `add_node_target_group` | `k8s_node` | 允许执行加节点的分组 |
| `add_node_forbidden_groups` | `[k8s_master, etcd]` | 禁止分组（防误把控制面当新节点） |
| `add_node_cert_mode` | `sign` | `sign`（本地用 CA 私钥签发）/ `preissued`（只校验已分发证书） |
| `add_node_ca_cert` / `add_node_ca_key` | `<pki>/ca.crt` / `<pki>/ca.key` | 既有集群 CA（**只读**） |
| `add_node_kubelet_cert` / `_key` | `<pki>/kubelet/<node>.crt` / `.key` | 本节点 kubelet 证书 |
| `add_node_cluster_version` | `k8s_version` | 集群版本（minor 兼容判定） |
| `add_node_kubelet_version` | `kubelet_version` | 目标 kubelet 版本 |
| `add_node_allow_minor_skew` | `0` | 允许的 minor 偏差 |
| `add_node_verify_registration` | `true` | 是否在控制端读回注册结果 |
| `add_node_verify_kubeconfig` | `/etc/kubernetes/admin.conf` | 控制端 kubeconfig |
| `add_node_verify_kubectl` | `/usr/local/bin/kubectl` | 控制端 kubectl |
| `add_node_verify_retries` / `_delay` | `60` / `2` | 等待节点注册的重试 |
| `add_node_manage_host` | `true` | 是否执行 `base` 主机级准备（沙箱可关） |

## 用法（真机）

```bash
cp inventory/hosts.example inventory/hosts.yml     # 把新节点填进 [k8s_node]
ansible-playbook -i inventory/hosts.yml playbooks/add-node.yml -l <new-node> \
  -e add_node_cert_mode=preissued                  # 推荐：节点上无 CA 私钥
kubectl get node <new-node> -o wide
```

重复执行同一命令应 `changed=0` 且不重启 kubelet；`--check` 对 add-node 自身的判定
（分组/CA/版本/证书是否已存在）只读执行（`containerd`/`kubelet` 的写任务在 check 模式跳过）。
