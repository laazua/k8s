# 部署与运维手册

本仓库用 Ansible 以**二进制方式**部署高可用 Kubernetes：CRI=containerd，CNI=Cilium，
控制面高可用，业务只调度到 worker，可加节点、可升级/回滚。

- 需求与架构：[`spec.md`](harness/state/spec.md)
- 全部可配置项（886 个默认变量，自动生成）：[`variables.md`](variables.md)
- 端到端验收：`make test-e2e-full`（见 [`tests/e2e/README.md`](../tests/e2e/README.md)）

## 前置条件

- 控制面 ≥3 台、etcd 奇数成员、worker ≥1 台；RedHat/Debian 家族（一级支持）。
- 所有节点：`ansible` 免密 SSH、`become` 可用、时间同步、主机名可解析。
- 控制面主机：已安装 `kubectl` 到 `/usr/local/bin/kubectl`（`taints`/升级使用）。
- 控制面主机：`keepalived`、`haproxy` 由 role 负责安装；发行版仓库需可达或已配代理。
- 制品：官方二进制 + **强制 sha256 校验**；可走代理或预置本地制品目录（见下文）。

```bash
# 在仓库根目录执行；确认 ansible 可用
make syntax
ansible --version
```

## 执行身份（ansible_user 与 become）

本仓库所有入口 playbook（`control-plane.yml`、`node.yml`、`add-node.yml`、`taints.yml`、`upgrade.yml`）
均在 play 级设置 `become: true`，以 `sudo` 切换到 root 执行需要特权的任务。
**推荐以普通用户免密 SSH + 免密 sudo（NOPASSWD）** 运维节点，不直接使用 root 账户：

```ini
# inventory/hosts.ini 示例
[k8s_cluster:vars]
ansible_user=zhangsan               # 以普通用户 SSH 登录
ansible_become_method=sudo          # 默认即为 sudo，可省略
```

如果节点尚未配置 `NOPASSWD`，部署时需加 `-K` 参数，Ansible 会交互询问 sudo 密码：

```bash
ansible-playbook -i inventory/hosts.ini playbooks/site.yml -K
```

也可通过变量 `ansible_become_password` 传入（不推荐明文写入 inventory，建议结合 ansible-vault）：

```bash
ansible-playbook -i inventory/hosts.ini playbooks/site.yml \
  -e ansible_become_password='your_sudo_pass'
```

> [!NOTE]
> `add-node.yml` 中的 `verify` 和 `validate` 任务通过 `delegate_to: "{{ add_node_verify_delegate }}"` 在控制节点上执行 kubectl，该任务**同样继承 play 级 become: true**，因此控制端也需要 sudo 权限（或配置 NOPASSWD）。

## inventory

从示例复制后按真实拓扑填写。`[k8s_master]` 是控制面，`[k8s_node]` 是业务节点，
`[etcd]` 默认与控制面同机（可独立）。

```bash
cp inventory/hosts.example inventory/hosts.ini
$EDITOR inventory/hosts.ini
```

```ini
[k8s_master]
k8s-master-01 ansible_host=10.0.0.11
k8s-master-02 ansible_host=10.0.0.12
k8s-master-03 ansible_host=10.0.0.13

[etcd]
k8s-master-01 ansible_host=10.0.0.11
k8s-master-02 ansible_host=10.0.0.12
k8s-master-03 ansible_host=10.0.0.13

[k8s_node]
k8s-node-01 ansible_host=10.0.0.21
```

## 可配置项

所有可调参数集中在 `group_vars/` 与各 role 的 `defaults/main.yml`；
**完整台账见自动生成的 [`docs/variables.md`](variables.md)**（`make test-e2e-full` 会校验文档与 defaults 不漂移）。
覆盖优先级：`-e` / host_vars > group_vars > role defaults。

