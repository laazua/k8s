# 交接摘要（Handoff）· T009

> 硬要求：**仅凭本文件 + `state.yaml` 就能继续工作**，不需要翻聊天记录。保持短。

- 时间：2026-11-04
- 角色：generator
- 当前任务：T009（kube-proxy role）
- 本次做了什么：
  1. 交付 `roles/kube-proxy`：**官方二进制 + systemd**（契约 §1.1 声明理由：registry 不可达 →
     DaemonSet 无法真实运行；二进制可真跑并完成 A9 验收）。变量化版本/sha256/路径/端口/
     `--cluster-cidr`（Pod CIDR）/proxy-mode/healthz/metrics/conntrack/iptables/ipvs。
  2. 安全默认：healthz/metrics 绑 `127.0.0.1`；kubeconfig `0600 root:root`（source 复制
     或 embedded 内嵌证书两分支）。
  3. fail-fast（落盘前）：proxy_mode 非法、cluster-cidr 缺失/非法、hostname 空、
     kubeconfig 缺失/为空、iptables 依赖缺失、ipvs 但 `/proc/net/ip_vs` 不存在、sha256 非法、
     安装后版本不匹配。
  4. 新增 `tests/kube-proxy/`（208 断言）：静态 A1–A10 + 动态 B0–B10；套件自动
     `sudo unshare -n`（仅 lo）内跑**真实** pki + etcd + kube-apiserver + kube-proxy，
     手工 Node/Service/EndpointSlice + 本地 mock HTTP，**实测 ClusterIP 返回 200**。
  5. `Makefile` 增 `test-kube-proxy` 并挂入 `make test`；契约 §5 声明全部受限项。
- 改了哪些文件：
  - `roles/kube-proxy/{defaults,tasks,templates,handlers,meta}/…, README.md`
  - `tests/kube-proxy/{test_kube_proxy_role.sh,inventory.ini,sandbox_stack.yml,sandbox_apiserver.yml,sandbox_kube_proxy.yml,real_kube_proxy.yml,README.md}`
  - `Makefile`（`test-kube-proxy` + 纳入 `test`）
  - `docs/harness/state/{contracts/T009.md,state.yaml,roadmap.md,handoff.md}`
- 怎么验证（给下一位）：
  ```
  make lint
  make test-kube-proxy            # 208/0；约 3–4 分钟（首次需外网预取制品）
  make test                       # 全量（约 40 分钟）
  ```
  动态证据：B5 `curl http://10.96.0.50/health` → `HTTP/1.0 200` + `MOCK-OK-T009`；
  B4 `iptables-save -t nat` 含 `KUBE-SERVICES` 与 `DNAT --to-destination 10.0.0.10:18080`；
  B8 连跑第二次 `changed=0`、无 handler、PID/starttime/哈希不变。
- 测试/幂等结果：红 `PASS=7 FAIL=17`（role 缺失）→ 绿 `PASS=208 FAIL=0`，连跑两次一致；
  全量 `make test` 一次 **rc=0 / 43m38s**（2026-11-05 复验），各套件
  27/39/59/100/225/186/269/291 + 新增 208 = **1404 断言全 PASS**，既有套件计数逐项与基线
  相同（无回退）；明细见契约 §8.1，日志 `/tmp/opencode/t009_verify_full.log`。
  交付首轮证据：`/tmp/opencode/t009_green{1,2}.log`、`/tmp/opencode/t009_full.log`。
- 复验记录（2026-11-05）：`make lint` rc=0；`make test-kube-proxy` 两次 rc=0（275s/273s，
  208/0，PASS 集仅沙箱目录名/PID 不同）；全量 `make test` 一次 rc=0（43m38s，1404/0）。
  测试后无残留 kube-proxy/apiserver/etcd 进程、无 netns、无 `/tmp/opencode/t009.*` 沙箱目录，
  宿主无 `/etc/kubernetes` 与 kube-proxy unit。
- 遗留问题 / 风险 / 待办：
  - 受限（契约 §5，均不得表述为「已验证」）：宿主 systemd `active/enabled`、多节点
    DaemonSet 调度、Pod 级 ClusterIP（无镜像/无 Pod）、专用 `system:kube-proxy` 凭据（T011）、
    ipvs 动态验证（宿主 `ip_vs` 未加载，仅 fail-fast）。
  - 测试夹具（非产品逻辑，契约 §5.6）：手工 Node、`lo` 上 `10.0.0.10/32` 与
    ClusterIP 网段 `dev lo` 路由、本地 mock HTTP 后端。
  - `ansible-lint` 仍不可得（repo-conventions §8），静态门禁为 syntax-check + yamllint。
  - T008 遗留（未在本次处理，避免越界）：证书身份不符缺定向 fail-fast 断言；
    `--cgroup-driver` 已弃用（T015）。
- 下一步建议（`state.yaml.next_action`）：`eval T009`。
