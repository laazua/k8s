# role · taints

给控制面节点写入 `NoSchedule` 污点与角色标签，保证**业务工作负载只调度到 node**。

## 职责

1. 经真实 `kubectl` 访问真实 Kubernetes API，给 `[k8s_master]` 节点确保：
   - 污点（默认 `node-role.kubernetes.io/control-plane:NoSchedule`，key/value/effect 可配）；
   - 角色标签（默认 `node-role.kubernetes.io/control-plane`）。
2. 只增不删：不负责移除历史污点；由集群运维显式清理。
3. 幂等：先 `get node -o json` 读回现状，仅缺失/值不一致时执行
   `kubectl taint|label --overwrite`；重复执行 `changed=0`。
4. fail-fast：非法 effect、非 `[k8s_master]` 主机、kubeconfig 缺失 → 立即失败，
   不产生任何集群写操作。
5. 写后读回断言：污点/标签必须能从真实 API 读回，否则 role 失败。

## 目录与文件

| 路径 | 说明 |
| --- | --- |
| `tasks/validate.yml` | 参数/成员身份/kubeconfig 校验（只读） |
| `tasks/nodes.yml` | 读现状 → 按需写污点/标签 → 读回断言 |
| `tasks/main.yml` | 入口与 tags（`taints:validate` / `taints:nodes`） |

## 关键变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `taints_kubectl` | `/usr/local/bin/kubectl` | kubectl 绝对路径（validate 断言可执行） |
| `taints_kubeconfig` | `/etc/kubernetes/admin.conf` | 访问 API 的 kubeconfig |
| `taints_kubectl_extra_args` | `[]` | 额外 kubectl 参数（如沙箱 `--cache-dir`） |
| `taints_control_plane_nodes` | `groups['k8s_master']` | 目标节点列表 |
| `taints_control_plane_taint_key` | `node-role.kubernetes.io/control-plane` | 污点 key |
| `taints_control_plane_taint_value` | `""` | 污点 value |
| `taints_control_plane_taint_effect` | `NoSchedule` | 污点 effect（白名单三选一） |
| `taints_manage_taint` | `true` | 是否写污点 |
| `taints_manage_label` | `true` | 是否写角色标签 |
| `taints_control_plane_label_key` | `node-role.kubernetes.io/control-plane` | 标签 key |
| `taints_control_plane_label_value` | `""` | 标签 value |
| `taints_require_control_plane_membership` | `true` | 非 `[k8s_master]` 主机拒绝执行 |
| `taints_wait_for_nodes` | `true` | 等待 Node 对象注册 |
| `taints_wait_retries` / `taints_wait_delay` | `30` / `2` | 等待重试次数/间隔（秒） |

## 使用

```yaml
- name: 标记控制面节点（业务仅落 node）
  hosts: k8s_master
  become: true
  roles:
    - role: taints
```

```bash
# 前置：控制面已引导，/etc/kubernetes/admin.conf 存在
cp inventory/hosts.example inventory/hosts.yml   # 按需填写
ansible-playbook -i inventory/hosts.yml playbooks/taints.yml --tags taints
kubectl get nodes -o json | jq '.items[] | {name:.metadata.name, taints:.spec.taints, labels:.metadata.labels}'
kubectl get pods -o wide   # 业务 Pod 的 NODE 列应只有 node
```

## 验证

```bash
tests/taints/test_taints_role.sh   # 沙箱真实 apiserver/CM/scheduler/kubelet + 真实调度判定
make test-taints
```

受限项见 `docs/harness/state/contracts/T013.md` §5：无镜像时 Pod 只验证调度绑定
（`spec.nodeName`），不验证 Running；沙箱 master 节点为合成 Node 对象。
