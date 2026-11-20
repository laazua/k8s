# tests/upgrade — 版本升级与回滚验收套件（T015）

`make test-upgrade` → `tests/upgrade/test_upgrade_flow.sh`（约 10–15 分钟）。

## 被测对象

真实入口 [`playbooks/upgrade.yml`](../../playbooks/upgrade.yml) + `roles/upgrade`。

## 沙箱（单宿主，真实进程，不写宿主）

| 角色 | inventory | 端口 | 说明 |
| --- | --- | --- | --- |
| 控制面 | `cp1`（`k8s_master`） | apiserver `16443`、CM `20257`、scheduler `20259` | 真实 TLS etcd（`12379`）+ 真实 apiserver；CM/scheduler 仅渲染 unit |
| 工作节点 | `node1`（`k8s_node`） | kubelet `20250/20248` | 真实 containerd + 真实 kubelet（注册为 Node） |

- 所有落盘由 `sandbox_root` 重定向到 `mktemp -d`；不写宿主 `/etc/kubernetes`、`/etc/systemd/system`，
  不 `systemctl start/stop`（只停本次新建的 `kubepods*` slice）。
- 无 systemd：进程由测试按 unit `ExecStart`（`tests/etcd/unit_exec.py`）拉起；
  `upgrade_manage_service=false`，因此 role 只安装二进制，重启由测试执行。
- 基线 1.31.0、目标 1.32.13 的官方制品缓存在 `/tmp/opencode/k8s-cache`（含官方 sha256 校验）；
  缺失时测试自行下载（首跑慢，之后零网络）。
- 无镜像 → 系统 Pod 不 Running、无 CNI → 节点 `Ready=False`；`upgrade_require_ready_nodes=false`
  时只要求 Ready 条件存在且 reason 非空，另跑一次 `true` 反向证明判定有牙齿。

## 覆盖

| 组 | 内容 |
| --- | --- |
| A | role/测试资产结构、变量化、入口是真实实现（非占位）、`--syntax-check`/`yamllint`、check-mode 接线、无硬编码/无 `shell`/无 `systemctl` 直调 |
| B | 基线集群、升级前备份（真实 `etcdctl snapshot save` + PKI + kubeconfig + 旧二进制 + `MANIFEST` + `SHA256SUMS`）、备份失败即中止、版本变更（`/version`、`kubelet --version`）、节点仍注册、Ready 判定牙齿、备份保留数 |
| C | 幂等（重跑 `changed=0`、不重复备份、不重启）、二进制被回退后自愈、产物稳定 |
| D | 按文档回滚（控制面 + 节点）、版本回到原版本、集群可用、etcd 真回退（升级期写入的 ConfigMap 消失）、内容哈希可证、回滚后可重放 |
| E | fail-fast 矩阵（非法版本格式 / 跨多 minor / 降级 / 无备份 / 缺 `SHA256SUMS` / 备份被篡改 / 制品 sha256 不符 / 制品版本不符）、`--check`、宿主零污染、SKIP 单列计数 |

## 命令

```bash
make test-upgrade                      # 全量验收
bash tests/upgrade/test_upgrade_flow.sh # 等价（非 root 时自动 sudo 重入）
```

回滚命令（生产同一条）：

```bash
ansible-playbook -i inventory/hosts.yml playbooks/upgrade.yml \
  -e upgrade_action=rollback -e upgrade_rollback_dir=/var/backups/kubernetes/upgrade/<ts>-<host>
```

**多成员 etcd 必须显式覆盖成员名与 peer URL**（默认 `default` / `http://localhost:2380` 只适用单成员；
与本项目 `roles/etcd` 的 `etcd_member_name: "{{ inventory_hostname }}"` + TLS peer 对齐）：

```bash
ansible-playbook -i inventory/hosts.yml playbooks/upgrade.yml \
  -e upgrade_action=rollback \
  -e upgrade_rollback_dir=/var/backups/kubernetes/upgrade/<ts>-<host> \
  -e upgrade_rollback_etcd_member_name=<inventory_hostname> \
  -e upgrade_rollback_etcd_initial_peer_url=https://<peer_ip>:2380 \
  -e upgrade_rollback_etcd_initial_cluster='<inventory_hostname>=https://<peer_ip>:2380,...'
```

回滚证据的主/辅区分：**主证据** = 二进制哈希回到旧版 + apiserver `/version` 回到旧版 +
升级期写入的 ConfigMap 消失；PKI / kubeconfig / kubelet.conf 哈希比对只是**辅助**（升级本就不改它们，
相等是必然，不具区分度）。

## 已知限制（契约 §5 / §9）

- 单宿主单节点：「全部节点 Ready」只有 node1；真实多节点滚动需真机。
- 无 CNI → `Ready=False/KubeletNotReady`；无镜像 → Pod 不 Running。
- 无 systemd：handler 的 `systemd_service` 重启路径未在沙箱执行（生产 `upgrade_manage_service=true`）。
- etcd 单成员；3 成员滚动重启与成员间一致性未验证。
