# role: base — Kubernetes 主机准备

为集群所有节点（master / node）做基础准备，**按 `ansible_os_family` 同时支持 RedHat 与 Debian 系**。

## 做什么

| 关注点 | 作用 | tag |
| --- | --- | --- |
| 内核模块 | 下发 `/etc/modules-load.d/99-kubernetes.conf`（`overlay`、`br_netfilter`）并加载 | `base:files` / `base:system` |
| sysctl | 下发 `/etc/sysctl.d/99-kubernetes.conf`（`ip_forward`、`bridge-nf-call-*`）并 `sysctl --system` 生效 | `base:files` / `base:system` |
| swap | 注释 `/etc/fstab` 中 swap 行 + `swapoff -a` | `base:files` / `base:system` |
| hosts | 以受管块方式维护集群节点解析 | `base:files:hosts` |
| hostname | 设为 `inventory_hostname` | `base:system:hostname` |
| 时间同步 | 安装并启用 `chrony`，设置时区 | `base:system:ntp` `base:system:timezone` |
| 安全基线 | 可选关闭 `firewalld`、设置 SELinux 状态 | `base:system:firewall` `base:system:selinux` |

## 用法

```yaml
# playbooks/*.yml
- hosts: k8s_cluster
  become: true
  roles:
    - base
```

仅落盘、不产生主机副作用（可用于演练/验证）：

```bash
ansible-playbook -i inventory/hosts.ini playbooks/site.yml --tags base:files
```

## 关键变量

见 `defaults/main.yml`。生产环境应在 `group_vars/` 覆盖，勿改 role 默认值：

- `base_kernel_modules`、`base_sysctl`：内核模块与参数表。
- `base_hosts_entries`：`[{ ip: "...", names: "..." }]`，写入 hosts 受管块。
- `base_disable_swap`、`base_ntp_enabled`、`base_timezone`。
- `base_manage_firewall`、`base_selinux_state`。
- `base_root_prefix`：**仅供测试**（空 = 真实系统路径）。

## 测试

```bash
tests/base/test_base_role.sh   # 沙箱前缀 + 真实执行 + 幂等复跑 + 接线断言
```

> 局限：本开发环境无 systemd / 无可用容器，因此「模块真实加载、sysctl 真实生效、swapoff 真实执行、
> 主机名/时区真实变更、chrony 服务启用、firewalld/SELinux 真实状态」**无法在此真实验证**，
> 仅以 `--list-tasks --tags base:system` 断言其已接线；需在具备真机/VM 的环境复验。
