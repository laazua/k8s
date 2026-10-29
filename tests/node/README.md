# tests/node — T008 运行时与节点组件验收

## 运行

```bash
make test-node          # = tests/node/test_node_roles.sh
# 或
tests/node/test_node_roles.sh
```

套件**每次运行都会自动** `exec sudo -n ... unshare -n` 进入独立 netns（仅 `lo`、无默认路由），
从而把「测试不依赖外网」变成硬约束。首次运行需要外网预取制品；预取发生在 re-exec **之前**
（宿主网络），进入 netns 后只做 sha256 校验（T007-r3 M6 的修复）。

## 缓存

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `T008_TEST_CACHE` | `/tmp/opencode/k8s-cache` | 全部制品缓存目录（与 T007 共用） |
| `ETCD_TEST_CACHE` | `/tmp/opencode/etcd-cache` | 可选：etcd 发行包的种子目录 |

一次性预热（可选）：

```bash
tests/node/test_node_roles.sh   # 首次会自动下载并校验 sha256
```

制品清单（全部强制 sha256）：

- kube-apiserver / kube-controller-manager / kube-scheduler / kubectl / kubelet（v1.31.0）
- containerd 2.0.0（linux-amd64 tar.gz）
- runc 1.2.1（amd64）
- CNI plugins 1.5.1（linux-amd64）
- crictl 1.31.1（linux-amd64）
- etcd v3.5.16（linux-amd64）

## 验证内容

- **静态**：role 结构、变量化/无硬编码、unit/config 模板、systemd 接线、安全默认、语法/yamllint。
- **动态（真实进程）**：沙箱内真实 etcd + kube-apiserver + containerd + kubelet；
  从 role 渲染的 unit `ExecStart` 拉起进程；验证 `crictl info` / `crictl version` /
  CRI socket dial / `kubectl get nodes` 出现 `node1` / cgroup 一致性 / 幂等 / fail-fast。
- **受限**：不写宿主 `/etc/systemd/system`、不 `systemctl enable/start`、不写
  `/etc/containerd`、`/var/lib/{containerd,kubelet}`、不占默认 6443/10250。
  systemd `active+enabled` 的真机复验步骤见 `docs/harness/state/contracts/T008.md` §5.5。
- **预期 NotReady**：本任务不含 CNI（Cilium 属 T010），节点 `Ready=False`
  （通常 `NetworkPluginNotReady`）是预期结果；测试记录 Ready 条件与 reason。

## 沙箱布局

```
/tmp/opencode/t008.XXXXXX/
  opt/k8s/artifacts/        # 制品缓存副本（root:root 0644）
  opt/cni/bin/              # CNI plugins
  usr/local/bin/            # containerd/runc/crictl/kubelet/kubectl/etcd
  etc/containerd/config.toml
  etc/kubernetes/pki/       # pki（含 kubelet/node1.crt|key）
  etc/systemd/system/       # 只渲染 unit，不安装到宿主
  var/lib/containerd/       # containerd root
  var/lib/kubelet/          # kubelet root/config/kubeconfig
  run/containerd/           # containerd state + CRI socket
  logs/                     # 进程日志
  client/                   # 测试用 kubeconfig/证书副本
```

trap 在退出时杀掉全部子进程并删除沙箱；宿主 `/etc/systemd/system`、`/etc/containerd`、
`/var/lib/{containerd,kubelet}`、`/run/containerd`、`/opt/cni/bin` 做前后快照对比。
