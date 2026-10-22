# roles/keepalived

控制面 **VIP 层**：默认用 keepalived/VRRP 提供 apiserver VIP；`ha_mode=kube-vip`
时改为渲染 kube-vip 静态 Pod 清单（**仅配置渲染，真实漂移未验证**）。

## 行为（`ha_mode=keepalived`，默认）

1. `validate`：VIP、网卡、`virtual_router_id`（1-255）、priority（1-255）、
   `advert_int`、PASS 认证串（1-8）全部 fail-fast。
2. 渲染 `chk_haproxy.sh`（检查**本机** haproxy pid 文件）与 `notify.sh`
   （写 `state.log`）。
3. 渲染 `keepalived.conf` 到 **`/etc/keepalived/keepalived.conf`**
   （keepalived 服务默认读取的路径；可用 `keepalived_config_file` 覆盖）：
   - `vrrp_instance k8s_apiserver`
   - `state BACKUP`、`priority`（默认按 inventory 序号推导：`base - index*step`）
   - `virtual_router_id`、`interface`、`advert_int`、PASS 认证
   - `virtual_ipaddress { <k8s_vip>/32 }`
   - `track_script { chk_haproxy }`
   - `notify_master/backup/fault`
4. 渲染 systemd drop-in
   `/etc/systemd/system/keepalived.service.d/10-role-config.conf`：
   `ExecStart=... --dont-fork -f <keepalived_config_file>`，与渲染路径同源。
5. `keepalived_manage_service=true` 时 `daemon_reload` + enable/start；
   配置/脚本变化才 notify 重启。默认 **preempt**（高优先级恢复后回切）；
   `keepalived_nopreempt=true` 可关闭。

## 行为（`ha_mode=kube-vip`）

渲染 `kube-vip.yaml` **静态 Pod 清单**，包含：
`hostNetwork: true`、`priorityClassName: system-node-critical`、
`command: ["/kube-vip"]` + `args: ["manager"]`、
`vip_arp` / `vip_interface` / `vip_address` / `port` / `vip_leaderelection`、
`vip_nodename`（downward API）、`securityContext.capabilities`
（`NET_ADMIN`、`NET_RAW`）、以及 kubeconfig 的 hostPath 挂载
（默认 `/etc/kubernetes/admin.conf`，变量 `kube_vip_kubeconfig`）。

静态 Pod 使用该 kubeconfig 直连 apiserver，**不需要**额外 RBAC；若改用
DaemonSet 部署，需自行创建 ServiceAccount + ClusterRole(Binding)
（services/endpoints/nodes 读写）。role 不启动 keepalived。

真实 ARP 漂移、选主、镜像拉取**未在本任务验证**（见
`docs/harness/state/contracts/T006.md` §5），上真机前必须复验。

## 关键变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `ha_mode` | `k8s_ha_mode`（keepalived） | `keepalived` / `kube-vip` |
| `keepalived_vip` | `k8s_vip` | VIP 地址（必填） |
| `keepalived_interface` | `k8s_vip_interface` | VIP 所在网卡（必填） |
| `keepalived_virtual_router_id` | 51 | 同一 L2 唯一 |
| `keepalived_priority_base/step` | 150/10 | 按 inventory 顺序推导优先级 |
| `keepalived_priority` | 推导值 | host var 可显式覆盖（如 150/100） |
| `keepalived_state` | BACKUP | 初始状态 |
| `keepalived_nopreempt` | false | true = 不抢占 |
| `keepalived_advert_int` | 1 | VRRP 通告间隔（秒） |
| `keepalived_auth_pass` | `k8s-ha` | PASS 认证串（≤8） |
| `keepalived_haproxy_pid_file` | `/run/haproxy.pid` | track_script 检查对象 |
| `keepalived_config_file` | `/etc/keepalived/keepalived.conf` | 渲染路径 = unit 引用路径 |
| `keepalived_root_prefix` / `base_root_prefix` | 空 | 测试沙箱前缀 |
| `kube_vip_image` | `ghcr.io/kube-vip/kube-vip:v0.8.0` | kube-vip 镜像 |
| `kube_vip_kubeconfig` | `/etc/kubernetes/admin.conf` | 静态 Pod 挂载的 kubeconfig |
| `keepalived_manage_package/service` | true | 共享开发机测试置 false |

## 与 haproxy 配合

`track_script` 只检查本机 haproxy 是否存活（读 pid 文件）。haproxy 挂掉 →
本机进入 FAULT → VIP 漂移到仍有 haproxy 的 master，避免把流量导到坏节点。

```bash
ansible-playbook -i inventory/hosts.ini playbooks/control-plane.yml --tags keepalived
```

> 编排说明：`playbooks/control-plane.yml` 在 T007 完成前仍是占位 playbook，
> 上述命令会 exit 0 但不执行本 role；验证请用 `tests/ha/test_ha_role.sh`。
