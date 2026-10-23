# role · kube-scheduler

用**官方二进制 + systemd** 部署 Kubernetes Scheduler。

## 职责

1. 下载并安装 `kube-scheduler`（强制 sha256，支持代理/离线缓存），校验版本一致。
2. 渲染 systemd unit：`--kubeconfig` + delegated `--authentication-kubeconfig` /
   `--authorization-kubeconfig`、client CA/requestheader、leader election、安全端口
   （默认 `127.0.0.1:10259` 绑定）。
3. **只消费不签发**：`scheduler.conf`（`CN=system:kube-scheduler`）由 `kube-apiserver`
   role 生成；缺失即 fail-fast。
4. fail-fast：kubeconfig/CA 缺失、端口非法或被其它进程占用。

## 目录与文件

| 路径 | 说明 |
| --- | --- |
| `tasks/facts.yml` | 参数推导（flag 列表） |
| `tasks/validate.yml` | 依赖文件 + 端口校验（只读） |
| `tasks/binary.yml` | 制品/sha256/版本/安装 |
| `tasks/config.yml` | 渲染 systemd unit |
| `tasks/service.yml` / `handlers/main.yml` | `systemd` 启用/启动/重启（生产） |
| `templates/kube-scheduler.service.j2` | unit 模板 |

## 关键变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `kube_scheduler_version` | `k8s_version` | 版本；默认固定 1.31.0 官方 sha256 |
| `kube_scheduler_sha256` | 已知版本映射 | 换版本可显式固定或留空读官方侧车 |
| `kube_scheduler_kubeconfig` | `<config_dir>/scheduler.conf` | 客户端身份（apiserver role 生成） |
| `kube_scheduler_bind_address` | `127.0.0.1` | 安全端口绑定地址 |
| `kube_scheduler_secure_port` | `10259` | 安全端口（可覆盖） |
| `kube_scheduler_leader_elect` | `true` | leader election（内置 ClusterRole 已可授权） |
| `kube_scheduler_profiling` | `false` | 关闭 pprof |
| `kube_scheduler_manage_service` | `true` | 沙箱/共享机置 `false` |
| `kube_scheduler_root_prefix` | `""` | 沙箱前缀（测试用） |

## 验证方式

```bash
ansible-playbook -i inventory/hosts.example --syntax-check playbooks/control-plane.yml
yamllint -c .yamllint roles/kube-scheduler
tests/control-plane/test_control_plane_roles.sh     # 真实 apiserver 上验证 leader election
make test-control-plane

# 真机
ansible-playbook -i inventory/hosts.ini playbooks/control-plane.yml --tags kube-scheduler
systemctl is-enabled kube-scheduler && systemctl is-active kube-scheduler
journalctl -u kube-scheduler -n 50 | grep -i 'acquired lease'
```
