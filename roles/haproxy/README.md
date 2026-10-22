# roles/haproxy

Kubernetes apiserver 前置 **TCP 负载均衡**（通常与 `roles/keepalived` 的 VIP 配合）。

## 行为

1. 从 inventory 分组 `k8s_master`（变量 `haproxy_master_group`）推导后端成员：
   `ansible_host` 作为后端地址、`haproxy_backend_port` 作为端口。
   也可用 `haproxy_backend_servers` 显式覆盖（`[{name, address, port}]`）。
2. 渲染 `haproxy.cfg` 到 **`/etc/haproxy/haproxy.cfg`**（发行版 unit 约定的
   `CONFIG` 路径；可用 `haproxy_config_file` 覆盖）：
   `mode tcp`、`balance roundrobin`、对每个成员 `server <host> <ip>:<port> check ...`、
   `timeout connect/client/server`。
3. 渲染 systemd drop-in
   `/etc/systemd/system/haproxy.service.d/10-role-config.conf`：显式把
   `ExecStart`/`ExecStartPre` 的 `-f` 指到**同一个** `haproxy_config_file`，
   不再依赖发行版 unit 的 `$CFGDIR`（避免加载包自带样例/额外文件）。
   **渲染路径 == unit 引用路径**，生产默认即 `/etc/haproxy/haproxy.cfg`。
4. 安装包（`haproxy_manage_package`，默认 true）并断言 `haproxy_binary` 可执行。
5. `haproxy_manage_service=true` 时 `daemon_reload` + enable/start；配置内容变化才 notify 重启。

## 关键变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `haproxy_master_group` | `k8s_master` | 后端成员来源（唯一事实来源） |
| `haproxy_lb_port` | `k8s_apiserver_port`（6443） | 客户端访问端口（VIP:端口） |
| `haproxy_backend_port` | `k8s_apiserver_port`（6443） | 真实 apiserver 监听端口 |
| `haproxy_bind_address` | `k8s_lb_bind_address`（0.0.0.0） | 前端监听地址 |
| `haproxy_balance` | `roundrobin` | 负载均衡算法 |
| `haproxy_check_inter/fall/rise` | `2s/3/2` | 健康检查参数 |
| `haproxy_timeout_connect/client/server` | `5s/1h/1h` | 超时 |
| `haproxy_config_file` | `/etc/haproxy/haproxy.cfg` | 渲染路径 = unit 引用路径 |
| `haproxy_root_prefix` / `base_root_prefix` | 空 | 测试沙箱前缀（生产留空） |
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

> 编排说明：`playbooks/control-plane.yml` 在 T007 完成前仍是占位 playbook，
> 上述命令会 exit 0 但不执行本 role；验证请用 `tests/ha/test_ha_role.sh`。
