# roles/cilium — Cilium CNI（离线渲染清单）

## 作用

用 **Jinja 模板离线渲染** Cilium 部署清单（multi-doc YAML）：

- `ServiceAccount` / `ClusterRole` / `ClusterRoleBinding`（agent）
- `ConfigMap`（Cilium agent 配置）
- `DaemonSet`（`cilium-agent`）
- 可选 `cilium-operator`（`ServiceAccount`/`ClusterRole`/`Binding`/`Deployment`）

**不拉 helm chart、不拉镜像、不联网、不运行 `cilium-agent`**。渲染结果由真机
`kubectl apply` 后才会生效；运行态与 Pod 网络属真机验收（见契约 §5）。

## 关键变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `cilium_version` | `1.16.3` | 固定版本（禁止 `latest`）；镜像 tag 同值 |
| `cilium_mode` | `vxlan` | `vxlan` / `geneve` / `native` |
| `cilium_tunnel_port` | `8472` | VXLAN/Geneve 目的端口 |
| `cilium_mtu` | `1450` | 隧道 MTU（VXLAN 下应小于 underlay MTU） |
| `cilium_cluster_name` | `k8s_cluster_name` 或 `kubernetes` | 集群名 |
| `cilium_cluster_id` | `1` | 集群 ID，同时是 **VXLAN VNI**（24-bit） |
| `cilium_pod_cidr` | `k8s_pod_cidr` 或 `10.244.0.0/16` | Pod CIDR |
| `cilium_service_cidr` | `k8s_service_cidr` 或 `10.96.0.0/12` | Service CIDR |
| `cilium_k8s_api_endpoint` | `https://<vip>:6443` | API endpoint（host/port 写入 ConfigMap） |
| `cilium_kube_proxy_replacement` | `false` | 默认保留 kube-proxy |
| `cilium_kube_proxy_enabled` | `true` | 与上者冲突时 fail-fast |
| `cilium_image_registry` | `quay.io` | 镜像仓库前缀（可换离线/代理仓库） |
| `cilium_image_repository` | `cilium/cilium` | agent 镜像仓库 |
| `cilium_operator_enabled` | `true` | 是否渲染 operator |
| `cilium_agent_resources` | requests/limits | agent 资源 |
| `cilium_operator_resources` | requests/limits | operator 资源 |
| `cilium_tolerations` | `[{operator: Exists}]` | 允许跑在控制面 |
| `cilium_root_prefix` | `""` | 沙箱前缀（生产留空） |
| `cilium_manifest_path` | `<config_dir>/cilium/cilium.yaml` | 渲染落盘路径 |

## fail-fast

非法 `mode`、Pod/Service CIDR 缺失或非法、API endpoint 非法、
`kubeProxyReplacement=true` 但 kube-proxy 仍启用（冲突）、
版本格式/范围非法、cluster id/端口/MTU/registry/namespace/pullPolicy 非法 →
`assert` 失败，**在 render 之前**退出，不落盘、不改已渲染文件。

## 离线

role 只用 `ansible.builtin.file` / `template` / `stat` / `slurp` / `assert` /
`set_fact`，没有任何下载或网络访问；`--check` 干跑与 `--list-tasks` 可用。
镜像只在清单里以字符串出现，渲染阶段无需可达。

## 验证

```bash
make test-cilium     # 静态 + 渲染 + netns/VXLAN 真实内核数据面
```

详见 `tests/cilium/README.md`。

## 受限（必须阅读）

- **未运行 cilium-agent/operator**（无镜像）：`cilium status`、agent healthz、
  BPF maps 未验证。
- **Pod 网络未验证**：测试的跨 netns 连通性是**内核 VXLAN 隧道**，不是 Cilium
  Pod 网络；不验证 IPAM/Endpoint/策略/BPF。
- **`kubectl get nodes` Ready 未验证**（无真实节点注册）。
- 真机复验步骤见 `docs/harness/state/contracts/T010.md` §5.7。
