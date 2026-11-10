# tests/cilium — T010 Cilium CNI role 验收

## 运行

```bash
make test-cilium        # = tests/cilium/test_cilium_role.sh
# 或
tests/cilium/test_cilium_role.sh
```

套件**每次运行都会自动** `exec sudo -n ... unshare -n -m` 进入独立网络命名空间
（仅 `lo`、无默认路由）并 `mount --make-rprivate /`（私有 mount ns，`ip netns`
不泄漏到宿主）。**不需要外网、不拉 chart、不拉镜像、不需要缓存预取**。

## 验证内容

- **静态**：role 结构、变量化/无硬编码、清单模板 kind 与键映射、fail-fast 覆盖、
  离线（无 `get_url`/`uri`/helm/download）、`--syntax-check` + `yamllint`、文档、
  `--list-tasks` / `--check` 接线。
- **动态（真实内核对象，无镜像/无 Pod）**：
  1. 沙箱渲染 Cilium multi-doc YAML（`mktemp -d`，生产前缀留空）；
  2. PyYAML 解析；断言 DaemonSet/ConfigMap/ServiceAccount/ClusterRole(Binding)
     + operator Deployment 齐全；逐项比对版本、mode、`tunnel-protocol=vxlan`、
     `kubeProxyReplacement=false`、cluster name/id、Pod CIDR、API endpoint、MTU、
     tunnel 端口、镜像 registry；
  3. **netns + veth + VXLAN**：从渲染清单读取 VNI（`cluster-id`）、tunnel 端口、MTU、
     Pod CIDR，建 3 组双节点拓扑：
     - 正例：参数一致 → underlay 通、路由走 `vxlan0`、MTU 生效、跨 netns ICMP 与
       HTTP 成功；
     - 反证 A：一侧 VNI 不一致 → underlay 仍通，但 Pod IP 不通；
     - 反证 B：一侧 tunnel 端口不一致 → underlay 仍通，但 Pod IP 不通；
     - 反证后正例仍可通。
  4. 幂等：role 连跑第二次 `changed=0`；同沙箱 `--check` 不写；
  5. fail-fast 矩阵（mode/CIDR/冲突/版本/必填/端口/MTU/cluster-id/registry/namespace/
     pull policy）：exit≠0、错误可定位、已渲染文件哈希不变；全新沙箱不落盘；
  6. 清理：netns/veth/VXLAN/HTTP 进程/沙箱全部清除；宿主只对比本任务资源
     （vxlan 接口、`/var/run/netns`、测试 CIDR 路由、cilium iptables、18081 端口、
     `/etc/kubernetes`、cilium unit），不比较全局监听端口（spec v1.5）。

## 前置

- `vxlan` 内核模块需由环境预置（`/sys/module/vxlan`）。套件**不主动** `modprobe`；
  缺失时显式失败。干净环境可显式 `CILIUM_TEST_ALLOW_MODPROBE=1` 允许套件加载一次。
- 免密 sudo（`unshare -n -m`、`nsenter -t 1 -n` 快照）。
- PyYAML（清单解析）。

## 受限（契约 §5）

`cilium-agent`/`cilium-operator` 未运行（无镜像）；**Pod 网络未验证**；
`cilium status`、`kubectl get nodes` 的 Ready 未验证；B4 的内核 VXLAN 隧道
**不是** Cilium BPF 数据面。真机复验步骤见
`docs/harness/state/contracts/T010.md` §5.7。

## 沙箱布局

```
/tmp/opencode/t010.XXXXXX/
  etc/kubernetes/cilium/cilium.yaml   # role 渲染的清单
  www/health                          # HTTP 后端已知响应
```

`trap` 在退出时杀掉 HTTP、删除 3 组 netns、删除沙箱。
