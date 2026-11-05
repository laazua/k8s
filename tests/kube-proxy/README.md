# tests/kube-proxy — T009 kube-proxy 验收

## 运行

```bash
make test-kube-proxy        # = tests/kube-proxy/test_kube_proxy_role.sh
# 或
tests/kube-proxy/test_kube_proxy_role.sh
```

套件**每次运行都会自动** `exec sudo -n ... unshare -n` 进入独立 netns（仅 `lo`、
无默认路由），把「测试不依赖外网」变成硬约束。首次运行需要外网预取制品；预取发生在
re-exec **之前**（宿主网络），进入 netns 后只做 sha256 校验。

## 缓存

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `T009_TEST_CACHE` | `/tmp/opencode/k8s-cache` | 制品缓存（与 T007/T008 共用） |
| `ETCD_TEST_CACHE` | `/tmp/opencode/etcd-cache` | 可选：etcd 发行包种子目录 |

制品清单（全部强制 sha256）：

- kube-proxy v1.31.0（`b4b4ecbf…2967ca`）
- kube-apiserver v1.31.0、kubectl v1.31.0
- etcd v3.5.16（linux-amd64）

## 验证内容

- **静态**：role 结构、变量化/无硬编码、KubeProxyConfiguration 与 unit 模板、
  systemd 接线、安全默认（healthz/metrics 绑 127.0.0.1、kubeconfig 0600）、语法/yamllint。
- **动态（真实进程，无镜像/无 Pod）**：
  1. 沙箱内真实 pki + 单成员 TLS etcd + 真实 kube-apiserver（16443）；
  2. 创建 `Node node1`、`Service mock`（ClusterIP `10.96.0.50:80`）、
     `EndpointSlice` → 后端 `10.0.0.10:18080`（netns 内本地 mock HTTP，非 Pod）；
  3. 从 role 渲染的 unit 的 `ExecStart` 拉起**真实 kube-proxy**（healthz 20247 /
     metrics 20249）；
  4. 断言 `iptables-save -t nat` 含 `KUBE-SERVICES` 与 DNAT 到后端；
  5. **`curl http://10.96.0.50/health` 必须返回 200 与 mock 已知响应（A9 核心）**；
  6. 边界：停 mock → 失败；重启 → 成功；删 EndpointSlice → 规则移除且失败；恢复 → 成功；
  7. 幂等：role 连跑第二次 `changed=0`、无 handler、PID/starttime/内容哈希不变；
  8. fail-fast 矩阵：proxy_mode 非法 / cluster-cidr 缺失 / cluster-cidr 非法 /
     kubeconfig 缺失 / iptables 缺失 / ipvs 但 `ip_vs` 未加载 / 版本不匹配；
  9. 密闭性：空缓存 + 不可达 URL 必须失败；缓存命中 + 不可达 URL 必须成功；
  10. 清理：进程全退出、端口释放、宿主 iptables/端口/`/etc/kubernetes` 快照一致。
- **受限**：不写宿主 `/etc/systemd/system`、不 `systemctl enable/start`、不写
  `/etc/kubernetes`、不占默认 6443/10256/10249、不改宿主 iptables/路由。
  systemd `active+enabled`、多节点 DaemonSet 调度与 Pod 级 ClusterIP 访问见契约 §5。

## 沙箱布局

```
/tmp/opencode/t009.XXXXXX/
  opt/k8s/artifacts/        # 制品缓存副本（root:root 0644）
  usr/local/bin/            # kube-proxy/kube-apiserver/kubectl/etcd/etcdctl
  etc/kubernetes/           # pki、admin.conf、kube-proxy.yaml、kube-proxy.conf
  etc/systemd/system/       # 只渲染 unit，不安装到宿主
  logs/                     # etcd/apiserver/kube-proxy/mock 日志
  client/                   # 测试用 kubeconfig/证书副本
  www/                      # mock HTTP 文档根（含已知响应）
```

trap 在退出时杀掉全部子进程并删除沙箱；宿主 iptables/ip6tables、监听端口、
`/etc/kubernetes`、`/etc/systemd/system/kube-proxy.service`、`/var/lib/kube-proxy`
做前后快照对比。
