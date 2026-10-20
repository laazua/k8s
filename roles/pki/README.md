# role: pki

自建 PKI（**不依赖 kubeadm、不依赖外网**），为二进制部署生成全套集群证书。
实现载体是本地 `openssl` CLI（`community.crypto` 在本环境因缺 `cryptography` 不可用，见
`docs/harness/state/contracts/T004.md` §3/§9.0）。

## 生成物（默认路径，均可由 `pki_dir` 重定向）

| 组件 | 文件 | 签发者 |
| --- | --- | --- |
| kubernetes CA | `ca.crt` / `ca.key` | 自签 |
| apiserver | `apiserver.crt` / `apiserver.key` | kubernetes-ca |
| admin（kubeconfig 客户端证书） | `admin.crt` / `admin.key`（`CN=kubernetes-admin, O=system:masters`） | kubernetes-ca |
| kubelet（每节点一份） | `kubelet/<node>.crt` / `<node>.key`（`CN=system:node:<node>, O=system:nodes`） | kubernetes-ca |
| front-proxy CA | `front-proxy-ca.crt` / `.key` | 自签 |
| front-proxy client | `front-proxy-client.crt` / `.key` | front-proxy-ca |
| etcd CA | `etcd/ca.crt` / `etcd/ca.key` | 自签 |
| etcd server / peer | `etcd/server.crt`、`etcd/peer.crt`（+key） | etcd-ca |
| apiserver → etcd 客户端 | `apiserver-etcd-client.crt` / `.key` | etcd-ca |
| ServiceAccount | `sa.key`（RSA 2048）/ `sa.pub` | 无证书 |

权限硬指标：目录 `0700`、私钥 `0600`、证书 `0644`、公钥 `0644`。

## 核心不变量

1. **SAN 只来自变量**：inventory 分组（`pki_master_group` / `pki_node_group` / `pki_etcd_group`）
   + `k8s_vip` + `k8s_service_cidr` + 各主机 `ansible_host`（可用 `pki_host_addresses` 覆盖）。
   `tasks/` 中不存在任何硬编码 IP / 主机名 / 路径。
2. **拓扑缺失即 fail fast**：`k8s_master` 分组为空时直接失败并指出分组名，绝不生成空 SAN 证书。
3. **重跑不覆盖仍有效的既有证书**：内容 sha256 不变、`changed=0`。
4. 证书/私钥不落库（`.gitignore` 已覆盖 `*.key` / `*.crt`）。

## 主要变量（`defaults/main.yml`）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `pki_root_prefix` | `""` | **仅测试用**沙箱前缀；生产保持空串 |
| `pki_config_dir` | `{{ k8s_config_dir \| default('/etc/kubernetes') }}` | 配置根目录 |
| `pki_dir` | `{{ pki_root_prefix }}{{ pki_config_dir }}/pki` | PKI 根目录（可整体重定向） |
| `pki_key_type` / `pki_key_size` / `pki_ec_curve` | `RSA` / `2048` / `prime256v1` | 密钥算法 |
| `pki_digest` | `sha256` | 签名摘要 |
| `pki_ca_duration_days` / `pki_cert_duration_days` | `3650` / `3650` | 有效期 |
| `pki_renew_before_seconds` | `2592000` | 进入该续期窗口即重签（默认 30 天） |
| `pki_force_regen` | `false` | 显式强制全量重签（SAN 集合变化时用） |
| `pki_verify_chain` | `true` | 落盘后做链式校验，失败即让 role 失败 |
| `pki_master_group` / `pki_node_group` / `pki_etcd_group` | `k8s_master` / `k8s_node` / `etcd` | 拓扑来源 |
| `k8s_vip` / `k8s_service_cidr` | `""` / `10.96.0.0/12` | VIP 与服务网段（服务 IP 取网段首个可用地址） |
| `pki_include_nodes_in_apiserver_sans` | `true` | apiserver SAN 是否含工作节点 |
| `pki_*_extra_sans` | `[]` | 追加 SAN |
| `pki_cas` / `pki_certs` | 3 个 CA / 6 张 leaf | **数据驱动清单**，后续任务追加条目即可，无需改代码 |

## 幂等与自愈语义

判定逻辑集中在 `tasks/_needs_regen.yml`（`stat` + `openssl x509 -checkend` + 证书/私钥公钥比对）：

- 证书**有效**（不在续期窗口）且**与私钥匹配** → 全流程 skip，`changed=0`，不触碰文件；
- 证书缺失 / 无法解析 / 已过期或进入续期窗口 / 与私钥不匹配 → 重签；
- 私钥仅在**缺失或与证书不匹配**时重建（避免无谓密钥轮换）；
- 某 CA 本次被重建 → 由它签发的 leaf **强制重签**（用 CA 证书 sha256 前后对比判定）；
- **不在范围**：SAN 集合变化不自动触发重签，需 `pki_force_regen=true`（或删除旧证书）。

## 用法

```yaml
- hosts: k8s_master
  roles:
    - role: pki
```

测试（离线 + 沙箱真实执行，不触碰宿主 `/etc/kubernetes`）：

```bash
tests/pki/test_pki_role.sh      # 等价于 make test-pki
```

## 不在范围

kubeconfig 渲染（T007/T008）、控制面组件客户端证书（T006/T007）、kubelet 证书分发（T008/T014）、
CRL / 自动轮换编排 / 集群外 CA 注入。
