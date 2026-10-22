# roles/haproxy

Kubernetes apiserver 前置 **TCP 负载均衡**（通常与 `roles/keepalived` 的 VIP 配合）。

## 行为

1. 从 inventory 分组 `k8s_master`（变量 `haproxy_master_group`）推导后端成员：
   `ansible_host:ansible_host`，端口 `haproxy_backend_port`。
   也可用 `haproxy_backend_servers` 显式覆盖（`[{name, address, port}]`）。
2. 渲染 `haproxy.cfg` 到 `haproxy_config_dir`（默认 `/etc/kubernetes/haproxy`）：
   `mode tcp`、`balance roundrobin`、对每个成员 `server <host> <ip>:<port> check ...`、
   `timeout connect/client/server`。
3. 安装包（`haproxy_manage_package`，默认 true）并断言 `haproxy_binary` 可执行。
4. `haproxy_manage_service=true` 时 enable/start；配置内容变化才 notify 重启。

## 关键变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `haproxy_master_group` | `k8s_master` | 后端成员来源（唯一事实来源） |
| `haproxy_lb_port` | `k8s_apiserver_port`（6443） | 客户端访问端口（VIP:端口） |
| `haproxy_backend_port` | `k8s_apiserver_port`（6443） | 真实 apiserver 监听端口 |
| `haproxy_bind_address` | `0.0.0.0` | 前端监听地址 |
| `haproxy_balance` | `roundrobin` | 负载均衡算法 |
| `haproxy_check_inter/fall/rise` | `2s/3/2` | 健康检查参数 |
| `haproxy_timeout_connect/client/server` | `5s/1h/1h` | 超时 |
| `haproxy_root_prefix` | 空 | 测试沙箱前缀（生产留空） |
| `haproxy_manage_package/service` | true | 共享开发机测试置 false |

## 同机部署注意

若 haproxy 与 kube-apiserver 部署在同一主机，两者不能同时绑定同一地址的 6443。
常见做法（由后续 T007 落实其一）：
- kube-apiserver 只监听 `127.0.0.1:6443`，haproxy 监听 `0.0.0.0:6443`；或
- haproxy 使用独立端口，客户端统一通过 `VIP:<haproxy_lb_port>` 访问。

本 role 不改变 apiserver 的监听参数；`haproxy_lb_port` / `haproxy_backend_port`
已分离，便于按实际拓扑配置。

```bash
ansible-playbook -i inventory/hosts.ini playbooks/control-plane.yml --tags haproxy
```
