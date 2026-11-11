# roles/cluster-addons

kubeconfig / RBAC / CoreDNS 核心附加组件（T011）。

## 交付
- `admin.conf`、`kubelet.conf`：从 `roles/pki` 产物内嵌 CA/leaf，`0600 root:root`；
  默认不覆盖（`cluster_addons_rotate_kubeconfigs=true` 时强制更新）。
- RBAC：kubelet（Group `system:nodes`）最小权限（**不含 secrets**）；CoreDNS 只读权限。
- CoreDNS：Deployment/Service/SA/ClusterRole(Binding)/ConfigMap(Corefile)/Service，
  版本、域、上游、缓存、端口、镜像仓库、TLS endpoint 全部变量化。

## 关键变量
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `cluster_addons_root_prefix` | `""` | 沙箱前缀（测试用） |
| `cluster_addons_server` | VIP/本机:6443 | kubeconfig 的 server |
| `cluster_addons_cluster_domain` | `cluster.local` | 集群域 |
| `cluster_addons_coredns_upstream` | `/etc/resolv.conf` | 上游 DNS |
| `cluster_addons_coredns_version` | `1.11.3` | 镜像版本（仅渲染） |
| `cluster_addons_coredns_ready_port` | `""` | `ready` 插件端口（空 → 插件默认 :8181） |
| `cluster_addons_coredns_kubernetes_endpoint` | `""` | 非空时写入 Corefile（测试/独立运行） |

## 受限（本环境无镜像）
- CoreDNS Deployment 未在真实集群 apply/运行；Pod Running、集群内 DNS 解析未验证。
- CoreDNS 配置语义由官方二进制在测试沙箱内按同一 Corefile 真实验证（非 Pod 网络）。
- 沙箱 apiserver 只开 `RBAC`（Node authorizer 会给 kubelet 隐式放行 secrets 等），
  生产默认仍为 `RBAC,Node`。
