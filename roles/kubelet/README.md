# roles/kubelet

以**官方二进制 + systemd** 安装并配置 kubelet。kubelet **只消费** T004 `pki` 为节点签发的
证书（`CN=system:node:<node>`、`O=system:nodes`），并在落盘前强校验身份/链/私钥匹配。

## 变量（全部可在 `group_vars` / `host_vars` / `-e` 覆盖）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `kubelet_version` | `k8s_version`（1.31.0） | 与集群版本一致；`--version` 不符即失败 |
| `kubelet_known_sha256` / `kubelet_sha256` | 官方 1.31.0 sha256 | 强制 sha256（复用 `download` role） |
| `kubelet_download_url` | `dl.k8s.io` | 可换代理/本地镜像源 |
| `kubelet_root_prefix` | `""` | 沙箱前缀（仅测试）；生产留空 |
| `kubelet_bin_dir` / `kubelet_binary` | `k8s_bin_dir` | 安装目录 |
| `kubelet_pki_dir` / `kubelet_client_ca_file` | `k8s_config_dir/pki` | T004 PKI 产物 |
| `kubelet_client_cert_file` / `kubelet_client_key_file` | `pki/kubelet/<node>.crt|key` | 客户端/serving 证书 |
| `kubelet_root_dir` / `kubelet_cert_dir` | `/var/lib/kubelet`、`/var/lib/kubelet/pki` | 运行时目录 |
| `kubelet_config_path` / `kubelet_kubeconfig_path` | `<root>/config.yaml`、`<root>/kubelet.conf` | 配置/kubeconfig |
| `kubelet_kubeconfig_mode` | `0600` | kubeconfig 权限（root:root） |
| `kubelet_unit_dir` / `kubelet_unit_name` | `kube_systemd_dir` / `kubelet.service` | systemd unit |
| `kubelet_container_runtime_endpoint` | `unix:///run/containerd/containerd.sock` | 必须指向 containerd CRI socket |
| `kubelet_cgroup_driver` | `container_runtime_cgroup_driver`（`systemd`） | 与 containerd 交叉校验 |
| `kubelet_require_systemd_cgroup` | `true` | 非 systemd 直接失败 |
| `kubelet_apiserver_url` | `https://<k8s_vip>:<k8s_apiserver_port>` | kubeconfig server |
| `kubelet_node_ip` / `kubelet_hostname_override` | `ansible_host` / `inventory_hostname` | 节点身份 |
| `kubelet_address` / `kubelet_port` / `kubelet_healthz_port` | `0.0.0.0` / `10250` / `10248` | 监听（测试用高位端口） |
| `kubelet_read_only_port` | `0` | 关闭只读端口 |
| `kubelet_fail_swap_on` | `true` | 生产正确默认；测试显式 `false`（禁止 swapoff） |
| `kubelet_static_pod_path` | `""` | 为空则**不渲染**该字段 |
| `kubelet_anonymous_auth` | `false` | 安全默认 |
| `kubelet_authorization_mode` | `Webhook` | 安全默认 |
| `kubelet_manage_service` | `true` | 是否 `systemctl enable/start`（共享开发机测试必须 `false`） |
| `kubelet_service_enabled` / `kubelet_service_state` | `true` / `started` | 服务状态 |

## 任务流

`facts`（推导 `--config/--kubeconfig/--container-runtime-endpoint/--cgroup-driver/--root-dir/
--cert-dir/--hostname-override/...`）→ `validate`（cgroup、证书身份/链/私钥、CRI socket fail-fast）
→ `binary`（download + sha256 + 版本断言）→ `kubeconfig`（证书内嵌，0600）→ `config`
（KubeletConfiguration + unit）→ `service` → `verify`（产物/权限自检）。

## 验证方式

```bash
# 静态
ansible-playbook -i tests/node/inventory.ini --syntax-check tests/node/sandbox_kubelet.yml
yamllint -c .yamllint roles/kubelet

# 动态（沙箱：真实 containerd + 真实 kubelet + 真实控制面；宿主零污染）
tests/node/test_node_roles.sh

# 真机（写 /etc/systemd/system 并 enable/start；仅目标真机）
ansible-playbook -i inventory/hosts.ini tests/node/real_node.yml
systemctl is-active kubelet
kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
grep -E 'cgroupDriver|anonymous|mode:' /var/lib/kubelet/config.yaml
```

## 受限声明（spec R1 / 契约 §5）

- 共享开发机**禁止** `systemctl enable/start`、不写宿主 `/etc/systemd/system`、`/var/lib/kubelet`。
  测试把路径重定向到 `mktemp` 沙箱，并从渲染出的 unit 的 `ExecStart` 拉起**真实 kubelet**，
  用真实 apiserver 验证节点注册；systemd active/enabled 须按上文真机步骤复验。
- 节点 `Ready=True` 需要 CNI（T010）；本任务允许 `NotReady`（reason 记录在测试输出）。
- `kubelet.conf` 默认落在 `<root-dir>/kubelet.conf`（便于按节点重定向；真机可覆盖为
  `/etc/kubernetes/kubelet.conf`）。
- kube-apiserver 的 `--kubelet-certificate-authority` 未在本任务打开（见契约 §5.4）。
