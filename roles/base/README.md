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

仅落盘、不产生主机副作用（演练/验证；**直接复用测试沙箱 playbook**，不依赖是否已接入 playbook）：

```bash
SB="$(mktemp -d)"
ansible-playbook -i localhost, -c local tests/base/sandbox.yml \
  -e "sandbox_root=$SB" --skip-tags base:system
# 产物在 $SB/etc/{sysctl.d,modules-load.d,hosts}；若 $SB/etc/fstab 存在则其中 swap 行会被注释
# 用后清理：rm -rf "$SB"
```

> 该 playbook 会把 `base_root_prefix` 指向 `$SB`，并跳过所有 `base:system` 主机级任务。
> 若要在真实节点执行，请先按上面的 `roles: [base]` 示例接入 playbook，再按需 `--tags base:files` 分步运行。

## 关键变量

见 `defaults/main.yml`。生产环境应在 `group_vars/` 覆盖，勿改 role 默认值：

- `base_kernel_modules`、`base_sysctl`：内核模块与参数表。
- `base_hosts_entries`：`[{ ip: "...", names: "..." }]`，写入 hosts 受管块。
- `base_disable_swap`、`base_ntp_enabled`、`base_timezone`。
- `base_ntp_service`：时间同步服务名，默认按 `ansible_os_family` 求值
  （RedHat → `chronyd`，Debian/Ubuntu → `chrony`）；可在 `group_vars`/`host_vars`/`-e` 中覆盖。
- `base_manage_firewall`、`base_selinux_state`。
- `base_root_prefix`：**仅供测试**（空 = 真实系统路径）。

## 测试

```bash
tests/base/test_base_role.sh   # 沙箱前缀 + 真实执行 + 幂等复跑 + 接线断言
```

> 局限：开发机 PID1 为 systemd 且免密 sudo 可用，但它是**共享开发机**——
> 禁止执行 `swapoff` / `sysctl --system` / 改主机名 / 改时区 / 启停服务等破坏性主机级变更；
> 也无可用容器、制品仓库不可达，无法做多发行版真机验证。因此
> 「模块真实加载、sysctl 真实生效、swapoff 真实执行、主机名/时区真实变更、chrony 服务启用、
> firewalld/SELinux 真实状态」**无法在此真实验证**，仅以 `--list-tasks --tags base:system`
> 断言其已接线，并以跨发行版变量求值断言覆盖 `chronyd`/`chrony` 服务名差异；
> 需在具备真机/VM 的环境复验。
