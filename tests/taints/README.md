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

前置：控制面已引导完成，`/etc/kubernetes/admin.conf` 存在（`roles/cluster-addons`）。

```bash
# 1) 准备 inventory（仓库只提供示例）
cp inventory/hosts.example inventory/hosts.yml   # 按需填写 master/node 主机

# 2) 只跑调度约束 role（playbooks/taints.yml 已接入 roles/taints）
ansible-playbook -i inventory/hosts.yml playbooks/taints.yml --tags taints

# 3) 读回真实污点/标签
kubectl get nodes -o json | jq '.items[] | {name:.metadata.name,
  taints:.spec.taints, labels:.metadata.labels}'

# 4) 无 toleration 的工作负载（镜像可达时 Pod 会 Running）
kubectl create deployment t013-real --image=<可达镜像> --replicas=3
kubectl get pods -o wide    # NODE 列应只有 node
```

受限项见 `docs/harness/state/contracts/T013.md` §5：无镜像时 Pod 只验证调度绑定
（`spec.nodeName`），不验证 Running；沙箱 master 节点为合成 Node 对象。
