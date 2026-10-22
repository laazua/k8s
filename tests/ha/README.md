# tests/ha — T006 控制面高可用（haproxy + keepalived）测试

## 它验证什么

| 验收 | 方式 |
| --- | --- |
| 配置渲染 | ansible 在沙箱渲染 `haproxy.cfg` / `keepalived.conf`，逐项断言（`mode tcp`、`balance`、全部 `k8s_master` 后端、timeouts；`vrrp_instance`、`state`、`priority`、`virtual_router_id`、`virtual_ipaddress`、`interface`、`track_script`、`notify`） |
| 真实 VIP 漂移 | 两个 netns + veth 组成真实 L2；netns 内运行 **role 渲染出的** keepalived（priority 150/100）与 haproxy；停掉持有 VIP 的一侧 → VIP 漂移、`curl -k https://10.99.0.100:6443/healthz` 仍 `ok`；恢复后按 preempt 回切 |
| 真实负载均衡 | 两个 TLS mock backend（ID 不同）经 haproxy 分发；杀掉一个 backend → 健康检查摘除，请求仍成功且只落存活后端 |
| 幂等 | 同参数连跑两次：第二次 `changed=0`，运行中的 PID 不变、无 handler 重启 |
| fail-fast | 无 master 成员 / VIP 为空 / `virtual_router_id` 非法 / `ha_mode` 非法 / interface 为空 → 明确失败且不落配置 |
| 宿主零污染 | 不写 `/etc/{haproxy,keepalived}`、不 `systemctl`、宿主 6443/16443 不被占用；trap 清理 netns/veth/进程/临时目录 |

`kube-vip` 只验证 **配置渲染 + 前置校验**，真实漂移/选主**未验证**（见 `docs/harness/state/contracts/T006.md` §5）。

## 依赖与二进制获取

测试环境不把 haproxy/keepalived 安装进系统；用解包后的二进制（`/tmp/opencode/t006root` 是推荐前缀）：

```bash
tests/ha/provision_bins.sh          # dnf download + rpm2cpio 解包，不执行 rpm -i
export HAPROXY_BIN=/tmp/opencode/t006root/usr/sbin/haproxy
export KEEPALIVED_BIN=/tmp/opencode/t006root/usr/sbin/keepalived
export LD_LIBRARY_PATH=/tmp/opencode/t006root/usr/lib64:/tmp/opencode/t006root/usr/lib64/mariadb
```

注意：`sudo` 默认会清空环境变量；测试脚本内部用
`sudo env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ip netns exec ...` 传递。

若二进制缺失，测试会**明确 FAIL** 并打印上述步骤（不会静默 skip）。

其他依赖：
- `ansible-playbook`（Makefile 自动探测 `$ANSIBLE_PLAYBOOK` → `PATH` → `~/ansible/bin`）
- 免密 `sudo`（创建 netns/veth、以 root 运行 keepalived）
- `ip netns`、`openssl`、`curl`、`python3`

## 运行

```bash
tests/ha/test_ha_role.sh     # 直接运行
make test-ha                 # Makefile 目标
make test                    # 全量门禁（含本套件）
```

测试使用独立 netns（`t006ha1`/`t006ha2`）和 `veth-ha1`/`veth-ha2`，所有监听都在 netns 内；
不会影响宿主网络。`keepalived` 的 `enable_script_security` 要求脚本及父目录 root 拥有且
不可被 group/other 写，而 `/tmp` 是 1777，所以沙箱 playbook 以 `become: true` 运行，并把
`chk_haproxy.sh` / `notify.sh` 放在 `root:root` 的 `/run/t006-$$` 下（trap 清理）。
若上次异常中断留下 netns，可手动清理：

```bash
sudo ip netns del t006ha1 2>/dev/null || true
sudo ip netns del t006ha2 2>/dev/null || true
sudo pkill -9 -f '/tmp/opencode/t006\.' 2>/dev/null || true
sudo rm -rf /run/t006-*
```

当前套件共 **160** 条断言。

## 为什么需要 `-r/-c` 独立 pid 文件

keepalived 2.2.8 在启动前会检查默认的 `/run/vrrp.pid`（不受 `-p` 影响）。
同一台机器上运行第二个 keepalived 时必须传入 `-r <独立路径>`（测试脚本已处理），
否则第二个实例会以 `daemon is already running` 退出。生产每台主机只有一个实例，无此问题。