常用覆盖项：

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `k8s_version` | Kubernetes 版本（只改这里） | `1.31.0` |
| `k8s_vip` | 控制面 VIP（keepalived/kube-vip） | `10.0.0.100` |
| `k8s_apiserver_port` | apiserver 端口 | `6443` |
| `k8s_service_cidr` | Service 网段 | `10.96.0.0/12` |
| `k8s_pod_cidr` | Pod 网段 | `10.244.0.0/16` |
| `k8s_artifact_dir` | 二进制制品缓存目录 | `/opt/k8s/artifacts` |
| `containerd_version` | containerd 版本 | `2.0.0` |
| `cilium_version` | Cilium 版本 | `1.16.3` |
| `upgrade_version` | `playbooks/upgrade.yml` 目标版本 | `{{ k8s_version }}` |

```bash
# 示例：改版本 / VIP / 网段
ansible-playbook -i inventory/hosts.ini playbooks/site.yml \
  -e k8s_version=1.32.13 -e k8s_vip=10.0.0.100 -e k8s_pod_cidr=10.244.0.0/16
```

## 代理

下载 role 统一读取 `proxy_env`（同时作用于 get_url / uri），不散落在任务里。
代理只影响下载，不影响 Ansible SSH。

```yaml
# group_vars/all/main.yml
proxy_env:
  http_proxy: "http://proxy.example.com:3128"
  https_proxy: "http://proxy.example.com:3128"
  no_proxy: "127.0.0.1,localhost,10.0.0.0/8"
```

```bash
# 临时走代理
ansible-playbook -i inventory/hosts.ini playbooks/site.yml \
  -e '{"proxy_env":{"http_proxy":"http://proxy:3128","https_proxy":"http://proxy:3128","no_proxy":"10.0.0.0/8"}}'
```

## 离线

优先用本地制品缓存：`download_cache_dir` 命中且 sha256 相符时**不发网络请求**。
支持 `file://` 本地源；生产离线环境把制品预置到 `k8s_artifact_dir` 即可。

```bash
# 1) 在有网机器预取制品（任选官方地址），落到 k8s_artifact_dir
# 2) 离线机器上确认缓存命中
ls -l /opt/k8s/artifacts

# 3) 用本地制品目录部署（各 role 复用同一缓存）
ansible-playbook -i inventory/hosts.ini playbooks/site.yml \
  -e k8s_artifact_dir=/opt/k8s/artifacts
```

> 离线必须固定 sha256（role 不接受“制品已存在”自证）；版本与 sha 表见各 role defaults。

## 部署

一条命令：`make deploy`（等价于对 `playbooks/site.yml` 执行 ansible-playbook）。
先控制面、再工作节点；重复执行幂等（changed=0）。

```bash
make deploy INVENTORY=inventory/hosts.ini
```

```bash
# 等价的手工命令（便于加 -e / --tags）
ansible-playbook -i inventory/hosts.ini playbooks/site.yml
ansible-playbook -i inventory/hosts.ini playbooks/site.yml --tags control-plane
ansible-playbook -i inventory/hosts.ini playbooks/site.yml --tags node
```

## 验证

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl -n kube-system get deploy,svc
```

```bash
# 仓库自带的冒烟（真机模式需要一个可用的 kubeconfig）
KUBECONFIG=/etc/kubernetes/admin.conf make smoke-e2e
```

## 调度约束

控制面默认带 `NoSchedule` 污点并打角色标签，业务只调度到 `[k8s_node]`。
重复执行 `changed=0`；`--check` 只读、不写 API。

```bash
ansible-playbook -i inventory/hosts.ini playbooks/taints.yml --tags taints
ansible-playbook -i inventory/hosts.ini playbooks/taints.yml --tags taints --check
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

## 加节点

把新节点加入 `[k8s_node]`，只对该节点执行 `playbooks/add-node.yml`：
只签本节点 kubelet 证书、**绝不重建 CA**、不重启既有节点；连跑第二次 changed=0。

```bash
# 1) 编辑 inventory，把新节点写进 [k8s_node]
# 2) 只对新节点执行（-l 限定目标）
ansible-playbook -i inventory/hosts.ini playbooks/add-node.yml -l k8s-node-02
# 3) 控制端读回注册结果
kubectl get node k8s-node-02
```

