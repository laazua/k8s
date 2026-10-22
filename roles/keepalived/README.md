# roles/keepalived

控制面 **VIP 层**：默认用 keepalived/VRRP 提供 apiserver VIP；`ha_mode=kube-vip`
时改为渲染 kube-vip 静态 Pod 清单（**仅配置渲染，真实漂移未验证**）。

## 行为（`ha_mode=keepalived`，默认）

1. `validate`：VIP、网卡、`virtual_router_id`（1-255）、priority（1-255）、
   `advert_int`、PASS 认证串（1-8）全部 fail-fast。
2. 渲染 `chk_haproxy.sh`（检查**本机** haproxy pid 文件）与 `notify.sh`
   （写 `state.log`）。
3. 渲染 `keepalived.conf`：
   - `vrrp_instance k8s_apiserver`
   - `state BACKUP`、`priority`（默认按 inventory 序号推导：`base - index*step`）
   - `virtual_router_id`、`interface`、`advert_int`、PASS 认证
   - `virtual_ipaddress { <k8s_vip>/32 }`
   - `track_script { chk_haproxy }`
   - `notify_master/backup/fault`
4. `keepalived_manage_service=true` 时 enable/start；配置/脚本变化才 notify 重启。
   默认 **preempt**（高优先级恢复后回切）；`keepalived_nopreempt=true` 可关闭。

## 行为（`ha_mode=kube-vip`）

渲染 `kube-vip.yaml` 静态 Pod 清单（`vip_arp`、`vip_interface`、`port`、
`vip_leaderelection` 等），并做同样的 VIP/网卡/镜像前置校验；**不启动 keepalived**。
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
| `keepalived_root_prefix` | 空 | 测试沙箱前缀 |
| `kube_vip_image` | `ghcr.io/kube-vip/kube-vip:v0.8.0` | kube-vip 镜像 |
| `keepalived_manage_package/service` | true | 共享开发机测试置 false |

## 与 haproxy 配合

`track_script` 只检查本机 haproxy 是否存活（读 pid 文件）。haproxy 挂掉 →
本机进入 FAULT → VIP 漂移到仍有 haproxy 的 master，避免把流量导到坏节点。

```bash
ansible-playbook -i inventory/hosts.ini playbooks/control-plane.yml --tags keepalived
```
