# roles/ · 角色命名与结构约定

每个子系统一个 role，目录结构遵循标准：

```
roles/<role_name>/
  defaults/main.yml    # 可被 group_vars 覆盖的默认值（版本、路径、参数）
  vars/main.yml        # 不希望被覆盖的内部常量（尽量少用）
  tasks/main.yml       # 主任务（幂等优先）
  handlers/main.yml    # 服务重启等
  templates/           # *.j2（systemd unit、组件配置、证书配置）
  files/               # 静态文件（二进制校验清单等）
  meta/main.yml        # role 依赖声明
  README.md            # 该 role 的用途与变量
```

## 约定
- 使用 FQCN（`ansible.builtin.*`、`ansible.posix.*`）。
- 每个 task 必须带 `name`；给 role 打 `tags` 便于单跑。
- 优先幂等模块；必须 `command`/`shell` 时加 `creates`/`removes`/`changed_when`。
- 可变项一律走 `defaults/` + `group_vars`，禁止硬编码版本/路径/发行版。
- 发行版差异集中在 `base` role，按 `ansible_os_family` 分支。

## 规划中的 roles
| role | 任务 |
| --- | --- |
| `base` | T002 |
| `download` | T003 |
| `pki` | T004 |
| `etcd` | T005 |
| `haproxy`, `keepalived` | T006 |
| `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` | T007 |
| `containerd`, `kubelet` | T008 |
| `kube-proxy` | T009 |
| `cilium` | T010 |
| `cluster-addons` | T011 |
| `taints` | T013 |

> 本文件仅定义约定；空 role 由对应任务创建。
