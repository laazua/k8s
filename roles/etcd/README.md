# role: etcd

以**官方二进制 + systemd unit** 部署 etcd 集群（**奇数成员**）。复用 `download` role 取包
（URL + 强制 sha256 + 代理 + 本地缓存），TLS 证书来自 `pki` role（T004）。

安全模型分三段（详见「权限模型」）：**systemd unit / 二进制 / 解包目录永远 `root:root`**；
**数据目录归服务用户 `0700`**；**证书由 role 复制到独立分发目录**（`root:<etcd 组> 0750`，
私钥 `0640`、证书 `0644`），服务进程以 `Group` + `SupplementaryGroups` 只读访问，
**不放松 pki 源目录**。配置/二进制变更时按成员**滚动重启**并等待 quorum，绝不整簇同时重启。

## 做什么

| 关注点 | 行为 | tag |
| --- | --- | --- |
| 成员来源 | inventory `etcd` 分组（`etcd_inventory_group`）或显式 `etcd_members`；**无硬编码** | `etcd:facts` |
| 奇数校验 | 成员数为偶数 → **fail fast**（信息含当前成员数）；`etcd_min_members` 默认 3 | `etcd:validate` |
| 唯一性 | 成员名唯一、`address:client_port` 唯一；当前主机必须在成员清单中 | `etcd:validate` |
| 二进制 | `download` role 取官方 tarball（默认 `storage.googleapis.com/etcd`）+ 强制 sha256；解包安装 `etcd/etcdctl/etcdutl`（`root:root 0755`）；断言版本 | `etcd:binary` |
| 数据目录 | 每成员独立 `--data-dir`（服务用户 `0700`）；`co-located` 布局按成员名追加子目录 | `etcd:config` |
| 证书分发 | 从 pki 源复制 CA/server/peer 到 `etcd_pki_share_dir`（`root:<etcd 组> 0750`，私钥 `0640`、证书 `0644`） | `etcd:certs` |
| systemd | 渲染 unit（`--initial-cluster`、TLS、`Restart=always`、`LimitNOFILE`、`User=`/`Group=`/`SupplementaryGroups=`）；unit `root:root 0644` | `etcd:config` |
| 服务 | `ansible.builtin.systemd` 启用/启动；`etcd_manage_service=false` 时完全跳过 | `etcd:service` |
| 重启 | unit/二进制/证书内容变化才 `notify: etcd:restart`；handler **滚动重启**（throttle=1 + 等本成员 health + 校验 quorum） | handler |

