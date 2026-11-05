# roles/kube-proxy

在每个 **node** 上以**官方二进制 + systemd** 运行 `kube-proxy`，使 `Service` 的
`ClusterIP` 可被真实访问（spec A9）。

## 方案选择（契约 §1.1）

**二进制 + systemd；不使用 DaemonSet。** 理由：

1. 当前环境容器 registry 不可达 → kube-proxy 镜像无法拉取，DaemonSet 无法真实运行；
2. 二进制方案可真实拉起进程，并在 netns 内用真实 apiserver + 真实 iptables 规则
   完成 ClusterIP 验收（符合 spec C13「验收必须可执行」）；
3. 与项目「二进制部署」总目标及 T008 的 containerd/kubelet 交付形态一致。

DaemonSet 渲染分支**未交付**（如后续需要，另立任务并声明「未真实运行」）。

## 变量（`defaults/main.yml`，全部可覆盖）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `kube_proxy_version` | `{{ k8s_version }}` | 版本；sha256 由 `kube_proxy_known_sha256` 固定 |
| `kube_proxy_root_prefix` | `""` | 沙箱前缀（测试用）；生产留空 |
| `kube_proxy_proxy_mode` | `iptables` | 仅 `iptables` / `ipvs`；其它值 fail-fast |
| `kube_proxy_cluster_cidr` | `{{ k8s_pod_cidr }}` | **Pod CIDR**（`detectLocalMode=ClusterCIDR`）；缺失/非法 fail-fast |
| `kube_proxy_bind_address` | `0.0.0.0` | kube-proxy 认为的节点主 IP（不真正 bind） |
| `kube_proxy_healthz_bind_address` | `127.0.0.1:10256` | healthz 监听（安全默认） |
| `kube_proxy_metrics_bind_address` | `127.0.0.1:10249` | metrics 监听（安全默认） |
| `kube_proxy_hostname_override` | `{{ inventory_hostname }}` | 必须与 Node 对象同名 |
| `kube_proxy_detect_local_mode` | `ClusterCIDR` | 1.31 不支持 `Cluster` |
| `kube_proxy_conntrack_*` | `0` / `24h` / `1h` | `0` = 保持系统现值（不改全局限制） |
| `kube_proxy_iptables_*` | `syncPeriod=30s` 等 | iptables 参数 |
| `kube_proxy_ipvs_*` | `rr` 等 | 仅 `proxy_mode=ipvs` 时渲染 |
| `kube_proxy_kubeconfig_source_mode` | `source` | `source` 复制既有 kubeconfig / `embedded` 由 CA/cert/key 渲染 |
| `kube_proxy_kubeconfig_source` | `{{ kube_proxy_config_dir }}/admin.conf` | source 模式的来源 |
| `kube_proxy_kubeconfig_mode` | `0600` | kubeconfig 权限 |
| `kube_proxy_manage_service` | `true` | `false` 时不调用 systemctl（沙箱/共享机） |
| `kube_proxy_iptables_binary` | `iptables` | 依赖探测（缺失 fail-fast） |
| `kube_proxy_ipvs_proc_path` | `/proc/net/ip_vs` | ipvs 模式前置（未加载 fail-fast） |

## 落盘

```
{{ kube_proxy_bin_dir }}/kube-proxy                        # 0755 root:root
{{ kube_proxy_config_path }}                               # KubeProxyConfiguration 0644
{{ kube_proxy_kubeconfig_path }}                           # 0600 root:root
{{ kube_proxy_unit_path }}                                 # kube-proxy.service 0644
```

## 验证方式

- `make test-kube-proxy`：静态（结构/变量化/模板/接线/安全默认/语法/风格）+
  动态（`sudo unshare -n` 独立 netns 内**真实** pki + etcd + kube-apiserver +
  kube-proxy；创建 Node/Service/EndpointSlice，后端为本地 mock HTTP，
  实测 `curl http://<ClusterIP>:80` 返回已知响应；后端故障/EndpointSlice 移除的
  边界；幂等 `changed=0`；fail-fast 矩阵；密闭性；宿主零污染）。
- 真机复验：`tests/kube-proxy/real_kube_proxy.yml`（见契约 §5.5）。

## 受限说明（详见 `docs/harness/state/contracts/T009.md` §5）

- 共享开发机**不写**宿主 `/etc/systemd/system`、不 `systemctl enable/start`：
  unit 只渲染到沙箱并断言，随后**用其 `ExecStart` 真实拉起进程**；真机步骤见契约。
- **未使用容器镜像 / 未运行 Pod**（registry 不可达）：ClusterIP 后端是 netns 内
  本地 mock HTTP（`10.0.0.10:18080`），证明 kube-proxy 的 Service→Endpoint DNAT
  数据面，不证明 Pod 网络/CNI（T010）。
- 单机 netns ≠ 多节点集群：「kube-proxy 在全部 node 运行」由 role 的 hosts 范围 +
  systemd enabled 保证；动态部分只证明单实例真实运行。
- 默认 kubeconfig 使用 T007 的 `admin.conf`（引导凭据）；专用 `system:kube-proxy`
  凭据属 T011。
- `ipvs` 分支已完整渲染，但本环境 `ip_vs` 未加载 → 只做 fail-fast 断言，未动态验证。
