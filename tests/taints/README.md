# tests/taints · T013 调度约束验收

验证 `roles/taints` 把控制面节点标记为 `NoSchedule` + 角色标签，并证明
**不带 toleration 的示例工作负载不会落 master**。

## 运行

```bash
env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test-taints
```

约 10–15 分钟。需要：

- `sudo -n`（沙箱进程以 root 拉起；不写宿主 systemd）；
- 制品缓存 `/tmp/opencode/k8s-cache/`（kubectl/apiserver/cm/scheduler/kubelet/etcd/containerd 等）；
- 空闲高位端口：16443、12379、20250、20248、20257、20259。

## 真实栈与近似项

| 组件 | 真实性 |
| --- | --- |
| etcd / kube-apiserver / kube-controller-manager / kube-scheduler | 真实二进制，从 role 渲染的 unit ExecStart 拉起 |
| kubelet（node1） | 真实注册；无 CNI → Ready=False |
| 控制面节点（cp1） | **合成 Node 对象**：真实 API 对象 + 真实污点/标签，无 kubelet |
| 工作负载 Pod | 真实调度绑定（`spec.nodeName`），镜像不可达 → 不会 Running |

## 断言分组

- **A 静态**：role 结构/变量化、示例工作负载无 toleration、syntax-check/yamllint、
  已 PASS role 未被修改。
- **B 真实 API**：两个节点均为真实 API 对象；污点 key/effect、角色标签可读回；
  非控制面节点不受影响；变量化（自定义 key/effect）生效。
- **C 调度**：3 副本 Deployment 全部 `spec.nodeName=node1`，0 个 `cp1`。
- **D 幂等**：role 连跑两次，第二次 `changed=0`，污点/标签哈希不变。
- **E 牙齿**：带污点时 pinned Pod 停在 Pending（事件含 untolerated taint）；
  移除污点后同类 Pod 被真实绑定到 `cp1`；重跑 role 恢复污点。
- **F fail-fast**：非法 effect / 非 `[k8s_master]` 主机 / 缺 kubeconfig → rc≠0。
- **G 清理**：进程、端口、`/etc/kubernetes`、`/etc/systemd/system`、`kernel.panic*`、
  `kubepods*.slice` 前后一致；沙箱目录删除。

## 真机

见 `docs/harness/state/contracts/T013.md` §5：真实集群用
`ansible-playbook ... --tags taints` + `kubectl get pods -o wide` 复验。