## 关键变量（`defaults/main.yml`）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `etcd_root_prefix` | `""` | **仅测试用**沙箱前缀；生产留空 |
| `etcd_version` | `3.5.16` | 版本（只改这里） |
| `etcd_arch` | `{{ k8s_arch \| default('amd64') }}` | 架构 |
| `etcd_download_url` | `storage.googleapis.com/etcd/v<ver>/etcd-v<ver>-linux-<arch>.tar.gz` | 官方制品地址（可配代理/镜像） |
| `etcd_artifact_sha256` | 固定值（已实测） | **强制校验**，不可省略 |
| `etcd_inventory_group` | `etcd` | 成员来源分组 |
| `etcd_members` | `[]` | 显式覆盖；元素为 host 或 `{name,address,client_port,peer_port}` |
| `etcd_port_client` / `etcd_port_peer` | `2379` / `2380` | 默认端口（可被 hostvars `etcd_client_port`/`etcd_peer_port` 覆盖） |
| `etcd_min_members` | `3` | 高可用最低成员数（单机开发可置 1，奇数校验仍生效） |
| `etcd_instance_layout` | `per-host` | `per-host`（生产，每机一实例）或 `co-located`（单机多实例，data-dir/unit 名按成员隔离） |
| `etcd_cluster_token` | `k8s-etcd-cluster` | `--initial-cluster-token` |
| `etcd_data_dir` | `/var/lib/etcd` | 基础数据目录（group_vars 可覆盖） |
| `etcd_member_data_dir` | 派生 | 成员数据目录；`co-located` 时追加成员名 |
| `etcd_data_dir_mode` | `0700` | 数据目录权限（属主 = 服务用户） |
| `etcd_unit_dir` / `etcd_unit_mode` | `/etc/systemd/system` / `0644` | unit 目录（测试重定向到沙箱）/ unit 权限（属主 `root:root`） |
| `etcd_user` / `etcd_user_group` | `etcd` / `etcd` | 服务身份（unit 的 `User=`/`Group=`） |
| `etcd_root_owner` / `etcd_root_group` | `root` / `root` | **系统路径**属主：unit 目录与文件、二进制、制品/解包目录、证书分发父目录 |
| `etcd_data_owner` / `etcd_data_group` | `{{ etcd_user }}` / `{{ etcd_user_group }}` | **数据目录**属主（与服务身份一致，`0700`） |
| `etcd_cert_owner` / `etcd_cert_group` | `root` / `{{ etcd_user_group }}` | **证书分发目录**属主（root 拥有，服务组只读） |
| `etcd_tls_enabled` | `true` | TLS 开关；关闭后使用 `http://` 且无证书 flag |
| `etcd_tls_client_auth` / `etcd_tls_peer_client_auth` | `true` | `--client-cert-auth` / `--peer-client-cert-auth` |
| `etcd_ca_file` / `etcd_cert_file` / `etcd_key_file` / `etcd_peer_*` | `{{ etcd_pki_dir }}/...` | pki **源**路径（默认 `/etc/kubernetes/pki/etcd`，保持 `root:root 0700/0600`） |
| `etcd_share_config_dir` | `/etc/etcd` | 证书分发父目录（`root:root 0755`） |
| `etcd_pki_share_dir` | `{{ etcd_share_config_dir }}/pki` | 证书分发目录（`root:<etcd 组> 0750`） |
| `etcd_cert_dir_mode` / `etcd_cert_mode` / `etcd_cert_key_mode` | `0750` / `0644` / `0640` | 分发目录 / 证书 / **私钥**权限 |
| `etcd_runtime_{ca,cert,key,peer_cert,peer_key}_file` | 派生 | unit 与 etcdctl 实际使用的**分发目录**路径 |
| `etcd_manage_user` | `true` | 创建系统用户/组（沙箱测试置 false） |
| `etcd_manage_service` | `true` | 是否真实调用 systemctl（共享开发机/测试置 false） |
| `etcd_restart_health_retries` / `etcd_restart_health_delay` | `30` / `2` | 滚动重启后等待本成员 health / quorum 的重试次数与间隔（秒） |
| `etcd_service_restart_argv` | `[]` | **仅测试/无 systemd 环境**：非空时用该 argv 重启本成员；生产留空走 systemd |
| `etcd_heartbeat_interval` / `etcd_election_timeout` / `etcd_snapshot_count` | `100` / `1000` / `10000` | etcd 调优 |
| `etcd_extra_args` | `[]` | 追加原生参数 |

## 成员清单示例

```ini
[etcd]
etcd1 ansible_host=10.0.0.11
etcd2 ansible_host=10.0.0.12
etcd3 ansible_host=10.0.0.13
```

单机三实例（测试/实验）：

```ini
[etcd]
etcd1 ansible_host=127.0.0.1 etcd_client_port=12379 etcd_peer_port=12380
etcd2 ansible_host=127.0.0.1 etcd_client_port=22379 etcd_peer_port=22380
etcd3 ansible_host=127.0.0.1 etcd_client_port=32379 etcd_peer_port=32380
```

```yaml
- hosts: etcd
  vars:
    etcd_instance_layout: co-located
    etcd_listen_address: 127.0.0.1
    etcd_listen_peer_address: 127.0.0.1
  roles:
    - role: etcd
```

## 权限模型（B1/B2：为什么 `User=etcd` 能读私钥，但不能改 unit/二进制）

pki role（T004）默认把私钥生成为 `root:root 0600`、目录 `root:root 0700`。若 unit 直接引用这些路径，
`User=etcd` 的 etcd 进程**必然读不到私钥**。本 role 不修改 pki 源（kube-apiserver 等也消费它，
且 pki 每次运行都会重置权限），而是复制运行时需要的 5 个文件到独立分发目录：

| 对象 | 属主 | 权限 | 说明 |
| --- | --- | --- | --- |
| pki 源目录 `etcd_pki_dir` | `root:root` | `0700` | **保持不变**，不因 etcd 放宽 |
| pki 源私钥 | `root:root` | `0600` | **保持不变**，服务用户不可读 |
| 分发父目录 `etcd_share_config_dir` | `root:root` | `0755` | 可遍历，不可写 |
| 分发目录 `etcd_pki_share_dir` | `root:<etcd 组>` | `0750` | 组可进入，others 不可 |
| 分发证书 `*.crt` | `root:<etcd 组>` | `0644` | 公开材料 |
| 分发私钥 `*.key` | `root:<etcd 组>` | `0640` | 组可读、others 不可、**服务用户不可改写** |
| 数据目录 `etcd_member_data_dir` | `<etcd 用户>:<etcd 组>` | `0700` | 服务用户独占；与证书属主分离 |
| unit 目录 | `root:root` | `0755` | 服务用户不可写 |
| unit 文件 | `root:root` | `0644` | 服务用户不可改自己的 unit |
| 二进制目录 / 二进制 | `root:root` | `0755` / `0755` | 服务用户不可替换可执行文件 |

