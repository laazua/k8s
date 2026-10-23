# role · kube-apiserver

用**官方二进制 + systemd**（非 kubeadm、非容器）部署 Kubernetes API Server，并提供控制面
客户端凭据引导（kubeconfig）。

## 职责

1. 下载并安装 `kube-apiserver`（强制 sha256，支持代理/离线缓存），校验实际版本与声明一致。
2. 渲染安全默认的 systemd unit：`--anonymous-auth=false`、`--authorization-mode=RBAC,Node`、
   TLS 双向客户端 CA、ServiceAccount 签名密钥、NodeRestriction 准入等。
3. **控制面引导**（T004 README 划归 T007）：用 kubernetes-ca 签发
   `system:kube-controller-manager`、`system:kube-scheduler`、`apiserver-kubelet-client`
   三张客户端证书，并渲染 `admin.conf` / `controller-manager.conf` / `scheduler.conf`
   （证书/私钥 base64 内嵌，文件 0600 root:root）。
4. fail-fast：地址/端口非法、安全默认被关闭、etcd endpoint 为空、PKI/SA 文件缺失、
   sha256 非固定但制品已存在、`secure-port` 被其它进程占用、版本不匹配。

## 目录与文件

| 路径 | 说明 |
| --- | --- |
| `tasks/facts.yml` | 唯一参数推导处：etcd endpoint 列表 + 完整 flag 列表（无副作用） |
| `tasks/validate.yml` | 只读前置校验（任何失败都不改动 unit） |
| `tasks/binary.yml` | 官方制品 + sha256 + 版本断言 + 安装 |
| `tasks/client_cert.yml` | 单张客户端证书签发（幂等、自愈、原子） |
| `tasks/kubeconfigs.yml` / `kubeconfig_one.yml` | 三份 kubeconfig 渲染 |
| `tasks/config.yml` | 渲染 systemd unit |
| `tasks/service.yml` / `handlers/main.yml` | `systemd` 启用/启动/重启（生产） |
| `templates/kube-apiserver.service.j2` | unit 模板 |
| `templates/kubeconfig_file.j2` | kubeconfig 模板（文件名不含 `kubeconfig.` 前缀，避免被 `.gitignore` 的 `kubeconfig.*` 吞掉） |

## 关键变量（全部可在 `group_vars`/`host_vars` 覆盖）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `kube_apiserver_version` | `k8s_version`（1.31.0） | 版本；默认固定该版本官方 sha256 |
| `kube_apiserver_sha256` | 已知版本映射 | 换版本可显式固定；留空且制品缺失时读官方 `.sha256` 侧车 |
| `kube_apiserver_download_url_base` | `https://dl.k8s.io` | 支持代理/镜像 |
| `kube_apiserver_bind_address` / `kube_apiserver_secure_port` | `0.0.0.0` / `6443` | 监听地址/端口 |
| `kube_apiserver_advertise_address` | `ansible_host` | 对外通告地址（推导不到即失败） |
| `kube_apiserver_etcd_servers` / `kube_apiserver_etcd_group` | `[]` / `etcd` | etcd endpoint：显式列表优先，否则由 inventory 分组推导 |
| `kube_apiserver_kubeconfig_server` | `https://<k8s_vip>:<k8s_apiserver_port>` | kubeconfig server（HA 走 VIP，可覆盖） |
| `kube_apiserver_authorization_mode` | `RBAC,Node` | 授权模式（必须含 RBAC） |
| `kube_apiserver_anonymous_auth` | `false` | 关闭匿名认证 |
| `kube_apiserver_manage_kubeconfigs` | `true` | 是否签发客户端证书/渲染 kubeconfig |
| `kube_apiserver_manage_service` | `true` | 是否调用 `systemd`（沙箱/共享机置 `false`） |
| `kube_apiserver_root_prefix` | `""` | 沙箱前缀（测试用；生产留空） |

其余路径/flag 均成对提供变量（`kube_apiserver_pki_dir`、`kube_apiserver_front_proxy_ca_file`、
`kube_apiserver_enable_admission_plugins`、`kube_apiserver_extra_args` 等）。

## 验证方式

```bash
# 静态（语法 + 风格）
ansible-playbook -i inventory/hosts.example --syntax-check playbooks/control-plane.yml
yamllint -c .yamllint roles/kube-apiserver

# 本任务验收（真实 etcd + 三进程，高位端口，宿主零污染）
tests/control-plane/test_control_plane_roles.sh
make test-control-plane

# 真机（systemd active+enabled 的受限项复验；playbooks/control-plane.yml 仍是骨架占位，属 T012）
ansible-playbook -i inventory/hosts.ini tests/control-plane/real_services.yml
systemctl is-enabled kube-apiserver kube-controller-manager kube-scheduler   # enabled
systemctl is-active  kube-apiserver kube-controller-manager kube-scheduler   # active
kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /healthz   # ok
kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /readyz    # ok
curl -k -s -o /dev/null -w '%{http_code}\n' https://<VIP>:6443/api   # 401
```

> **systemd 受限**：共享开发机不写 `/etc/systemd/system`、不执行 `systemctl`。测试只渲染
> unit 并静态断言，再用 unit 的 `ExecStart` **真实拉起**进程验证可执行性；`active+enabled`
> 必须在目标机按上面的真机步骤复验（见 `docs/harness/state/contracts/T007.md` §5.1）。
