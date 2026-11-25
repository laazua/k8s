# k8s

## [项目初始化](docs/init.md)

---

## 部署快速开始

完整手册见 [`docs/usage.md`](docs/usage.md)，全部可配置项见自动生成的
[`docs/variables.md`](docs/variables.md)。

```bash
# 1) 初始化 inventory（按真实拓扑填写 [k8s_master]/[etcd]/[k8s_node]）
cp inventory/hosts.example inventory/hosts.ini

# 2) 一条命令部署（控制面 + 工作节点，幂等可重复执行）
make deploy INVENTORY=inventory/hosts.ini

# 3) 验证
kubectl get nodes -o wide
```

常用后续操作：

```bash
# 加节点：只对新节点执行（不重建 CA、不影响既有节点）
ansible-playbook -i inventory/hosts.ini playbooks/add-node.yml -l <new-node>

# 升级 / 回滚（相邻 minor，升级前自动备份 etcd 与证书）
ansible-playbook -i inventory/hosts.ini playbooks/upgrade.yml -e upgrade_version=1.32.13 --limit k8s_master

# 一键端到端验收（沙箱真实执行，约 30 分钟）
make test-e2e-full
```

> 无镜像/离线/多节点等**已知限制**见 [`docs/usage.md`](docs/usage.md#已知限制)。

---

## [harness 使用说明](docs/harness-usage.md)