unit 同时设置 `Group=<etcd 组>` 与 `SupplementaryGroups=<etcd 组>`，进程按组读私钥；
`etcd:config` / `etcd:certs` / `etcd:binary` 在写入后用 `stat`/`assert` 校验上述属主与权限，
测试另以**真实非 root uid**（`setpriv --reuid ... --regid ... --clear-groups`）读取私钥并启动 etcd。

真机复验：

```bash
sudo stat -c '%U:%G %a %n' /etc/etcd/pki /etc/etcd/pki/*.key /etc/systemd/system/etcd.service \
  /usr/local/bin/etcd /var/lib/etcd
sudo -u etcd test -r /etc/etcd/pki/server.key && echo 'service user can read key'
sudo -u etcd test -w /etc/systemd/system/etcd.service || echo 'service user cannot write unit'
systemctl show etcd -p User -p Group -p SupplementaryGroups
```

## 幂等与重启语义

1. 制品已存在且 sha256 相符 → `download` role 跳过（**不重下载**，支持离线）。
2. 解包用版本目录 + `creates`；二进制 `copy` 内容不变 → `changed=0`。
3. unit 模板内容不变 → `template` `changed=0`，**不 notify**，运行中的 etcd 不会被重启。
4. 只有 unit、二进制或分发证书内容变化才 `notify: etcd:restart`；`etcd_manage_service=false` 时
   systemd 动作被 skip（受限环境不执行真实 systemctl），若提供 `etcd_service_restart_argv` 则用该命令
   真实重启本成员（仅测试）。
5. **滚动重启（D3）**：handler 执行 `tasks/rolling_restart.yml` —— `throttle: 1` 保证跨主机同一时刻
   只重启一个成员；每次重启后 `wait_member_healthy.yml` 等待本成员 `endpoint health` 恢复，
   并校验集群 healthy 端点数 `>= etcd_quorum`（多数派）；任一失败立即中止，**不会**继续重启下一个成员。
   生产建议在 play 层再加 `serial: 1`（更强的跨 play 保证）。
6. 同参数连跑两次 → 第二次 `changed=0`。

## 测试

```bash
tests/etcd/test_etcd_role.sh      # 等价于 make test-etcd
```

测试以 root 应用生产属主（`become: true`），再以**非 root 服务 uid** 从 unit 的 `ExecStart` 真实拉起
**单机 3 实例** etcd（高位端口、独立 data-dir、真实 TLS + 客户端证书认证），断言：

- `endpoint health` 三条全 healthy；`member list` 恰为 3；`endpoint status` leader 唯一；`put/get` 正常；
- 三个进程 `uid` 均为非 root 服务用户；分发私钥 `root:<组> 0640` 可被该 uid 读取，
  而 pki 源私钥仍 `root:root 0600` 且该 uid **不可读**；
- `stat` 断言二进制/unit/系统目录 `root:root`、unit `0644`、数据目录服务用户 `0700`，
  且宿主 `/etc/systemd/system`、`/usr/local/bin` 未被 chown；
- `kill -9` 一个成员 → 2/3 仍有 quorum；重新拉起 → 三条恢复 healthy、数据仍在；
- 配置变更触发滚动重启：3 个成员逐个重启、每次等待本成员 health 并校验 quorum，
  滚动期间采样 quorum 始终 `>=2`，重启后 PID 全变化、数据不丢、leader 唯一；
- `etcd_min_members=1` 下 2 成员与 4 成员均 fail-fast（单独锁定奇数校验，而非靠最低成员数）；
- TLS 证书缺失 fail-fast；TLS 关闭分支真实起 HTTP 集群；
- 幂等 `changed=0`、运行中重跑 PID 与 `/proc/<pid>/stat` starttime 不变；离线缓存命中；
- 宿主零污染（不写 `/etc/systemd/system`、不建 `/var/lib/etcd`、不装 `/usr/local/bin/etcd`）。

> 受限项（对应 `spec.md` R1 / 契约 §5）：共享开发机**禁止**真实 `systemctl enable/start`，
> 故 systemd 只渲染 unit + 断言内容；测试用 `setpriv` 真实切换非 root uid 启动进程，
> 但**未验证真实 systemd 托管**。跨主机网络/真实 systemd 需按契约 §6.2 在真机复验。

## 不在范围

证书生成（T004 `pki`）、控制面编排（T006/T007）、etcd 备份/恢复与版本升级（T015）、
动态成员增删（`member add/remove`）。
