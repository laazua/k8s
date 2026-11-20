# roles/upgrade — 版本升级与回滚

以**官方二进制 + 强制 sha256** 的方式把一个已部署集群从当前版本升级到相邻 minor，
并在升级前**自动备份** etcd 快照 / 证书 / kubeconfig / 旧二进制；回滚复用同一 role。

真实入口（唯一命令）：[`playbooks/upgrade.yml`](../../playbooks/upgrade.yml)。

## 做什么

| 阶段 | 文件 | 内容 |
| --- | --- | --- |
| validate | `tasks/validate.yml` | 动作合法、版本格式 `X.Y.Z`、相邻 minor、不降级、备份保留数裁剪、计算 `upgrade_needed` |
| backup | `tasks/backup.yml` | `etcdctl snapshot save` + PKI 树 + kubeconfig + 旧二进制 + `MANIFEST.txt` + `SHA256SUMS`（失败即中止） |
| binaries | `tasks/binaries.yml` | 复用 `download` role（缓存/代理/sha256）→ sha256 断言 → `--version` 断言 → 安装（内容不变 `changed=0`） |
| verify | `tasks/verify.yml` | 各组件 `--version`、集群 `/version`、节点仍注册 + Ready 判定 |
| rollback | `tasks/rollback_validate.yml` + `tasks/rollback.yml` | 备份完整性（`sha256sum -c`）→ `etcdctl snapshot restore` + 数据目录换入 → 旧二进制/证书回装 |

## 用法

```bash
# 干跑（不落盘）
ansible-playbook -i inventory/hosts.yml playbooks/upgrade.yml -e k8s_version=1.32.13 --check

# 升级（控制面 serial: 1 → 工作节点 serial: 1）
ansible-playbook -i inventory/hosts.yml playbooks/upgrade.yml -e k8s_version=1.32.13

# 幂等复跑（已在目标版本 → changed=0，不重复备份、不重启）
ansible-playbook -i inventory/hosts.yml playbooks/upgrade.yml -e k8s_version=1.32.13

# 回滚（显式动作 + 显式备份目录）
ansible-playbook -i inventory/hosts.yml playbooks/upgrade.yml \
  -e upgrade_action=rollback \
  -e upgrade_rollback_dir=/var/backups/kubernetes/upgrade/<时间戳>-<主机名>
```

## 关键变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `upgrade_action` | `upgrade` | `upgrade` 或 `rollback` |
| `upgrade_version` | `{{ k8s_version }}` | 目标版本（`X.Y.Z`，无 `v` 前缀） |
| `upgrade_allow_minor_jump` | `false` | 允许跨多个 minor（默认拒绝） |
| `upgrade_allow_downgrade` | `false` | 允许降级（默认拒绝） |
| `upgrade_control_plane_components` | `[kube-apiserver, kube-controller-manager, kube-scheduler, kubectl]` | 控制面组件 |
| `upgrade_node_components` | `[kubelet, kube-proxy]` | 节点组件 |
| `upgrade_backup_root` | `/var/backups/kubernetes/upgrade` | 备份根目录 |
| `upgrade_backup_retention` | `5` | 保留的备份目录数（按时间戳裁剪） |
| `upgrade_backup_etcd` / `upgrade_backup_pki` | `true` | 是否备份 etcd 快照 / PKI |
| `upgrade_etcdctl` / `upgrade_etcd_endpoints` | `/usr/local/bin/etcdctl` / `["https://127.0.0.1:2379"]` | etcd 快照连接 |
| `upgrade_etcd_ca_file` / `_cert_file` / `_key_file` | PKI 下的 etcd CA / apiserver-etcd-client | 快照鉴权 |
| `upgrade_manage_service` | `true` | 是否由 role 重启 systemd 服务（沙箱置 `false`） |
| `upgrade_verify_cluster_version` | `true` | 是否在 role 内交叉校验集群 `/version` |
| `upgrade_require_ready_nodes` | `true` | 严格 Ready；`false` 时要求 Ready 条件存在且 NotReady 有 reason |
| `upgrade_known_sha256` | 1.31.0 / 1.32.13 官方值 | 官方 sha256 固定表；新版本必须显式补充 |
| `upgrade_rollback_dir` | `""` | 回滚用的备份目录（必填） |
| `upgrade_rollback_etcd_offline_ack` | `false` | 确认 etcd 已停止（沙箱必须显式置 `true`） |
| `upgrade_rollback_etcd_data_dir` | `/var/lib/etcd` | 回滚换入的 etcd 数据目录（per-host 布局填 `<data_dir>/<member>`） |
| `upgrade_rollback_etcd_member_name` | `default` | 恢复时的成员名（须与数据目录成员一致） |
| `upgrade_rollback_etcd_initial_peer_url` | `http://localhost:2380` | 恢复后的 peer URL（多成员/TLS 集群必须覆盖） |

> **多成员对齐**：`roles/etcd` 用 `etcd_member_name: "{{ inventory_hostname }}"` + TLS peer，
> 因此多成员回滚必须显式覆盖
> `-e upgrade_rollback_etcd_member_name=<inventory_hostname>`
> `-e upgrade_rollback_etcd_initial_peer_url=https://<peer_ip>:2380`（以及 `upgrade_rollback_etcd_initial_cluster`）。
> 单成员默认值（`default` / `http://localhost:2380`）只在单机沙箱成立。

## 语义与安全

1. **备份是硬前置**：`backup.yml` 的任一断言（快照非空、`SHA256SUMS` 自校验、文件数）失败即中止，
   `binaries.yml` 不会执行。
2. **版本判定以本机二进制为准**：`upgrade_version_probe_component`（控制面 `kube-apiserver`、节点 `kubelet`）
   的 `--version` 与集群 `/version` 都等于目标才短路（`changed=0`）。
3. **回滚是真恢复**：`etcdctl snapshot restore` → 校验 `member/snap/db` → 旧数据目录改名
   `<data_dir>.pre-rollback-<ts>` → 恢复目录换入；不删除旧数据。
4. **回滚前强校验备份**：`MANIFEST.txt` + `SHA256SUMS` 必须存在，`sha256sum -c` 必须通过（篡改即拒绝）。
5. **不硬编码版本/路径**：版本与 sha256 只在 `defaults` 的固定表里；tasks 全部变量化。

## 测试

`make test-upgrade` → [`tests/upgrade/test_upgrade_flow.sh`](../../tests/upgrade/test_upgrade_flow.sh)（单宿主沙箱真实执行）。
