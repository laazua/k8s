# role: etcd

以**官方二进制 + systemd unit** 部署 etcd 集群（**奇数成员**）。复用 `download` role 取包
（URL + 强制 sha256 + 代理 + 本地缓存），TLS 证书来自 `pki` role（T004）。

## 做什么

| 关注点 | 行为 | tag |
| --- | --- | --- |
| 成员来源 | inventory `etcd` 分组（`etcd_inventory_group`）或显式 `etcd_members`；**无硬编码** | `etcd:facts` |
| 奇数校验 | 成员数为偶数 → **fail fast**（信息含当前成员数）；`etcd_min_members` 默认 3 | `etcd:validate` |
| 唯一性 | 成员名唯一、`address:client_port` 唯一；当前主机必须在成员清单中 | `etcd:validate` |
| 二进制 | `download` role 取官方 tarball（默认 `storage.googleapis.com/etcd`）+ 强制 sha256；解包安装 `etcd/etcdctl/etcdutl`；断言版本 | `etcd:binary` |
| 数据目录 | 每成员独立 `--data-dir`（`0700`）；`co-located` 布局按成员名追加子目录 | `etcd:config` |
| systemd | 渲染 unit（`--initial-cluster`、TLS、`Restart=always`、`LimitNOFILE`、`User=`） | `etcd:config` |
| 服务 | `ansible.builtin.systemd` 启用/启动；`etcd_manage_service=false` 时完全跳过 | `etcd:service` |
| 重启 | unit/二进制内容变化才 `notify: etcd:restart`（配置未变不重启） | handler |

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
| `etcd_data_dir`（group_vars） | `/var/lib/etcd` | 基础数据目录 |
| `etcd_unit_dir` | `/etc/systemd/system` | unit 目录（测试重定向到沙箱） |
| `etcd_tls_enabled` | `true` | TLS 开关；关闭后使用 `http://` 且无证书 flag |
| `etcd_tls_client_auth` / `etcd_tls_peer_client_auth` | `true` | `--client-cert-auth` / `--peer-client-cert-auth` |
| `etcd_ca_file` / `etcd_cert_file` / `etcd_key_file` / `etcd_peer_*` | `{{ etcd_pki_dir }}/...` | 证书路径（默认 `/etc/kubernetes/pki/etcd`） |
| `etcd_manage_user` | `true` | 创建系统用户/组（沙箱测试置 false） |
| `etcd_manage_service` | `true` | 是否真实调用 systemctl（共享开发机/测试置 false） |
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

## 幂等与重启语义

1. 制品已存在且 sha256 相符 → `download` role 跳过（**不重下载**，支持离线）。
2. 解包用版本目录 + `creates`；二进制 `copy` 内容不变 → `changed=0`。
3. unit 模板内容不变 → `template` `changed=0`，**不 notify**，运行中的 etcd 不会被重启。
4. 只有 unit 或二进制内容变化才 `notify: etcd:restart`；`etcd_manage_service=false` 时 handler 被 skip
   （受限环境不执行真实 systemctl）。
5. 同参数连跑两次 → 第二次 `changed=0`。

## 测试

```bash
tests/etcd/test_etcd_role.sh      # 等价于 make test-etcd
```

测试真实启动**单机 3 实例** etcd（高位端口、独立 data-dir、真实 TLS + 客户端证书认证），断言：

- `endpoint health` 三条全 healthy；`member list` 恰为 3；`endpoint status` leader 唯一；`put/get` 正常；
- `kill -9` 一个成员 → 2/3 仍有 quorum；重新拉起 → 三条恢复 healthy、数据仍在；
- 偶数成员 fail-fast；TLS 证书缺失 fail-fast；TLS 关闭分支真实起 HTTP 集群；
- 幂等 `changed=0`；配置变更才通知重启 handler；离线缓存命中；
- 宿主零污染（不写 `/etc/systemd/system`、不建 `/var/lib/etcd`、不装 `/usr/local/bin/etcd`）。

> 受限项（对应 `spec.md` R1 / 契约 §5）：共享开发机**禁止**真实 `systemctl enable/start`，
> 故 systemd 只渲染 unit + 断言内容；跨主机网络/真实 systemd 托管需按契约 §6.2 在真机复验。

## 不在范围

证书生成（T004 `pki`）、控制面编排（T006/T007）、etcd 备份/恢复与版本升级（T015）、
动态成员增删（`member add/remove`）。