> 生产推荐 `-e add_node_cert_mode=preissued`（worker 不接触 CA 私钥）。

## 升级

相邻 minor 升级；升级前自动备份 etcd 快照、证书与二进制。
控制面 `serial: 1` 逐台升级，再升级工作节点。

```bash
# 升级到 1.32.13（控制面）
ansible-playbook -i inventory/hosts.ini playbooks/upgrade.yml \
  -e upgrade_version=1.32.13 --limit k8s_master
# 再升级工作节点
ansible-playbook -i inventory/hosts.ini playbooks/upgrade.yml \
  -e upgrade_version=1.32.13 --limit k8s_node
# 验证
kubectl get nodes -o wide
```

## 回滚

回滚与升级是同一 role，由 `upgrade_action=rollback` 分派；回滚使用升级前备份的
etcd 快照与二进制。多成员 etcd 必须显式声明成员身份与初始集群，否则拒绝执行：

- `upgrade_rollback_etcd_member_name`：本机 etcd 成员名（如 `etcd1`）
- `upgrade_rollback_etcd_initial_peer_url`：该成员 peer URL
- `upgrade_rollback_etcd_initial_cluster`：完整成员列表（`etcd1=https://…` 逗号分隔）
- `upgrade_rollback_etcd_data_dir`：数据目录（与控制面同机时要指向成员子目录）

```bash
ansible-playbook -i inventory/hosts.ini playbooks/upgrade.yml \
  -e upgrade_action=rollback -e upgrade_version=1.31.0 --limit k8s_master \
  -e upgrade_rollback_etcd_member_name=etcd1 \
  -e upgrade_rollback_etcd_initial_peer_url=https://10.0.0.11:2380 \
  -e upgrade_rollback_etcd_initial_cluster=etcd1=https://10.0.0.11:2380,etcd2=https://10.0.0.12:2380,etcd3=https://10.0.0.13:2380
```

## 已知限制

本仓库的验收在**单宿主**沙箱中真实执行（真实 etcd/apiserver/kubelet/containerd 进程，
但共用一台机器）；以下项目**未在本仓库 CI 中验证**，上真机前须补验：

- **单宿主**：全部测试用 `$SB` 前缀在一台机器上模拟多节点，未验证真实 **多节点** 网络拓扑、
  跨机 SSH 与 etcd 选主；真机请按上文 inventory 复跑 `make deploy` 后再验。
- **无镜像 / registry 不可达**：沙箱拉不到业务镜像，系统 Pod 与 Cilium/CoreDNS Pod
  不会 `Running`；只验证了清单可渲染、可 apply。真机需可达 registry 后复查。
- **多成员 etcd**：仓库只验证了单成员 TLS etcd；多成员回滚必须显式提供
  `upgrade_rollback_etcd_member_name` / `upgrade_rollback_etcd_initial_peer_url` /
  `upgrade_rollback_etcd_initial_cluster`，且未在真实 3 成员集群上执行过。
- **upgrade_manage_service=true 未验证**：沙箱无 systemd 启停，升级/回滚只验证了
  `upgrade_manage_service=false`；真机需确认服务重启顺序。
- **重启 kubelet**：加节点自愈（证书被替换后重签）需人工**重启 kubelet** 才生效；
  role 不主动重启，以免影响既有节点。
- **default callback**：`tests/upgrade` 的任务结果解析依赖 Ansible default callback；
  改用其它 callback（如 `yaml`）会让 `task_status` 解析失败，测试会显式报错。
- **磁盘 6G**：`make test-e2e-full` 运行前要求 `/tmp/opencode` 至少 **6G** 余量，
  否则前置守卫直接失败（避免磁盘写满造成假 FAIL）。
- **SIGKILL 清理**：沙箱不调用 `systemctl` 启停宿主服务，退出时只对本次启动的
  `$SB/usr/local/bin/*` 进程发送 **SIGKILL**，并只清理本次新建的 kubepods slice。
- **沙箱高位端口**：全流程测试占用 16443/12379/20250/20248/20251/20249/20257/20259，
  端口被占用时测试会前置失败，不静默降级。
