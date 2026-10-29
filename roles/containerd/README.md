# roles/containerd

以**官方二进制 + systemd** 安装并配置 containerd（CRI），同时安装 `runc`、官方
`CNI plugins`（bridge/host-local/loopback/portmap/tuning）与 `crictl`（可选）。
不使用发行版包管理器，不拉取任何容器镜像。

## 变量（全部可在 `group_vars` / `host_vars` / `-e` 覆盖）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `containerd_version` | `2.0.0` | containerd 版本；`>= 2.0.0` 用 config `version = 3`，1.x 用 `version = 2` |
| `containerd_known_sha256` / `containerd_sha256` | 官方 2.0.0 sha256 | 强制 sha256（复用 `download` role；离线/缓存可复现） |
| `containerd_download_url` | GitHub releases | 可换代理/本地镜像源 |
| `runc_version` / `runc_download_url` / `runc_sha256` | `1.2.1` | CRI runtime 依赖 |
| `cni_plugins_version` / `cni_plugins_download_url` / `cni_plugins_sha256` | `1.5.1` | 官方 CNI plugins |
| `crictl_version` / `crictl_download_url` / `crictl_sha256` | `1.31.1` | CRI 自检工具 |
| `containerd_root_prefix` | `""` | 沙箱前缀（仅测试）；生产留空 |
| `containerd_artifact_dir` / `containerd_bin_dir` | `k8s_artifact_dir` / `k8s_bin_dir` | 制品缓存与安装目录 |
| `containerd_config_dir` / `containerd_config_path` | `/etc/containerd` | 配置目录/文件 |
| `containerd_root_dir` / `containerd_state_dir` / `containerd_socket` | `/var/lib/containerd` / `/run/containerd` | 运行时数据/状态/socket |
| `containerd_cni_bin_dir` / `containerd_cni_conf_dir` | `/opt/cni/bin` / `/etc/cni/net.d` | CNI 目录 |
| `containerd_sandbox_image` | `registry.k8s.io/pause:3.10` | pause 镜像（仅配置，不拉取） |
| `containerd_cgroup_driver` / `containerd_systemd_cgroup` | `container_runtime_cgroup_driver`（`systemd`） | 与 kubelet 单一来源；不一致 fail-fast |
| `containerd_unit_dir` / `containerd_unit_name` | `kube_systemd_dir` / `containerd.service` | systemd unit |
| `containerd_manage_service` | `true` | 是否 `systemctl enable/start`（共享开发机测试必须 `false`） |
| `containerd_service_enabled` / `containerd_service_state` | `true` / `started` | 服务状态 |
| `containerd_install_runc` / `containerd_require_runc` | `true` | 关闭安装时必须已存在，否则 fail-fast |
| `containerd_install_cni_plugins` / `containerd_require_cni_plugins` | `true` | 同上 |
| `containerd_install_crictl` | `true` | 仅运维工具 |
| `containerd_verify_endpoint` | `= containerd_manage_service` | 启动后等待 socket 并执行 `crictl info` |

## 任务流

`facts`（推导 ExecStart）→ `validate`（cgroup/哈希/runc/CNI fail-fast）→ `binary`
（download + sha256 + 解包 + 版本断言）→ `runc` → `cni` → `crictl` → `config`
（`config.toml` + unit）→ `service`（systemd）→ `verify`（可选 CRI 自检）。

## 验证方式

```bash
# 静态
ansible-playbook -i tests/node/inventory.ini --syntax-check tests/node/sandbox_containerd.yml
yamllint -c .yamllint roles/containerd

# 动态（沙箱：真实进程 + 宿主零污染）
tests/node/test_node_roles.sh
# 或只跑 role 级沙箱渲染（不调用 systemctl）
ansible-playbook -i tests/node/inventory.ini tests/node/sandbox_containerd.yml -e sandbox_root=/tmp/sb

# 真机（写 /etc/systemd/system 并 enable/start；仅目标真机）
ansible-playbook -i inventory/hosts.ini tests/node/real_node.yml
systemctl is-active containerd
crictl --runtime-endpoint unix:///run/containerd/containerd.sock info | grep -E 'runtimeName|SystemdCgroup'
```

## 受限声明（spec R1 / 契约 §5）

- 共享开发机**禁止** `systemctl enable/start`、不写宿主 `/etc/systemd/system`、`/etc/containerd`、
  `/var/lib/containerd`、`/run/containerd`。测试把上述路径整体重定向到 `mktemp` 沙箱，并
  **直接用渲染出的 unit 的 `ExecStart` 拉起真实 containerd**，再用 `crictl info/version` 验证
  CRI 端点、版本与 `SystemdCgroup`；systemd 的 active/enabled 语义须按上文真机步骤复验。
- docker registry 不可达：不拉取 pause/业务镜像；`crictl ps`/Pod 生命周期属 T010/T011。
- `containerd_verify_endpoint` 在生产默认开启（CRI 不可用即失败）；沙箱测试关闭，由测试脚本自检。
