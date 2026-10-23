# tests/control-plane · T007 验收测试

## 一句话

在**沙箱**里用真实 PKI + 真实单成员 TLS etcd + 真实 `kube-apiserver` /
`kube-controller-manager` / `kube-scheduler` 进程验证控制平面 role；不写宿主
`/etc/systemd/system`、不执行 `systemctl`、不占默认端口，结束后全量清理。

## 运行

```bash
# 单跑（自动准备官方制品缓存到 /tmp/opencode/k8s-cache，sha256 强校验）
tests/control-plane/test_control_plane_roles.sh
make test-control-plane

# 全量门禁（含本套件）
env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test
```

依赖：`ansible-playbook`、`yamllint`、`python3`(+PyYAML)、`openssl`、`curl`、`ss`、
免密 `sudo`（以 root 应用生产属主模型并从 unit 拉起进程）、网络可访问 `dl.k8s.io`
（制品已缓存时离线可跑）。

## 拓扑（全部 127.0.0.1，高位端口）

| 组件 | 端口 | 说明 |
| --- | --- | --- |
| etcd（单成员 TLS，uid 65534） | 12379 / 12380 | unit 由 T005 role 渲染，从 `ExecStart` 拉起 |
| kube-apiserver | 16443 | admin/匿名/TLS 断言 |
| kube-controller-manager | 20257 | leader election + delegated authn |
| kube-scheduler | 20259 | leader election + delegated authn |

## 文件

| 文件 | 用途 |
| --- | --- |
| `inventory.ini` | 单机 inventory：`[k8s_master]`/`[etcd]` + VIP/端口/版本 |
| `sandbox_stack.yml` | kubectl（测试用）+ pki（真实签发）+ 单成员 TLS etcd |
| `sandbox_control_plane.yml` | 三 role 渲染（`manage_service=false`，全部写沙箱） |
| `test_control_plane_roles.sh` | 静态 A1–A9 + 动态 B1–B10 断言，输出 `PASS/FAIL` 汇总 |

## 断言分组

- **A1–A9**：结构/变量化/unit 模板/安全默认/引导 kubeconfig/systemd 接线/文档/范围/语法风格。
- **B1–B5**：真实 pki+etcd、首跑渲染、unit 关键 flag、kubeconfig 身份与签发链。
- **B6–B7**：真实进程存活、`/healthz`、`/readyz`、`kubectl get ns`、匿名 401、进程参数。
- **B8**：运行中重跑 `changed=0`、无 handler、PID/starttime/文件哈希不变。
- **B9**：fail-fast 矩阵（缺证书 / 缺 etcd endpoint / 缺 SA key / cm 缺 kubeconfig /
  版本不匹配 / 端口冲突），全部要求 unit 不变。
- **B10**：进程/端口/沙箱清理 + 宿主零污染快照对比。

> 受限项（systemd `active+enabled`、多主/VIP 串联、kubelet 侧认证）见
> `docs/harness/state/contracts/T007.md` §5；真机复验命令在 §5.1。
