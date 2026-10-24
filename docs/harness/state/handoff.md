# 交接摘要（Handoff）

> 仅凭本文件 + `state.yaml` 即可继续工作，无需翻聊天记录。
> 最新条目在最上方。

---

## [2026-10-24] Generator · T007 r1 修复 → ready_for_eval（build）

- 时间：2026-10-24
- 角色：Generator（独立复跑；未自判 PASS）
- 任务：`T007`（修复 r1 FAIL；被测代码提交 `056364f`）
- 本次做了什么：
  1. **B1**：`roles/kube-apiserver/templates/kubeconfig.j2` **重命名**为 `kubeconfig_file.j2` 并入库
     （`.gitignore` 一字未改，真实 kubeconfig/私钥忽略规则未放宽）；`tasks/kubeconfig_one.yml`、
     README、测试断言同步；套件新增 `templates_tracked()`（role 引用的每个 `src: *.j2` 必须
     `git ls-files --error-unmatch` 通过）。
  2. **B2**：`tests/skeleton/test_skeleton.sh` 密钥探针收紧为
     `(^|/)kubeconfig$|(^|/)kubeconfig\.(ya?ml|json|conf)$|\.kubeconfig$|\.key$|\.pem$|(^|/)vault[-_]?pass[^/]*$`，
     并加正例/负例自检 + 临时 git 仓库「真实 `kubeconfig` 必须仍被判为已跟踪」端到端负例。
  3. **M2**：B7 匿名断言改**严格 401**（`/api`、`/api/v1/namespaces`），契约 A9 同步。
  4. **M1**：新增 `tests/control-plane/real_services.yml`（三 role + `*_manage_service: true`），
     契约 §5.1 改为可执行命令（含 `cp inventory/hosts.example inventory/hosts.ini` 前置、
     期望输出、回滚），并声明 `playbooks/control-plane.yml` 仍是 T012 占位、不得用于复验。
  5. **M3/N2**：删 kubeconfig server 显式覆盖（改验默认 VIP 派生）；端口冲突端口可配
     `T007_TEST_CONFLICT_PORT`。**N1** 缓期至 T008（kubelet serving CA 未就绪）。**N3** 说明。
- 改了哪些文件（代码提交 `056364f`）：`roles/kube-apiserver/{README.md,tasks/kubeconfig_one.yml,
  templates/kubeconfig_file.j2}`、`tests/control-plane/{README.md,real_services.yml,
  sandbox_control_plane.yml,test_control_plane_roles.sh}`、`tests/skeleton/test_skeleton.sh`；
  本提交另含 `docs/harness/state/{contracts/T007.md,handoff.md,state.yaml,reports/T007-r1.md}`。
- 怎么验证（给下一位）：
  ```bash
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test              # 主工作区，期望 rc=0
  # 干净归档（证明提交自包含）：
  git archive 056364f | tar -x -C /tmp/opencode/t007fix/archive
  cd /tmp/opencode/t007fix/archive && git init -q && git add -A && git commit -qm archive
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test              # 期望 rc=0
  ```
- 测试结果（红→绿）：
  - 红：`afd7338` 归档跑 T007 `PASS=179 FAIL=88`（rc=1，`kubeconfig.j2` 缺失）；同提交 T001
    `PASS=26 FAIL=1`（rc=1，误报 `tasks/kubeconfig_one.yml`）。
  - 绿：主工作区 `make test` ×2 → rc=0（1857s/1867s），T001 **27**/T002 39/T003 59/T004 100/
    T005 225/T006 186/T007 **269**，`FAIL=0`；干净归档 `056364f` ×2 → rc=0（1872s/1866s），计数一致。
  - 匿名：两次复跑均 `严格 401，实际 401`。
  - 牙齿：旧宽泛正则 → T001 自检红（26/1）；删 `--anonymous-auth` → B7 两条 `实际 403` FAIL（264/5）。
  - 探针独立核验：正例 7/7、负例 5/5、临时仓库真实 `kubeconfig` 端到端命中。
- 遗留问题 / 风险 / 待办：
  - N1 `--kubelet-certificate-authority` 待 T008（kubelet serving CA 就绪后打开）。
  - systemd `active+enabled`、多主/VIP 串联、kubelet 侧仍未在真机动态验证（契约 §5.1–§5.3 已声明）；
    真机复验路径 `tests/control-plane/real_services.yml` 已可执行（`--syntax-check` exit 0）。
  - 纯 `git archive` 无 `.git`，T001 会报「非 git 仓库」（25/1，归档目录固有属性）。
- 收尾：无残留进程/端口/沙箱；宿主无 `kube-*.service`、无 `/etc/kubernetes`、无 `/var/lib/kubelet`；
  `git ls-files` 无真实密钥/证书/kubeconfig。
- 下一步建议（`state.yaml.next_action`）：`eval T007 (r2)`

---

## [2026-10-23] Evaluator · T007 r1 → FAIL（eval）

- 时间：2026-10-23
- 角色：Evaluator（独立只读评审；未改代码/测试/契约）
- 任务：`T007`（被测提交 `afd7338`，父 `6b619ce`）
- **结论：FAIL**（报告 `reports/T007-r1.md`）；六项硬指标 功能 **2** / 幂等 5 / 可配置 4 /
  测试 **3** / 结构 4 / 安全 4；产品完整度 3。2 BLOCKER + 2 MAJOR。
- **B1（BLOCKER）**：`roles/kube-apiserver/templates/kubeconfig.j2` 被 `.gitignore:7` 的 `kubeconfig.*`
  规则忽略、**未入库**（`git ls-tree afd7338` 只有 service.j2）。干净 worktree 跑 T007 套件：静态
  `FAIL 存在 templates/kubeconfig.j2`、`FAIL A5 渲染 kubeconfig`，首跑 fatal `Could not find or access
  'kubeconfig.j2'`；T1/T2/T3 干净检出分别为 `179/90`、`176/93`、`181/88`，**269/269 不可复现**。
- **B2（BLOCKER）**：`make test` 两次均 **rc=2**、T001 `PASS=26 FAIL=1`「git 跟踪了密钥类文件」——
  `tests/skeleton/test_skeleton.sh:99` 的 `kubeconfig` 宽泛正则命中新任务文件
  `tasks/kubeconfig_one.yml` / `tasks/kubeconfigs.yml`；父提交 T001=27/0。Generator 声称的
  「全量门禁 ×2 绿」在提交后不成立（开发期这两个文件尚未被 git 跟踪，`git ls-files` 看不到）。
- 复现：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` ×2（均 rc=2）；主工作区单套件
  `PASS=269 FAIL=0`（6m26s，但依赖未跟踪文件）。
- **真实控制面独立核验（开发树）**：三进程真实存活；`/healthz`=`ok`、`/readyz`=`ok`；`get ns` 含
  default/kube-system；cm/scheduler lease 存在且被持有；匿名 `/api`、`/api/v1/namespaces` 均 **401**；
  三份 kubeconfig `0600 root:root`，身份 `kubernetes-admin/system:masters`、
  `system:kube-controller-manager`、`system:kube-scheduler`；进程参数实测
  `--anonymous-auth=false`、`--authorization-mode=RBAC,Node`、`NodeRestriction`、SA/TLS flags。
  默认 VIP 派生独立验证：`k8s_vip=10.0.0.100:19443` → server `https://10.0.0.100:19443`；
  第二次运行 `changed=0`，`--check` `changed=0`。
- **牙齿 5/5 被捕获**（独立 worktree，主工作区 clean；均先补回未入库模板）：T1 删 anon flag
  `263/6`（但 HTTP 匿名断言仍 PASS，实际 403 → M2）；T2 AlwaysAllow `266/3`；T3 scheduler 用 admin
  证书 `268/1`（命中身份断言）；T4 etcd 指向 12399 `253/16`（healthz/readyz/ns 明确 FAIL）；
  T5 强制 changed `267/2`（changed=0 + handler 断言）。
- **M1（MAJOR）**：契约 §5.1「真机复验（必做）」命令指向 `playbooks/control-plane.yml`，但该 playbook
  仍是占位 debug（0 个 role 任务），命令 exit 0 却什么也不部署；A6 受限项无可执行复验路径。
- **M2（MAJOR）**：B7 匿名断言接受 401 或 403，删 `--anonymous-auth=false` 后 `/api` 返回 403 仍被判
  PASS；应改断言 401 或改用 `/healthz`。
- 收尾：无残留进程/端口/沙箱；宿主无 `kube-*.service`、无 `/etc/kubernetes`、无 `/var/lib/kubelet`；
  `git ls-files` 无 `.key/.crt/.pem`；主工作区 clean。其余套件单跑全绿：T002 `39/0`、T003 `59/0`、
  T004 `100/0`、T005 `225/0`、T006 `186/0`、T007 `269/0`（开发树）——唯一红的是 T001（B2）。
- 变更：`reports/T007-r1.md`（新增）、`state.yaml`（`changes_requested` / `eval_round: 1` /
  `active_task: T007` / `next_action: "build T007 (fix r1)"` / `phase: BUILDING` / blockers）、本文件。
  `roadmap.md` T007 保持 `in-progress`（FAIL 不勾选）。
- 下一步：`build T007 (fix r1)`——先 B1（模板入库 + 干净检出复跑 269）、再 B2（收紧 T001 探针）、
  M2（严格 401）、M1（可执行真机复验 playbook），重跑 `make test` ×2 与干净 worktree 套件后交 r2。

---

## [2026-10-23] Generator · T007 → ready_for_eval（build）

- 时间：2026-10-23
- 角色：Generator（harness-generator；只做 T007，**不自判 PASS**）
- 任务：`T007` 控制平面组件 role（`kube-apiserver` / `kube-controller-manager` / `kube-scheduler`）
- **做了什么**
  1. 三个 role：官方二进制 + sha256 + 版本断言 → 安全默认 unit（`--anonymous-auth=false`、
     `--authorization-mode=RBAC,Node`、TLS client CA、SA 签名、NodeRestriction）→ systemd 接线。
  2. 控制面引导集中在 `kube-apiserver`：用 kubernetes-ca 签发 cm / scheduler /
     `apiserver-kubelet-client` 三张客户端证书，渲染 `admin.conf` / `controller-manager.conf` /
     `scheduler.conf`（证书内嵌、0600 root:root、server 默认 `https://<VIP>:<port>`）。
  3. fail-fast：地址/端口、安全默认、etcd endpoint、PKI/SA 文件、sha256、端口冲突、版本不匹配；
     cm/scheduler 缺失 kubeconfig 即失败（只消费不签发）。
  4. 测试 `tests/control-plane/`：真实 pki + 单成员 TLS etcd + 从 unit ExecStart 真实拉起三进程
     （高位端口 16443/20257/20259），覆盖 healthz/readyz/ns/匿名 401/身份/leader lease/
     幂等/fail-fast 矩阵/宿主零污染；`Makefile` 增加 `test-control-plane` 并挂入 `make test`。
- **改了哪些文件**
  - `roles/kube-apiserver/`（含 README）、`roles/kube-controller-manager/`、`roles/kube-scheduler/`
  - `tests/control-plane/{inventory.ini,sandbox_stack.yml,sandbox_control_plane.yml,test_control_plane_roles.sh}`
  - `Makefile`、`docs/harness/state/contracts/T007.md`、`state.yaml`、`roadmap.md`、本文件
- **怎么验证（给下一位）**
  ```bash
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK tests/control-plane/test_control_plane_roles.sh
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test   # 连跑两次
  ```
- **测试/幂等结果**：红 `PASS=15 FAIL=123`（role 移走）→ 绿 `PASS=269 FAIL=0`；
  运行中重跑 `changed=0`、无 handler、PID/starttime/unit/kubeconfig 哈希不变；
  fail-fast 6/6 且 unit 不变。全量门禁两次 exit 0：`27/39/59/100/225/186/269`，`FAIL=0`。
- **遗留问题 / 风险 / 待办**
  - systemd `active+enabled` 未在宿主真实执行（共享机限制）；已静态断言 + 用 unit ExecStart
    真实起进程，真机复验命令见契约 §5.1。
  - 未动态验证多 master / 经 VIP 串联（T010/T012/T014）；kubelet 侧认证属 T008。
  - 测试沙箱以此前不存在的 `$SB/var`、`$SB/etc` 预创建 0755（否则 uid 65534 的 etcd 与
    非 root 读 unit 会失败），属测试基座而非 role 逻辑。
  - 观察到 apiserver 对 loopback advertise-address 的 `kubernetes` Endpoints 报
    `may not be in the loopback range`；不影响 healthz/readyz/ns（测试端口/地址使然）。
- **下一步建议（`state.yaml.next_action`）**：`eval T007`

---

## [2026-10-23] Evaluator · T006 r2 PASS（eval）

- 时间：2026-10-23
- 角色：Evaluator（独立评估；未改代码/测试/契约）
- 任务：`T006` 第 2 轮（被测 `6b619ce`，r1=`4e6c503` FAIL）
- **结论：PASS**（功能 5 / 幂等 5 / 可配置 4 / 测试 5 / 结构 4 / 安全 4 / 完整度 4）
- B1 复核：默认路径 `/etc/haproxy/haproxy.cfg`、`/etc/keepalived/keepalived.conf`；
  沙箱重定向下 `渲染 == drop-in ExecStart -f == Environment CONFIG` 三方相等，且与解包发行版 unit
  (`Type=notify`、haproxy `CONFIG=/etc/haproxy/haproxy.cfg`、keepalived `--dont-fork`) 对齐；
  反证（drop-in 改 `/etc/haproxy/wrong.cfg`）→ `PASS=167 FAIL=19`，断言精确命中。
- M1 复核：kube-vip manifest 含 `manager`、`hostNetwork`、`system-node-critical`、`NET_ADMIN/NET_RAW`、
  kubeconfig hostPath、`vip_nodename`；契约 §5.3 / README 均声明「仅渲染、未验证真实漂移」。
- 独立动态（自建 netns/inventory，直接启动 role 渲染产物）：**70/70 PASS**；VIP 初始 e1、停持有者漂移、
  preempt 回切、track_script 摘除、LB 12/12（6/6）、后端摘除 8/8、运行中重跑 `changed=0` 且 PID/sha 不变。
- 全量门禁：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` 两次 exit 0，计数一致
  `27/39/59/100/225/186`（636），`FAIL=0`；T001–T005 无回退。
- 牙齿 6/6：路径不一致 / 删 `-f` / VIP 写死 / 去 `check` / 强制 changed / 删 `NET_RAW`，全部 rc=1。
- 非阻塞项：keepalived drop-in 可补清空 `ExecStartPre/ExecReload`；`haproxy_config_dir` 未由
  `haproxy_config_file` 派生；测试固定 netns 名；systemd 运行需真机/T007 复验。
- 宿主零污染：无 netns/veth/进程/端口/`/run` 残留；无 `/etc/{haproxy,keepalived,kubernetes}`；主工作区 clean。
- 下一步：`build T007`（控制平面编排；注意 §5.4 端口协调、T005 的 etcd `serial: 1`）。

---

## [2026-10-22] Generator · T006 修复轮 r1 → ready_for_eval（build）

- 时间：2026-10-22
- 角色：Generator（harness-generator 子会话；只做 T006，不自判 PASS）
- 任务：`T006`（r1 修复 `reports/T006-r1.md` 的 B1 + M1 + MINOR/NIT）
- **做了什么**
  - **B1**：haproxy/keepalived 默认配置路径改为服务约定：
    `roles/haproxy/defaults/main.yml` → `<prefix>/etc/haproxy/haproxy.cfg`；
    `roles/keepalived/defaults/main.yml` → `<prefix>/etc/keepalived/keepalived.conf`；
    仍可用 `*_config_file` 覆盖，`base_root_prefix`/`*_root_prefix` 整体沙箱重定向（去尾斜杠）。
  - **新增 systemd drop-in**（`templates/systemd-dropin.conf.j2`，
    `/etc/systemd/system/<svc>.service.d/10-role-config.conf`）：显式重写 `ExecStart`（`-f` 同一变量），
    haproxy 同时设 `Environment="CONFIG=<同一变量>"` 并清空 `$CFGDIR` 引用；service/handler `daemon_reload: true`。
    渲染路径 == unit 引用路径 == 约定路径（测试三方交叉断言）。
  - **M1**：`kube-vip.yaml.j2` 补齐 `command`+`args: ["manager"]`、`hostNetwork`、
    `priorityClassName: system-node-critical`、`NET_ADMIN`/`NET_RAW`、kubeconfig hostPath 挂载
    （`kube_vip_kubeconfig`，默认 `/etc/kubernetes/admin.conf`）、`vip_nodename` downward API +
    leader-election 时长；README/契约说明静态 Pod 无需额外 RBAC（DaemonSet 需自建）。
  - **MINOR/NIT**：bind 复用 `k8s_lb_bind_address`；删除死变量与重复 pidfile/daemon；README 修正并标注
    T007 前 playbook 占位；端口快照加 80/443。
- **TDD 红→绿**
  - 红：`/tmp/opencode/t006r1_red.log` **PASS=117 FAIL=69**（exit 1）——新路径/一致性/drop-in/kube-vip 字段断言全红。
  - 绿：`/tmp/opencode/t006r1_green2.log` **PASS=186 FAIL=0**（exit 0）。
  - 牙齿（改路径→红）：`/tmp/opencode/t006r1_teeth.log` **PASS=145 FAIL=39**，两处变异分别命中
    `H drop-in ExecStart 显式 -f 渲染路径` 与 `K defaults 默认路径 = 服务约定…`；还原后 sha256 不变。
- **全量门禁**：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` 两次均 **exit 0**，计数一致：
  `27/39/59/100/225/186`，合计 **636**，`FAIL=0`（T001–T005 未回退；T006 因新增断言 160→186）。
- **动态复验（测试内真实 netns）**：VIP 初始 ha1、停 keepalived 漂移 ha2、停 haproxy 整机故障、
  恢复 preempt 回切、12 次 LB 命中双后端、杀后端后 8/8 仅落存活后端、运行中重跑 `changed=0` 且
  haproxy/keepalived PID 与配置 sha256 不变——全部 PASS；测试**从 drop-in 解析路径启动**，
  确保跑的是 unit 会引用的文件。
- **宿主收尾**：无 netns/veth/HA 进程/`/run/t006-*`/`/run/vrrp.pid`；无 `/etc/{haproxy,keepalived,kubernetes}`；
  80/443/6443/16443 无监听；无密钥文件。
- **遗留/风险**：systemd 运行（enable/start/daemon-reload）与包样例覆盖仍属真机复验项（契约 §5.2）；
  kube-vip 仅渲染、未真实漂移（§5.3）；同机端口协调归 T007（§5.4）。
- **下一步**：`eval T006 (r2)`。`state.yaml` 置 `ready_for_eval` / `phase: EVALUATING`；
  `roadmap.md` T006 保持 `in-progress`。

---

## [2026-10-22] Evaluator · T006 评估第 1 轮 → FAIL（eval）

- 时间：2026-10-22
- 角色：Evaluator（harness-evaluator 独立子会话；只读评审，未改任何代码/测试/契约）
- 当前任务：`T006`（被测提交 `4e6c503`）
- **结论：FAIL**（报告 `reports/T006-r1.md`）；六项硬指标 功能 **3** / 幂等 **5** / 可配置 **3** /
  测试 4 / 结构 4 / 安全 4；产品完整度 3。阻塞 **B1** + MAJOR **M1** + 4 个 MINOR + NIT。
- 复现：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` **连跑两次**均 exit 0；
  T001 `27` / T002 `39` / T003 `59` / T004 `100` / T005 `225` / T006 `160`，合计 **610**，`FAIL=0`。
  独立动态（自建 netns/veth + role 渲染配置）`PASS=48 FAIL=0`：VIP 漂移 **699 ms**、
  preempt 回切 **3648 ms**、LB 20/20（10/10）、杀后端 **5013 ms** 摘除后 20/20 只落存活后端；
  fail-fast 7/7 明确失败；TDD 红 `38/118` → green4 `160/0`。牙齿实验 5/5 变异均被捕获
  （删 server 行 151/9、写死 VIP 145/15、去 check 151/9、破坏幂等 158/2、强制 nopreempt 158/2）。
- **B1（BLOCKER）**：role 渲染到 `/etc/kubernetes/{haproxy,keepalived}`，但发行版 systemd
  haproxy 读 `CONFIG=/etc/haproxy/haproxy.cfg`、keepalived 默认读 `/etc/keepalived/keepalived.conf`；
  按默认 `manage_service=true` 时服务不会加载 role 配置，可能启动包样例（keepalived 样例含
  `state MASTER`、vrid 51、VIP `192.168.200.16-18`）。测试 `manage_service=false` + 手动 `-f`
  掩盖了该路径，且 `tests/ha/test_ha_role.sh:109-110` 反向禁止默认路径。
- **M1（MAJOR）**：kube-vip 清单缺 `args: ["manager"]`、kubeconfig 挂载、NET_ADMIN/NET_RAW capabilities。
- 宿主收尾：无 netns/veth/HA 进程/`/run/t006-*`；`/etc/{haproxy,keepalived,kubernetes}` 不存在；
  80/443/6443/16443 无监听；route md5 与 iptables 规则集前后一致；回归/密钥检查通过。
- 变更：`docs/harness/state/reports/T006-r1.md`（新增）、`state.yaml`
  （`changes_requested` / `eval_round: 1` / `active_task: T006` / `phase: BUILDING` /
  `next_action: "build T006 (fix r1)"` / `blockers`）、本文件。
  `roadmap.md` T006 保持 `in-progress`（FAIL 不勾选）。
- 下一步：`build T006 (fix r1)`——先修 B1（改默认配置路径或写 systemd drop-in，并覆盖包样例），
  再补 M1，更新测试（去掉默认路径禁令、断言有效 unit 配置路径、端口快照加 80/443），
  重跑两次 `make test` + `test_ha_role.sh` 后交 r2。

---

## [2026-10-22] Generator · T006 -> ready_for_eval（build）

- 时间：2026-10-22
- 角色：Generator
- 当前任务：`T006`（控制面高可用 role · LB + VIP）
- 本次做了什么：
  - 新增 `roles/haproxy`：从 inventory `[k8s_master]` 推导后端，渲染 `haproxy.cfg`
    （`mode tcp`、`balance roundrobin`、每 master `server ... check inter/fall/rise`、
    connect/client/server timeouts），包安装/二进制断言、systemd 启停、变更才重启。
  - 新增 `roles/keepalived`：VRRP VIP（priority 按 inventory 推导或 host var 覆盖）、
    `virtual_router_id`/`advert_int`/PASS 认证、`virtual_ipaddress = k8s_vip`、
    `track_script` 检查本机 haproxy pid、`notify_master/backup/fault` 写状态日志；
    `ha_mode=kube-vip` 渲染静态 Pod 清单 + 前置校验（真实漂移未验证）。
  - 新增 `tests/ha/`：`test_ha_role.sh`（160 断言）、`sandbox.yml`、`inventory.ini`、
    `mock_backend.py`（TLS mock）、`provision_bins.sh`（dnf download + rpm2cpio 解包，不安装）、
    `README.md`。用 **2 netns + veth** 真实运行 role 渲染的 keepalived/haproxy：
    VIP 初始 ha1(150) → 停 ha1 keepalived → 漂移 ha2 → 停 ha1 haproxy → 恢复 → preempt 回切；
    haproxy 12 次请求命中两个后端；杀一个后端后连续 5 次只落存活后端。
  - `Makefile` 接入 `test` 与 `test-ha`；`do` 未改 `site.yml`（编排属 T007）。
- 改了哪些文件：
  `roles/haproxy/**`、`roles/keepalived/**`、`tests/ha/**`、`Makefile`、
  `docs/harness/state/contracts/T006.md`、`state.yaml`、`roadmap.md`、本文件。
- 怎么验证（给下一位）：
  ```
  tests/ha/test_ha_role.sh
  make test-ha
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test   # 连跑两次
  ```
  若二进制缺失：`tests/ha/provision_bins.sh`，然后
  `export HAPROXY_BIN=/tmp/opencode/t006root/usr/sbin/haproxy`
  `export KEEPALIVED_BIN=/tmp/opencode/t006root/usr/sbin/keepalived`
  `export LD_LIBRARY_PATH=/tmp/opencode/t006root/usr/lib64:/tmp/opencode/t006root/usr/lib64/mariadb`
- 测试/幂等结果：
  - 红：`tests/ha/test_ha_role.sh` → `PASS=38 FAIL=118`（role 不存在）。
  - 绿：`PASS=160 FAIL=0`；第二次渲染 `changed=0`，运行中 haproxy/keepalived PID 不变。
  - 全量门禁连跑两次均 exit 0，计数一致：T001 `27` / T002 `39` / T003 `59` /
    T004 `100` / T005 `225` / **T006 `160`**，合计 **610**，`FAIL=0`。
- 遗留问题 / 风险：
  - netns 是单内核 L2 模拟，**不等价于多机 HA**；真实网卡/交换机、防火墙 112、云 ARP/BGP 未验证。
    真机复验步骤见 `contracts/T006.md` §5.1。
  - `kube-vip` 仅配置渲染 + 前置校验，**真实漂移/选主未验证**（§5.3）。
  - systemd 与包安装未验证（测试用解包二进制直接启动；§5.2）。
  - 同机 haproxy 与 apiserver 的 6443 端口协调留给 T007（§5.4）。
  - T005-r2 MINOR 下传：**任何 etcd 重启编排必须 `serial: 1`**（§5.5）。
- 下一步建议（`state.yaml.next_action`）：`eval T006`

---

## [2026-10-21] Evaluator · T005 评估第 2 轮 → PASS（eval）

- 时间：2026-10-21
- 角色：Evaluator（harness-evaluator 独立子会话；只读评审，未改代码/测试/契约）
- 当前任务：`T005`（被测 `d24f1a1`，父 `aa35184`）
- **结论：PASS**（报告 `reports/T005-r2.md`）；六项硬指标
  **功能 4 / 幂等 5 / 可配置 4 / 测试 4 / 结构 4 / 安全 5**，产品完整度 4；**0 阻塞**、2 MINOR、3 NIT。
- 复现：
  - `env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` 连跑两次均 **exit 0**；
    T001 `27` / T002 `39` / T003 `59` / T004 `100` / **T005 `225`**，合计 **450**，`FAIL=0`；归一化 diff **0 行**。
  - 独立复现（`/tmp/opencode/t005r2_indep/`，自建 inventory/playbook、端口 13379/14379/15379）：
    pki 源 `root:root 700/600`、分发 `root:65534 750/640/644`；3 进程 uid=65534；health 3/3、
    member list=3、leader 唯一、put/get；kill 一成员→2/3 写成功→拉起 3/3 且数据在；
    运行中重跑 `changed=0`、PID+`/proc` starttime 不变。
  - 牙齿（全部独立 worktree）：B1 变异 42 FAIL；B2 变异 `nobody:nobody 755/644`；
    删奇数校验 + `min_members=1` 下 2 成员 rc=0 且渲染 unit；删 `--data-dir`/TLS flags 的 unit 断言必红；
    6 组实验后主工作区保持 clean。
- **MINOR（非阻塞，必须下传 T006）**：
  - D3 的 role 层“第二道防线”不成立：`throttle: 1` 只串行 restart 任务，`wait_member_healthy` 是后续任务。
    无 `serial: 1` 的 3 主机 play 中 3 个成员会先全部重启，之后才做 quorum 闸门；
    107 次采样 min_healthy=**1**，handler 仍 exit 0（`/tmp/opencode/t005r2_indep/multi.log:295,303`）。
    公开测试用 `tests/etcd/sandbox.yml:37 serial: 1` 掩盖了该语义；README:131-134 / 契约 §5.2 表述过强。
  - 建议：把“单成员 restart+wait”收进同一 `throttle: 1` 临界区（或用 assert 检测 play batch），
    或明确“必须 `serial: 1`”并在 **T006/T007 的 etcd 重启 play 显式设置 `serial: 1`**。
- 宿主收尾：无 etcd 进程、所有测试端口释放；`/etc/systemd/system`、`/usr/local/bin` 仍 `root:root 755`；
  `/var/lib/etcd`、`/etc/kubernetes` 不存在；无宿主 etcd unit；worktree 已全部移除。
- 变更：`state.yaml`（`accepted` / `eval_round: 2` / `done_tasks: 5` / `active_task: T006` / `next_action: build T006`
  / `phase: BUILDING` / `blockers: []`）、`roadmap.md` T005→done、本文件、`reports/T005-r2.md`。
- 下一步：`build T006`（控制面 LB+VIP）；开工前读 `reports/T005-r2.md` §5 MINOR-1，etcd 重启编排必须带 `serial: 1`。

---

## [2026-10-21] Generator · T005 修复第 1 轮 → ready_for_eval（build）

- 时间：2026-10-21
- 角色：Generator（TDD：先写会失败的断言，再实现；**未自判 PASS**）
- 当前任务：`T005`（响应 `reports/T005-r1.md` 的 B1/B2、D3、D4/D5、D6–D8）
- **交付/改动**：
  - `roles/etcd/defaults/main.yml`：删除单一 `etcd_file_owner`，改为三段属主
    `etcd_root_owner/group`（root：unit/二进制/制品/分发父目录）、`etcd_data_owner/group`（服务用户：数据目录）、
    `etcd_cert_owner/group`（root + 服务组：证书分发）；新增 `etcd_pki_share_dir`、`etcd_cert_{dir,mode,key_mode}`、
    `etcd_runtime_*`、`etcd_restart_health_{retries,delay}`、`etcd_service_restart_argv`（仅测试）。
  - 新增 `roles/etcd/tasks/certs.yml`（B1）：**不改 pki 源**，复制 CA/server/peer 5 文件到分发目录
    （目录 `root:<etcd 组> 0750`、私钥 `0640`、证书 `0644`），role 内 `stat` 断言私钥 uid=0/mode=0640。
  - `roles/etcd/tasks/{binary,config}.yml`、`templates/etcd.service.j2`（B2）：系统路径统一 root；
    unit `0644`、二进制 `0755`、数据目录服务用户 `0700`；unit 增加 `Group=`/`SupplementaryGroups=`，
    TLS flag 指向分发目录。
  - 新增 `roles/etcd/tasks/rolling_restart.yml` + `wait_member_healthy.yml`（D3），`handlers/main.yml` 改为调用；
    `throttle: 1` 串行、每成员重启后等本成员 health + 校验 healthy 端点数 `>= etcd_quorum`，失败即中止。
  - `roles/etcd/tasks/facts.yml`：新增 `etcd_cluster_client_urls`、`etcd_quorum`、`etcd_healthcheck_args`。
  - `tests/etcd/test_etcd_role.sh`：扩充到 **225 条**断言；`sandbox.yml` 以 root 应用生产属主、
    以真实非 root uid（`setpriv`）启动；新增 `inventory_even4.ini`。
    D4 用 `/proc/<pid>/stat` starttime；D5 在 `etcd_min_members=1` 下跑 2/4 成员；
    B1 断言服务 uid 可读分发私钥但**不可读 pki 源私钥**；B2 用 `stat` 断言属主且宿主目录未被 chown。
  - `roles/etcd/README.md`：补「权限模型」表、变量表、滚动重启语义、真机 `sudo -u etcd test -r` 复验。
  - 契约 `contracts/T005.md`：§4 增 A24–A27；§5.1–5.3 写明权限模型/滚动/受限；§6.2 真机步骤；
    §9.4 红绿；§10.1/10.4–10.6 修复记录与两次门禁。
- **TDD 红 → 绿**：
  - 红（新断言对旧实现）：`/tmp/opencode/t005_red_r1fix.log`，已执行断言 **`PASS=62 FAIL=89`**；
    B1/B2/D3/D4 均已红；旧实现无法以非 root 启动集群（`PermissionError` 读 unit），后续用例无意义，测试被终止（如实记录）。
  - 绿：`tests/etcd/test_etcd_role.sh` → `/tmp/opencode/t005green2.log`，**`PASS=225 FAIL=0`，exit 0**（约 8m40s）。
- **全量门禁（连跑两次）**：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test`
  - `/tmp/opencode/t005fix_make1.log`、`t005fix_make2.log`，两次均 **exit 0**（rc=0）。
  - 计数：T001 `27` / T002 `39` / T003 `59` / T004 `100` / **T005 `225`**，合计 **450**，`FAIL=0`；
    T001–T004 无回退（首轮 T005 为 152，合计 377）。
- **真实滚动重启/非 root 验证**：3 进程 uid=65534；运行中重跑 `changed=0`、PID 与 starttime 不变；
  `etcd_heartbeat_interval=150` → 3 个成员逐个重启（etcd1→etcd2→etcd3），每次均有 health 等待与 quorum 校验，
  后台采样 quorum 最小值 `>=2`，重启后 3/3 healthy、PID 全变、数据不丢、leader 唯一；同配置再跑 `changed=0` 且无 handler。
- **宿主收尾**：无 etcd 进程；12379/22379/32379 与 12380/22380/32380 空闲；`/etc/systemd/system`、`/usr/local/bin`
  仍 `root:root 0755`；无宿主 etcd unit；`/var/lib/etcd` 不存在；沙箱（含调试 `t005dbg2.*`）已清理。
  **未修改** `roles/pki`、`tests/pki`（B1 选择分发而非放宽 pki，理由见契约 §5.1/§10.5）。
- 改了哪些文件：上述 role/test/README + `contracts/T005.md` + `state.yaml` + 本文件；
  `reports/T005-r1.md` 为 Evaluator 产物，未修改、未提交。
- 下一步：`eval T005 (r2)`（`state.yaml`：`ready_for_eval` / `EVALUATING` / `next_action: eval T005 (r2)`；
  `roadmap.md` T005 保持 `in-progress`）。

---

## [2026-10-21] Evaluator · T005 评估第 1 轮 → FAIL（eval）

- 时间：2026-10-21
- 角色：Evaluator（harness-evaluator 独立子会话；只读评审，未改任何代码/测试/契约）
- 当前任务：`T005`（被测提交 `aa35184`）
- 结论：**FAIL**（报告 `reports/T005-r1.md`）；六项硬指标 功能 3 / 幂等 5 / 可配置 4 / 测试 4 / 结构 4 / **安全 2**；产品完整度 3；阻塞 2（B1/B2）+ MAJOR 1 + MINOR 2 + NIT 3。
- 复现：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` **连跑两次**均 exit 0；T001 `27`、T002 `39`、T003 `59`、T004 `100`、T005 `152`，`FAIL=0`；归一化 ANSI/沙箱路径/PID 后两次日志 `diff` **0 行**。TDD 红态 `PASS=14 FAIL=32` 独立复现，与契约 §9.1 一致。
- **独立真实集群（自建 inventory/playbook，不复用仓库测试断言）**：3 成员 TLS 集群 health 3/3、`member list`=3、leader 唯一、put/get 往返；`kill -9` 一个成员 → 2/3 healthy 且 put 成功、member list 仍 3 → 同一 unit 重新拉起 → 3/3 healthy、故障前后 key 均可读、leader 唯一；运行中重跑 `changed=0`、3 个 PID 的 `/proc` starttime 不变；配置变更 changed=3 + handler，同配置再跑 `changed=0`；TLS off 3 成员 HTTP 集群 health 3/3；2/4/1 成员、空成员、TLS 缺失、错 sha256 全部 fail-fast 且未落盘。
- **牙齿实验 5/5 被捕获**（临时 `git worktree`，主工作区 clean；仅做端口/日志前缀机械隔离，未改断言）：T1 少成员 → 138/14（A4/A6/A7/A8/A10/A11/A15/A18）；T2 删 sha256 → 78/73（安装失败级联）；T3 删奇数校验+min=1 → 146/6（A12 4 条）；T4 每次强制变更 → 146/6（A14/A15/A16/A17）；T5 删 `--data-dir` → 147/5（A4×3 + A18）。
- **阻塞缺陷**：
  - **B1（BLOCKER）**：生产 unit `User=etcd` 无法读 T004 默认生成的 `root:root 0600` etcd server/peer 私钥（目录 0700）；以非 root 用户按 unit 参数启动 etcd 实测 `open .../peer.crt: permission denied`。测试用 `pki_file_owner: omit` + 同用户运行完全绕过。修法：etcd role 对 etcd 证书/私钥做 `etcd:etcd 0600` 授权（或 pki `root:etcd 0640` + `SupplementaryGroups=etcd`），并加非 root 读/启动测试（`roles/pki/defaults/main.yml:29,32-33`、`templates/etcd.service.j2:9`、`tests/etcd/sandbox.yml:18-20`）。
  - **B2（BLOCKER）**：role 用 `etcd_file_owner`（默认 etcd）对 `/etc/systemd/system`、`/usr/local/bin`、unit 文件与二进制 chown；unit 0644 由 etcd 拥有 → 服务用户可改自己的 unit/替换二进制，提权面。实测把 root:root 的沙箱目录跑成 `zhangsan:zhangsan`（代表默认 etcd）。修法：数据目录用 etcd，系统目录/unit/二进制保持 root:root；用 `stat` 断言属主（`defaults/main.yml:31,57,60,67-72`、`tasks/binary.yml:11-25`、`tasks/config.yml:18-34`、`tests/etcd/sandbox.yml:32-35`）。
- 其他缺陷：D3（MAJOR）配置变更时所有成员同时重启、无滚动/编排保护；D4（MINOR）A15 PID 断言比较 shell 变量而非 `/proc`；D5（MINOR）A12 奇数校验仅靠文案兜住（默认 min=3 也拒绝 2）；D6–D8（NIT）契约/README 未显式声明 `User=etcd` 私钥可读前提、A2 未验 etcdctl/etcdutl 权限、`etcd_file_owner` 未文档化。
- 诚实性：契约 §5 如实声明单机多实例 ≠ 多主机 HA、未真实 systemctl、未验证真实 systemd；未把渲染断言说成 systemd 已生效。宿主零污染：`/etc/systemd/system/etcd*.service` 0、`/var/lib/etcd` 与 `/usr/local/bin/etcd*` 不存在、无残留进程/端口；`git ls-files` 无 `.key/.crt/.pem`；未改 T001–T004 资产。
- 改了哪些文件：`docs/harness/state/reports/T005-r1.md`（新增）、`state.yaml`（changes_requested / eval_round 1 / active_task T005 / phase BUILDING / next_action build T005 (fix r1)）、本文件。`roadmap.md` T005 保持 `in-progress`（FAIL 不勾选）。
- 下一步：`build T005 (fix r1)`——先修 B1/B2（证书属主与系统目录属主分离），补非 root 读取/启动与 `stat` 属主断言，再重跑两次 `make test` + 牙齿/独立探针。

---

## [2026-10-20] Generator · T005 实现完成 → ready_for_eval

- 时间：2026-10-20
- 角色：Generator（TDD：先红后绿；未自判 PASS）
- 当前任务：`T005`（etcd 集群 role）
- 交付物：
  - `roles/etcd/`（`defaults/main.yml`、`tasks/{facts,validate,binary,config,service,main}.yml`、
    `handlers/main.yml`、`templates/etcd.service.j2`、`meta/main.yml`、`README.md`）——
    官方二进制（URL + 强制 sha256，复用 `download` role 的缓存/代理）+ systemd unit；
    成员唯一来源 = inventory `etcd` 分组或 `etcd_members`；版本/端口/数据目录/token/TLS 与证书路径全变量化；
    TLS 默认 true（pki 的 etcd CA/server/peer，`--client-cert-auth` 双向认证）。
  - `tests/etcd/`（`test_etcd_role.sh` 152 断言、`sandbox.yml`、`inventory.ini`(3 成员)、
    `inventory_even.ini`(偶数负例)、`unit_exec.py`）。
  - `Makefile`：`test` 串入 etcd 套件 + 新目标 `make test-etcd`。
  - `docs/harness/state/contracts/T005.md`（A1–A23 + 红/绿/自测证据 + 受限声明）。
- TDD 红→绿：
  - 红：`tests/etcd/test_etcd_role.sh` → `PASS=14 FAIL=32`，exit 1（role 不存在，脚本快速失败）`/tmp/opencode/t005_red.log`。
  - 实现中真实红：①`unarchive` 要求 dest 已存在；②`changed_of` 只取末条 recap（TLS-off 集群漏建 logs 目录）。
  - 绿：`PASS=152 FAIL=0`，exit 0 `…/t005_green4.log`。
- 真实集群实测（沙箱 3 实例，端口 12379/22379/32379，peer 12380/22380/32380）：
  `endpoint health` 3/3 healthy；`member list`=3；leader 唯一；`put/get` 正常；
  `kill -9 etcd2` → 2/3 仍有 quorum 可写、member list 仍为 3 → 按同一 unit 的 `ExecStart` 重新拉起 →
  3 端点恢复 healthy、故障前后 key 均可读、PID 变化；运行中重跑 `changed=0`、无 handler、PID 不变；
  `etcd_heartbeat_interval` 变更 → `changed>=1` + `etcd:restart` 被通知；`etcd_tls_enabled=false` → HTTP 3 成员 healthy；
  偶数成员（2）→ exit≠0 且报「必须为奇数（当前 2）」；TLS 证书缺失 → fail fast；离线缓存命中 → exit 0 且 `changed=0`。
- 全量门禁（`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` 连跑两次）：
  两次均 **exit 0**；`27 / 39 / 59 / 100 / 152`，`FAIL=0`；归一化后两次日志 `diff` **0 行**；
  运行后宿主无 etcd 进程、测试端口空闲、沙箱目录已清理。
- 共享开发机安全：未写 `/etc/systemd/system`（`etcd_manage_service=false` 只渲染 unit，测试从 `ExecStart` 直接拉起）、
  未占用 2379/2380、未创建 `/var/lib/etcd` 与 `/usr/local/bin/etcd*`；未改 `roles/{base,download,pki}`、
  `tests/{skeleton,base,download,pki}`；`playbooks/site.yml` 未引用 etcd；未提交任何证书/私钥。
- 遗留风险：①真机 `systemctl enable/start` 与 unit 的 `User=etcd` 路径属受限项，需真机复验（契约 §5/§6.2 已声明）；
  ②`etcd_min_members` 默认 3，单成员开发集群需显式置 1（已报错提示）；③制品源为 `storage.googleapis.com`
  （GitHub release 资产在本环境被阻断），换源时需同步改 sha256。
- 下一步：`eval T005`。Evaluator 复现命令：`tests/etcd/test_etcd_role.sh` 或 `make test-etcd`。

---

## [2026-10-20] Evaluator · T004 评估第 1 轮 → PASS（eval）

- 时间：2026-10-20
- 角色：Evaluator（harness-evaluator 独立子会话；只读评审，未改任何代码/测试/契约）
- 当前任务：`T004`（被测提交 `08945c4`）
- 结论：**PASS**（报告 `reports/T004-r1.md`）；六项硬指标 功能 4 / 幂等 5 / 可配置 5 / 测试 4 / 结构 4 / 安全 5；产品完整度 4；阻塞 0；缺陷 2 MINOR + 3 NIT（均非阻塞）。
- 复现：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` **连跑两次**均 exit 0；T001 `27`、T002 `39`、T003 `59`、T004 `100`，`FAIL=0`；归一化 ANSI/随机沙箱路径后两次日志 `diff` **0 行**，与 Generator 声称一致（无回退）。
- **独立复现（自建 playbook + 自建 inventory，etcd 成员与 master 分离）**：61 条断言全绿（除下述 D1）；apiserver SAN 实测含 VIP/3 master/2 node/服务 IP/四件套 DNS；kubelet 各自节点且不扩散；etcd server/peer 含 3 个 etcd 成员；三链 `openssl verify` 通过、错 CA 必败；11 对证书/私钥公钥逐字节一致；私钥 600/证书 644/目录 700 用 `stat` 实测。
- **幂等/不覆盖/自愈**：第二次 `changed=0`，24 个产物 sha256 逐一不变；`--check` rc=0/changed=0；外部签发+旧 mtime 有效证书不被覆盖；垃圾证书（changed=6）与真实过期证书（2019→2020）均自愈且私钥复用；etcd-ca 损坏 → CA 重建 + 3 leaf 全量重签；`pki_force_regen=true` changed=53 全量重签仍验链通过；`pki_config_dir` 重定向生效；缺 `k8s_master` exit=2 且报分组名。
- **牙齿实验 5/5 全部被捕获**（独立 worktree，主工作区 clean）：删 VIP→A3 FAIL；删 master 主机名→A3 FAIL；私钥 mode 0644→A7 FAIL；强制每次重签→A11「changed=40 非幂等」+「产物被改动」+A12 FAIL；apiserver-etcd-client 改用错 CA→etcd 链 FAIL。
- **TDD 诚实性 PASS**：原始红日志（mtime `2026-10-19 15:38:46`，`PASS=26 FAIL=59`）仍在；worktree 重构红归一化后与原始红 `diff` 0 行；中途红 `PASS=89 FAIL=5` 日志亦在，未发现事后伪造。
- **安全/隔离**：`git ls-files` 无 `.key/.crt/.pem`；`/etc/kubernetes` 未创建；无残留沙箱/进程；测试离线（仅本地 openssl+ansible）。
- **回归**：`08945c4` 未触碰 `tests/{skeleton,base,download}`、`roles/{base,download}`、`playbooks/`（diff 0 行）。
- **非阻塞缺陷**：D1（MINOR）私钥文件「存在但不可解析」时不自愈且 role 仍 exit 0（`_needs_regen.yml:55-64` / `verify.yml:68-77`）；D2（MINOR）选择性 tags `--tags pki:ca`/`pki:cert` 报 `pki_needs_key` undefined，与契约 §10.1「`pki:*` 可单跑」不符；D3（NIT）kubelet 证书默认只为 `k8s_node` 生成、master 无（契约 A2/A4 以 node 为 N，不阻塞）；D4（NIT）测试用 OpenSSL 3.4+ `-not_before/-not_after`；D5（NIT）A15b 只显式验 front-proxy 链。
- 改了哪些文件：`docs/harness/state/reports/T004-r1.md`（新增）、`state.yaml`（accepted / eval_round 1 / done_tasks 4 / active_task T005 / phase BUILDING）、`roadmap.md`（T004 → done）、本文件。
- 下一步：`build T005`（etcd 集群 role：3 成员 healthy、member list、重启恢复）。建议后续触碰 `roles/pki` 时顺手修 D1/D2。

---

## [2026-10-20] Generator · T004 实现完成（**中断后续跑**）→ ready_for_eval

- 时间：2026-10-20
- 角色：Generator（harness-generator 子会话；只做 `active_task: T004`，未自判 PASS）
- 当前任务：`T004` PKI / 证书 role（`roles/pki`）
- **上下文**：上一轮（2026-10-19）已完成 role 与测试的绝大部分，随后因 **API 限流中断**；
  工作区留下未提交的半成品（`roles/pki`、`tests/pki`、契约 §1–§8 + §9.0）。本轮**没有重写**这些资产，
  只做「评估 → 修缺陷 → 补齐测试/文档/门禁」。
- 本次做了什么：
  1. 跑 `tests/pki/test_pki_role.sh`，首版实现 **`PASS=89 FAIL=5`**，定位并修复 2 个真实缺陷：
     - `tasks/facts.yml`：apiserver SAN 只加了 `map('extract', pki_host_addrs)` 解析出的**地址**，
       漏掉 `pki_apiserver_names` 的**主机名** → 补入；
     - `tasks/cert.yml`：首跑结束会清理 `pki_build_dir`，此后「仅某张 leaf 需重签」时目录不存在，
       `copy` 失败（A13a/A13b 红）→ 新增「按需准备构建目录」任务（`when: pki_cert_needs_issue`）。
  2. 补齐 `roles/pki/README.md`（测试 A1 要求，原半成品缺失）：产物清单/签发者、变量表、幂等语义、范围。
  3. `Makefile`：`test` 纳入 pki 套件，新增 `test-pki` 目标（风格同 `test-download`）。
  4. **红证据（诚实标注）**：
     - 交接假设原红日志丢失，但 `/tmp/opencode/t004_red.log`（2026-10-19T15:38:46）仍在；
     - 仍在 **git worktree**（`/tmp/opencode/t004-red`，HEAD=`6d6a367`）里**重构红**：只拷 `tests/pki`、
       不给 `roles/pki` → **`PASS=26 FAIL=59`、exit 1**；与原始红日志的差异**仅**为 `mktemp` 随机沙箱路径；
     - 另记录「实现中途红」`PASS=89 FAIL=5`，证明测试确实能抓缺陷（非恒绿）。
  5. 契约 §4 验收项 A1–A20 全部勾选，§9.1/§9.2/§9.3/§9.4/§9.5 与 §10 填实。
- **怎么验证**：
  ```bash
  tests/pki/test_pki_role.sh                                  # → PASS=100 FAIL=0, exit 0
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test             # 连跑两次，均 exit 0
  yamllint -c .yamllint roles/pki tests/pki                   # rc=0
  ```
- **测试结果**：pki `PASS=100 FAIL=0`；全量门禁两次完全一致（去时间戳后 `diff` 0 行）：
  skeleton `27` / base `39` / download `59` / **pki `100`**，FAIL 全为 0 → T001/T002/T003 无回退。
- **幂等 / 不覆盖**：同一沙箱连跑两次 `changed=54 → changed=0`，24 个产物 sha256 清单**逐一不变**
  （抽样：`apiserver.crt=653dc37c…`、`ca.crt=48b071f3…`、`kubelet/k8s-node1.crt=e1f39624…`、`sa.pub=4d393a52…`）。
  外部另签 + 旧 mtime 的有效证书不被覆盖（`changed=0`、哈希不变）；损坏/过期证书被自愈重签且私钥复用；
  etcd-ca 损坏 → CA 重建 + 其 leaf 全量重签且链自洽；`pki_force_regen=true` 全量重签仍验链通过。
- **宿主零污染 / 安全**：`/etc/kubernetes` 执行前后均**不存在**（未创建）；`git status` 无任何 `.key/.crt/.pem`；
  全部产物落在 `mktemp -d` 沙箱并已清理；无残留 worktree / 进程。
- 改了哪些文件：`roles/pki/tasks/facts.yml`、`roles/pki/tasks/cert.yml`、`roles/pki/README.md`（新增）、
  `tests/pki/*`（沿用上轮，未弱化断言）、`Makefile`、`docs/harness/state/contracts/T004.md`、
  `docs/harness/state/state.yaml`、`docs/harness/state/roadmap.md`（T004 → in-progress）、本文件。
- 遗留 / 风险（均已在契约 §5/§6 声明，非阻塞）：
  - 受限项：多节点证书分发、apiserver/kubelet 真实加载证书、与真实 etcd/kubeadm 互操作未验证（需真机/VM）；
  - `ansible-lint` 环境不可得，静态门禁仅 `syntax-check` + `yamllint`（沿用仓库既定策略）；
  - 首跑约 1.5 min/次（openssl CLI + 逐任务幂等判定），pki 套件全套约 13 min——评估时请预留时间；
  - `docs/harness/state/reports/T003-r1.md` 为上一轮 Evaluator 产物，至今仍未跟踪；本轮不越界提交（由后续提交处理）。
- 下一步：`eval T004`（`state.yaml` 已置 `contract_status: ready_for_eval`、`phase: EVALUATING`）。

---

## [2026-10-19] Evaluator · T003 评估第 1 轮 → PASS（eval）

- 时间：2026-10-19
- 角色：Evaluator（harness-evaluator 子会话，独立复现；未改任何代码/测试/契约）
- 当前任务：`T003`（被测提交 `6d6a367`）
- 结论：**PASS**（报告 `reports/T003-r1.md`）；六项硬指标均达标（功能 5 / 幂等 5 / 可配置 4 / 测试 4 / 结构 4 / 安全 5；产品完整度 4），阻塞 0，缺陷 3 MINOR + 3 NIT（均非阻塞）
- 复现：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` **连跑三次**（第 3 次在清理环境后）均 exit 0、T001 `PASS=27`、T002 `PASS=39`、T003 `PASS=59`、`FAIL=0`，三次去色日志**逐行一致**——Generator 声称的 27/39/59 核实无误。
- **独立复现（不复用仓库 mock/测试 playbook）**：自建 mock 源/代理 + 自建 playbook，36 条断言全绿（正常下载/hash/mode、幂等 + inode·mtime·size 不变、源不可达 `changed=0`、错 hash → 非 0 且无残留、换正确 hash 同 dest 成功、**自建记录型代理收到绝对 URI 请求**、`no_proxy` 直连、flaky 重试、`download_retries=0` 仅 1 次、缺/非法 sha256 网络前 fail-fast、显式 dest/mode）；另 14 条边界/负例（缓存损坏**自愈**、`--check` 无变更、空 items、`verify_after=false`、404 无残留、`timeout` 生效）全绿。
- **离线证明**：`unshare -rn`（仅 lo、**无默认路由**）内 `tests/download/test_download_role.sh` → `PASS=59 FAIL=0`，证明测试真正离线。
- **真实镜像站行为**：自建带 `Last-Modified`/`ETag`/`Accept-Ranges` 的源 → 第 2 次运行 `changed=0`、元数据不变且**零新增请求**；第 3 次源不可达仍 `changed=0`。
- **牙齿实验 12 组全部被捕获**（临时 worktree，主工作区零污染）：M1 删 `checksum`→FAIL×4；M2 放宽 sha256 正则→A10 FAIL×2；M3 `force:true`→A5 离线跳过 FAIL；M3b `changed_when:true`→**A4 changed=0 FAIL**；M5 删 `environment`→A6 FAIL；M6 删 `checksum`+关纵深复验→**A3「sha256 不符却 exit 0」FAIL**；M7 注入硬编码 URL→A8 FAIL；M8b 制品目录脱离沙箱前缀→FAIL×22（真实尝试写 `/opt/k8s` 被拒）；M9/M10 重试相关→A9 FAIL×3；**M12 先删后下（真正破坏「跳过」）→ A4 非幂等 + A5「制品被改动」FAIL**。
- 回归/隔离：`6d6a367` 未触碰 `tests/skeleton/`、`tests/base/`、`roles/base/`、`playbooks/`、`inventory/`、`group_vars/`、`ansible.cfg`；主工作区全程 clean、worktree 已清理、宿主 `/opt/k8s` 未被污染。
- **缺陷（非阻塞）**：D1（MINOR）契约 §9.1/§9.2 的证据日志来自**已修订的旧测试版本**（红态旧 18/37、断言 55 条；用最终 59 断言测试重跑红态得 **21/38**；绿灯日志仍打印端口）；D2（MINOR）Generator 手工实验泄漏一个 `python3 -m http.server 18080` 孤儿进程（PID 32697，cwd 已删除）——**测试套件自身无残留**，Evaluator 已 kill 并释放端口；D3（MINOR）`A4` 以「日志最后一个 `changed=N`」判定，`force:true` 单独出现时 A4 不红（靠 A5 离线断言兜住），建议补「源请求数=0」独立断言；NIT：D4 确定性 checksum 不符仍被 `until` 重试 4 次、D5 folded-scalar 拼接可读性、D6 `make test` 的 smoke 仍 0 task（T001 遗留）。
- 受限项维持诚实声明：真实 k8s 官方制品与真实 HTTPS `validate_certs` 未验证（契约 §5/§6）。
- 改了哪些文件：`docs/harness/state/reports/T003-r1.md`（新增）、`state.yaml`（accepted / eval_round 1 / done_tasks 3 / active_task T004 / phase BUILDING）、`roadmap.md`（T003 → done）、本文件。
- 下一步：`build T004`（PKI / 证书 role：自建 CA 与各组件证书、SAN 覆盖、私钥 600、重跑不覆盖有效证书）。

---

## [2026-10-19] Generator · T003 实现完成（build）→ ready_for_eval

- 时间：2026-10-19
- 角色：Generator（harness-generator 子会话；只做 `active_task: T003`，未自判 PASS）
- 当前任务：`T003`（下载与代理 role `download`）
- 本次做了什么：
  1. 写契约 `docs/harness/state/contracts/T003.md`（A1–A12 可判定验收项 + 幂等非典型例外 + **受限声明**）。
  2. **TDD**：先写全离线测试（`tests/download/mock_servers.py` + `fixtures` + `run_role.yml` +
     `test_download_role.sh`）→ 红灯 `PASS=18 FAIL=37`（`the role 'download' was not found`，exit 1）。
  3. 实现 `roles/download`：`defaults`（items/timeout/retries/proxy_env/cache_dir 全部变量化）、
     `tasks/main.yml`（validate → resolve → dirs → fetch → verify）、`handlers`、`meta`、`README.md`。
  4. 绿灯：`tests/download/test_download_role.sh` → **`PASS=59 FAIL=0`**，exit 0。
  5. `Makefile`：`test` 目标纳入新套件，并加 `test-download` 便捷目标。
- **怎么验证**：
  ```bash
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test        # T001 PASS=27 | T002 PASS=39 | T003 PASS=59，exit 0
  make test-download                                     # 仅 T003 套件，全离线
  tests/download/test_download_role.sh
  ```
- **测试/幂等结果**：`make test` **连跑两次**均 exit 0、`PASS=27/39/59 FAIL=0`，两次去色日志 diff 无差异；
  T003 用例内第二次执行 `changed=0`；已存在制品 `inode/mtime/size` 不变；**源不可达时 `changed=0`**
  （证明「已存在且 hash 相符 → 跳过」不发网络请求，可离线预置制品）。
- **关键设计决策**：
  - 强校验用 `get_url` 的 `checksum: "sha256:<hex>"`：实测「hash 不符 → 任务失败且 **dest 不落文件**」，
    无半成品残留；另有 `download:verify` 落盘后独立复验作纵深防御。
  - `download:validate` 强制每项提供 64 位 hex `sha256`（缺省/非法 → **fail fast，绝不降级为 warning**）。
  - 代理用 `environment: "{{ download_proxy_env }}"`（缺省 `{{ proxy_env }}`），实测 `http_proxy` 生效、
    `no_proxy` 被尊重（绕过代理且直连成功）。
  - 重试用任务级 `until/retries/delay`（实测 `loop` + `until` 为**逐项**重试）。
  - **唯一非典型幂等例外（已在契约 §5 声明）**：制品已存在但 sha256 不符 → 视为缓存损坏并**重新下载**（自愈）。
- **牙齿实验（7 组，仓库副本上执行，主工作区零污染）**：E1 删 `checksum`→FAIL×4；E2 删 `environment`→FAIL×1；
  E3 默认 retries=0→FAIL×3；E3c 删 `until/retries/delay`→FAIL×3；E4 放宽 sha256 正则→FAIL×2；
  E5 `force: true`→FAIL×1；E6 制品目录脱离沙箱前缀→FAIL×9。
  **E3 首轮未被捕获**（测试自己 `-e` 传了 `download_retries` 覆盖 role 默认）→ 已修正测试：
  A9 改用 role 默认，并新增 **A9b**（`download_retries: 0` 必须失败且源仅被请求一次）双向锁定该变量。
- **受限声明（对应 spec R1）**：本环境 registry 不可达、**禁止外网**，故不使用 molecule/testinfra，
  改用**本地 mock HTTP 源 + mock 正向代理 + mock 不稳定源**真实验证；**真实 k8s 官方制品（dl.k8s.io）的
  下载与 sha256、以及真实 HTTPS 的 `validate_certs` 无法在此验证**，须按契约 §6 的步骤在联网/真机复验。
- 改了哪些文件：`roles/download/**`（新增）、`tests/download/**`（新增）、`Makefile`、
  `docs/harness/state/contracts/T003.md`（新增）、`state.yaml`、`roadmap.md`（T003 → in-progress）、本文件。
  **未改** `tests/skeleton/`、`tests/base/`、`roles/base/`；**未接入** `playbooks/site.yml`（契约 A12 有断言）。
- 遗留项 / 风险（非阻塞）：
  - 真实制品与真实 HTTPS 未验证（见上「受限声明」）。
  - 测试失败时会**保留**沙箱目录（`/tmp/opencode/t003.XXXXXX`）并写 `t003_last_ports.json` 供排障；成功则清理。
  - 制品属主/属组因 `omit` 无法经 `set_fact` 存续，改在 fetch 的模块参数层解析（tasks 内已注释）。
- 下一步：`eval T003`（Evaluator 独立复现；`eval_round` 由 Evaluator 置 1）。

---

## [2026-10-19] Evaluator · T002 评估第 2 轮 → PASS（eval）

- 时间：2026-10-19
- 角色：Evaluator（harness-evaluator 子会话，独立复现；未改任何代码/测试/契约）
- 当前任务：`T002`（被测提交 `741a926`，上一轮 `fd9d4ec` FAIL）
- 结论：**PASS**（报告 `reports/T002-r2.md`）；六项硬指标均达标（功能 5 / 幂等 5 / 可配置 4 / 测试 4 / 结构 4 / 安全 4；产品完整度 4），阻塞 0。
- 复现：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` 连跑两次均 exit 0、T001 `PASS=27`、T002 `PASS=39`、`FAIL=0`，两次去色日志**完全一致**（核对 Generator 声称的 39 一致）。独立沙箱第二次 `changed=0`；0644/0755 权限、swap 注释、hosts 精确条目全部复核通过。
- **D1（MAJOR）确认修复**：自建探针（不引用仓库测试脚本）独立验证 Debian→`chrony`、RedHat→`chronyd`、`-e base_ntp_service=…` 覆盖生效、Suse 落 else 分支；回退写死 `chronyd` 立即 `FAIL NTP 服务名解析：Debian → chrony`。
- **牙齿实验 6/6 全部被捕获**（临时 worktree + private mount namespace，宿主零污染）：E1 回退 D1→FAIL；E2 删 hosts 循环→A5 两条精确行 FAIL；E3 `changed_when: true`→A6 FAIL；E4 mode 0600→A2 权限 FAIL；E5/E6 让 dest 绕过前缀（sysctl / hosts）→A10 打印前后哈希并 FAIL。
- 其余复核：D2/D3/D6 **确认修复**（含 E2/E5/E6 牙齿）；D4 spec v1.2 与 role README、契约 §5 口径一致；**D5 维持如实记录**（`make smoke` 仍 0 task、`site.yml` 未接入 `base`，未被悄悄"修绿"）。回归：`741a926` 未触碰 `tests/skeleton/`、`playbooks/`、`roles/base/tasks/*`，测试脚本 diff 为纯新增。
- 非阻塞项（N1–N6）：A9 仍整段跳过 NTP tag；A11 "用户覆盖" case 只证明 extra-var 优先级；缺 `base_disable_swap=false` 等配置变体负例；fstab 行首空白正则；README 裸 `ansible-playbook` 缺运行前提；smoke 0 task 建议后续独立 smoke playbook 解决。
- 改了哪些文件：`docs/harness/state/reports/T002-r2.md`（新增）、`state.yaml`（accepted / eval_round 2 / done_tasks 2 / active_task T003 / phase BUILDING）、`roadmap.md`（T002 → done）、本文件。
- 下一步：`build T003`（下载与代理 role：URL+sha256 校验、代理、本地缓存、幂等）。

---

## [2026-10-19] Generator · T002 修复 r1 → ready_for_eval（build）

- 时间：2026-10-19
- 角色：Generator（harness-generator 子会话；只做 `active_task: T002`，未自判 PASS）
- 当前任务：`T002`（主机准备 role `base`，修复 `reports/T002-r1.md` 的 D1/D2/D3/D6 + D4 README 部分）
- 本轮修了什么：
  1. **D1（MAJOR）**：`roles/base/defaults/main.yml` 的 `base_ntp_service` 改为按发行版求值
     `{{ 'chronyd' if ansible_os_family == 'RedHat' else 'chrony' }}`；仍是 role default，
     `group_vars`/`host_vars`/`-e` 可覆盖。`roles/base/README.md`「关键变量」补上 `base_ntp_service`。
  2. **D2（MINOR）**：A5 新增 hosts 精确行断言 `grep -qx '10.0.0.11 k8s-master1'` /
     `grep -qx '10.0.0.21 k8s-node1'`（补 E4 未捕获的缺口）。
  3. **D3（MINOR）**：A10 隔离断言扩展到四个真实宿主路径
     `/etc/sysctl.d/99-kubernetes.conf`、`/etc/modules-load.d/99-kubernetes.conf`、`/etc/hosts`、`/etc/fstab`
     （前后内容 sha256 对比，缺失记 `__MISSING__`）。
  4. **D6（NIT）**：README「仅落盘」示例改为直接运行 `tests/base/sandbox.yml`
     （`SB=$(mktemp -d)` + `-e sandbox_root=$SB --skip-tags base:system`），不再依赖先接入 playbook。
  5. **D4（README 部分）**：README 与契约 §5 的「无 systemd」更正为「PID1=systemd、免密 sudo 可用；
     但为共享开发机，禁止 swapoff/sysctl/改主机名等破坏性主机级变更；无可用容器、registry 不可达」。
     `spec.md` 由 Planner 维护（v1.2），本轮未改。
- **红 → 绿证据**：
  - 先加 `tests/base/assert_ntp_service.yml` + 新断言，修复前跑：Debian 分支
    `FAIL NTP 服务名解析：Debian → chrony`，`PASS=38 FAIL=1`，exit 1（`/tmp/opencode/t002_red.log`）。
  - D2 牙齿实验（临时副本删 hosts 条目循环）：两条精确行断言 FAIL，`PASS=36 FAIL=3`
    （`/tmp/opencode/t002_d2_teeth.log`）。
  - D3 牙齿实验（临时副本清空 `base_root_prefix`，`unshare -rm` 私有 mount namespace 内 bind `/etc`）：
    四个路径全部报「被污染」，`PASS=22 FAIL=17`（`/tmp/opencode/t002_d3_teeth2.log`）；
    namespace 退出后宿主四路径复核干净。
  - 修复后单跑：`tests/base/test_base_role.sh` → **`PASS=39 FAIL=0`**，exit 0（`/tmp/opencode/t002_green.log`）。
- **两次完整回归**（按报告 §9）：
  ```
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test   # 第一次：T001 PASS=27 FAIL=0；T002 PASS=39 FAIL=0；exit 0
  env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test   # 第二次：同上；去 ANSI 后两次日志 diff 无差异
  ```
  `/tmp/opencode/t002_make_test_r1_{1,2}.log`、`/tmp/opencode/r1_diff.txt`。
  文档定稿后又复跑一次，结果与上面完全一致（`/tmp/opencode/t002_make_test_final.log`）。
- 改了哪些文件：`roles/base/defaults/main.yml`、`roles/base/README.md`、
  `tests/base/test_base_role.sh`、`tests/base/assert_ntp_service.yml`（新增）、
  `docs/harness/state/contracts/T002.md`（§5/§6/§7/§8 + §9/§10）、`state.yaml`、本文件。
  **未改** `tests/skeleton/`、`playbooks/`、`roles/base/tasks/*`；未把 `base` 接入 `site.yml`。
- 提交范围：上述代码/测试/契约/状态 + 此前工作区中 Planner 的 `spec.md`/`roadmap.md` v1.2
  与 Evaluator 的 `reports/T002-r1.md`（一并纳入以保证状态可审计；Generator 未改其内容）。
- 遗留项：**D5**（`make smoke` 仍 0 task）属 T001 已验收门禁，本轮按要求不修，留待后续任务；
  报告 §7 的 NTP tag 拆分、fstab 行首空白正则等非阻塞改进项未做。
- 下一步：`eval T002 (r2)`（Evaluator 独立复现；`eval_round` 由 Evaluator 置 2）。

---

## [2026-10-19] Evaluator · T002 评估第 1 轮 → FAIL（eval）

- 时间：2026-10-19
- 角色：Evaluator（harness-evaluator 子会话，独立复现；未改任何代码/测试/契约）
- 当前任务：`T002`（被测提交 `fd9d4ec`）
- 结论：**FAIL**（报告 `reports/T002-r1.md`）；A1–A10 全部 PASS，但可配置与可移植 3/5（<4）触发 FAIL
- 复现：`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK make test` 连跑两次均 exit 0、T001 `PASS=27`、T002 `PASS=31`、`FAIL=0`，两次日志（去色）完全一致；独立沙箱验证内容/权限/幂等，第二次 `changed=0`；宿主 `/etc/{sysctl.d,modules-load.d}/99-kubernetes.conf`、`/etc/hosts`、`/etc/fstab` 均未被污染。
- 牙齿实验（临时 worktree，已删除）：删除 role → `PASS=4 FAIL=24`；删除 fstab replace → A4 FAIL；`ip_forward=0` → A3 FAIL；`changed_when: true` → A6 FAIL；`unshare -rm` 私有 namespace 中破坏前缀 → A10 FAIL「宿主真实系统路径被污染！」。**E4 未被捕获**：删除 hosts 条目渲染循环后仍 `PASS=31`，暴露 A5 只断言受管块标记、不断言条目内容。
- 阻塞缺陷（D1，MAJOR）：`roles/base/defaults/main.yml:46` 默认 `base_ntp_service: chronyd`，Debian/Ubuntu 的 chrony 包实际是 `chrony.service`；`tasks/system.yml:50-58` 未按 os_family 分支。Debian 12 filelist 实测只有 `chrony.service`/`chrony-wait.service`；错误服务名 check 探针 exit 2。README/meta 宣称支持 Debian/Ubuntu，默认配置会失败。
- 其余：D2 A5 测试缺口（MINOR）；D3 A10 只查 sysctl（MINOR）；D4 文档「无 systemd」与实测 PID1=systemd 不符（MINOR，需 Planner 更正）；D5 `make smoke` 仍 0 task（T001 N1 遗留，NIT）；D6 README「仅落盘」示例在未接入 playbook 时无效（NIT）。
- 设计取舍：`base_root_prefix` 沙箱接缝、不用 notify/handler、role 不接入 playbooks 均判定合理（后者代价是 smoke 仍为空转，建议后续独立 smoke playbook）。
- 改了哪些文件：`docs/harness/state/reports/T002-r1.md`（新增）、`state.yaml`、本文件；`roadmap.md` 保持 T002 `in-progress`（FAIL 不勾选）。
- 下一步：`build T002 (fix r1)` —— 修 D1、补 D2 断言、建议增强 D3/D4，重跑 `make test` 两次后交 r2。

---

## [2026-10-19] Planner · 规格维护 v1.1（plan）

- 时间：2026-10-19
- 角色：Planner（主会话，只写规格，未改任何代码/测试/契约/报告）
- 当前任务：`T002`（保持 `in-progress` + `ready_for_eval`，**未回退进度**）
- 本次做了什么（归档两笔欠账 + 固化环境事实）：
  1. **spec C10 / A1**：静态门禁由 `ansible-lint 0 error` **正式改为** `ansible-playbook --syntax-check` + `yamllint`
     （本环境 `ansible-lint` 不可获取；注明「若可安装须恢复为硬门禁」）。
  2. **spec 新增 C13「验收可执行性」**：验收不可执行时必须在契约标注「受限」并给真机复验步骤；
     评估报告不得把「接线断言/干跑」表述为「已验证生效」。
  3. **spec R1 细化**为已勘明事实：无 systemd（PID1）、容器镜像不可获取（dockerd 可起、registry 不通）、
     molecule/testinfra/ansible-lint 均装不上；并写明缓解=可重定向落盘面 + 幂等复跑 + 受限声明。
  4. **roadmap v1.1**：T002「测试方式」改为**沙箱前缀真实执行 + `--list-tasks` 接线 + `--check` 干跑**（验收摘要不变）；
     新增「验证环境」备注，规定后续 T005/T006/T008/T014/T015/T016 的同类降级规则。
  5. `state.yaml`：新增冻结项 `defaults.verification_policy`、`defaults.static_gate`。
- 未做的事（有意）：**没有**把 `phase` 改回 `BUILDING`、**没有**把 `active_task` 指向 T001 ——
  T001 已 done、T002 已实现待评估，回退会丢失真实进度；`next_action` 保持 `eval T002`。
- 改了哪些文件：`spec.md`、`roadmap.md`、`state.yaml`、本文件。**未改** README / standards / 代码。
- 待办（需要用户或有权限的角色处理，Planner 无权改）：
  - `repo-conventions.md` §8 末条「docker 可用（29.9.1）」**已过时**（daemon 默认未运行、镜像拉不到），建议改为「docker CLI 存在；daemon 需手动启动且 registry 不可达」。
  - README「一个任务的生命周期」第 3 步仍写 `ansible-lint`，与 spec C10 新口径不一致（README 属需求原文，建议仅加注）。
- 下一步：`eval T002`（`/h-eval`）。

---

## [2026-10-19] Generator · T002 实现完成（build）→ ready_for_eval

- 时间：2026-10-19
- 角色：Generator（harness-generator 会话）
- 当前任务：`T002`（主机准备 role `base`）
- 本次做了什么：
  1. 写契约 `contracts/T002.md`（A1–A10 可判定验收项 + **受限声明**）。
  2. **TDD**：先写 `tests/base/test_base_role.sh` + `tests/base/sandbox.yml` → 红灯 `PASS=4 FAIL=23`
     （失败原因确认为 `the role 'base' was not found`）。
  3. 实现 `roles/base`：`defaults`/`tasks/{main,files,system}`/`handlers`/`templates/*.j2`/`meta`/`README.md`。
  4. 绿灯：`make test` → T001 `PASS=27`、T002 `PASS=31`、`FAIL=0`、exit 0。
- **验证策略变更（需 Planner 归档，见下）**：roadmap 原写「molecule(docker driver) + testinfra」，
  但本环境 `molecule`/`testinfra` 装不上、dockerd 虽可手动启动却**拉不到镜像**（Docker Hub DNS 抖动 + 下载中断）、
  且**无 systemd**，主机级效果无法真实验证。经用户确认（选项 A），改为：
  **沙箱前缀 `base_root_prefix` + 真实执行文件类任务**（真实渲染 / 落盘 / 权限 / 幂等复跑）
  + `--list-tasks --tags base:system` 接线断言 + `--check --diff` 干跑。
- 怎么验证：
  ```
  make test                                                      # T001 PASS=27 + T002 PASS=31, exit 0
  tests/base/test_base_role.sh                                   # 单跑 T002 套件
  ```
- 测试/幂等结果：`make test` 连跑两次均 exit 0、`PASS=27/31 FAIL=0`；
  T002 用例内**第二次执行 `changed=0`**（真实幂等）；宿主 `/etc/sysctl.d/99-kubernetes.conf` 前后状态一致（沙箱隔离）。
- 关键设计决策：
  - 落盘路径全部由 `base_root_prefix` 派生（默认空 = 真实系统路径），故可整体重定向到沙箱做真实验证。
  - **不使用 notify/handler**：曾出现 handler 未被 `--skip-tags` 过滤、在控制机跑 `sysctl --system` 而失败的问题；
    改为 `tasks/system.yml` 中的幂等命令任务（`sysctl --system` 用 `changed_when: false`，`modprobe` 自身幂等）。
- 遗留问题 / 风险：
  - **受限声明（对应 spec R1）**：模块真实加载、sysctl 真实生效、`swapoff` 真实执行、主机名/时区真实变更、
    chrony 服务启用、firewalld/SELinux 真实状态 —— 本环境**无法真实验证**，仅接线 + 干跑断言，需真机/VM 复验。
  - **角色未接入 playbook**：`playbooks/{control-plane,node}.yml` 仍为占位，**故意不接入**——
    否则 `make smoke`（localhost）会对开发机做主机准备。接入应在 T003/T004 的真实编排中进行。
  - **待 Planner 归档**：① `roadmap.md` T002「测试方式」列仍写 molecule+testinfra；
    ② `spec.md` C10 仍写 `ansible-lint`（T001 遗留）。
  - 环境副作用：探查期手动启动过 `dockerd`（无镜像、可 `sudo pkill dockerd` 回收）。
- 下一步：`eval T002`（交 Evaluator 独立复现与打分）。

---

## [2026-10-16] Evaluator · T001 评估第 2 轮 → PASS（eval）

- 时间：2026-10-16
- 角色：Evaluator（harness-evaluator 子会话，独立复现，未改任何代码/测试/契约）
- 当前任务：`T001`（被测提交 `0e59f8b`，上一轮 `1c33f93` FAIL）
- 结论：**PASS**（报告 `reports/T001-r2.md`）；阻塞项 0，缺陷 1 MINOR + 2 NIT（均非阻塞）
- r1 五条缺陷**全部真实复现确认修复**：
  - D1（BLOCKER）：`ansible-playbook -i inventory/hosts.example playbooks/site.yml` → **exit 0**（原 exit 1）。
  - D3（MAJOR）：`Makefile:42` `test: lint smoke`；牙齿实验 `ANSIBLE_STDOUT_CALLBACK=yaml make test` → **exit 2**，脚本内 `FAIL 真实执行冒烟失败`。
  - D2（MINOR）：临时副本注释 `*.key` → 脚本 `FAIL 未被 .gitignore 忽略: secret.key`、exit 1（行为断言生效）。
  - D4（MINOR）：临时副本破坏 `add-node.yml`（不在 site.yml 内）→ `make syntax` exit 2；`make lint` 逐个校验 5 个 playbook。
  - D5（MINOR）：不显式 `-i` 时 warning 由 3 条降至 2 条，`Could not match supplied host pattern` 消失（回退 `hosts.example` 生效）。
- 打分：功能正确性 5 / 幂等 5 / 可配置 4 / 测试质量 4 / 代码结构 4 / 安全 4；产品完整度 4（加权）。
- 新增非阻塞项：**N1（MINOR）** `smoke` 实际执行 0 个 task（`grep -cE '^TASK \[' = 0`，两个 play 均 `skipping: no hosts matched`）→ 注入模块参数错误后 `make test` 仍 exit 0/PASS=27，但真实执行 exit 2；**T002 起须让冒烟真的落到主机**。N2 `make syntax PLAYBOOKS=` 空 glob 假绿；N3 提交把 Evaluator 的 `reports/T001-r1.md` 一并纳入（可审计性建议）。
- 门禁/幂等：`make lint` 与 `make test` 各连跑两次均 exit 0、`PASS=27 FAIL=0`、输出完全一致；干净环境（`env -u PYTHONPATH -u ANSIBLE_PLAYBOOK`）复现 `PASS=27`。
- 回归/隔离：`spec.md`/`roadmap.md`/`standards/` 自 `90a32de` 未被 Generator 改动；全部破坏性探针在 `git worktree` 临时副本完成，主工作区 `git status --porcelain` 为空、HEAD=`0e59f8b`。
- 改了哪些文件：`docs/harness/state/reports/T001-r2.md`（新增）、`state.yaml`、`roadmap.md`（T001 → done）、本文件。
- 下一步：`build T002`（主机准备 role base）；T002 须落实 N1 的"真实执行"升级与 spec C10 门禁口径归档（Planner）。

---

## [2026-10-16] Generator · T001 修复 r1（响应评估 r1）

- 时间：2026-10-16
- 角色：Generator（harness-generator 会话）
- 当前任务：`T001`
- 本次做了什么（逐条响应 `reports/T001-r1.md`）：
  - **D1（BLOCKER）**：`ansible.cfg` 删除 `stdout_callback = yaml`（`community.general` 已移除该 callback）。
  - **D3（MAJOR，假绿根因）**：新增真实执行冒烟 —— `Makefile` 的 `smoke` 目标 + 测试脚本内检查，`test: lint smoke`。
    牙齿验证：`ANSIBLE_STDOUT_CALLBACK=yaml` 模拟旧配置时冒烟 exit 1。
  - **D2（MINOR）**：`.gitignore` 断言改为行为断言 `git check-ignore -q --no-index <探针>`。
  - **D4（MINOR）**：`make syntax` 遍历 `playbooks/*.yml` 全量校验。
  - **D5（MINOR）**：`ansible.cfg` 的 inventory 增加回退 `inventory/hosts.ini, inventory/hosts.example`。
- 改了哪些文件：`ansible.cfg`、`Makefile`、`tests/skeleton/test_skeleton.sh`、`contracts/T001.md`（§10）、`state.yaml`、本文件。**未改 spec/reports**。
- 怎么验证：
  ```
  make test                                                       # PASS=27 FAIL=0, exit 0
  ansible-playbook -i inventory/hosts.example playbooks/site.yml  # exit 0（原为 exit 1）
  ```
- 测试/幂等结果：`make test` 连续两次 `PASS=27 FAIL=0`；真实运行 exit 0。
- 遗留问题 / 风险：`spec.md` C10 的 `ansible-lint` 口径仍待 Planner 归档（不影响本轮）；`host_key_checking=False`、`deprecation_warnings=False` 为已知权衡（评估 §5 非阻塞）。
- 下一步：`eval T001 (r2)`（交 Evaluator 复查）。

---

## [2026-10-16] Evaluator · T001 评估第 1 轮 → FAIL（eval）

- 时间：2026-10-16
- 角色：Evaluator（harness-evaluator 子会话，独立复现）
- 当前任务：`T001`（被测提交 `1c33f93`）
- 结论：**FAIL**（报告 `reports/T001-r1.md`）
- 复现摘要：A1–A6 静态验收**全部 PASS**（`./tests/skeleton/test_skeleton.sh` PASS=25/FAIL=0；`--syntax-check` exit 0；`yamllint -c .yamllint .` exit 0；`make help` 列出目标；无密钥入库；inventory 三分组齐全）；`make lint`/`make test` 连跑两次均 PASS=25/exit 0。
- **阻塞缺陷 D1（`ansible.cfg:12`）**：`stdout_callback = yaml` 在本环境（ansible-core 2.20.5 / community.general 12.6.0）使**任何真实 `ansible-playbook` 运行 exit 1**（`ERROR: ...community.general.yaml callback plugin has been removed`）。`--syntax-check` 不加载 callback → 门禁假绿（D3）。
- 修复方向：删该行，或改 `callback_result_format = yaml`（本地已验两种均可 exit 0）；并补真实执行 smoke（对 localhost 跑一次占位 playbook）。
- 其余改进项：D2 测试 `.gitignore` 断言为弱子串匹配（注释掉 `*.key` 仍 PASS）；D4 `make syntax` 只查 `site.yml`；D5 默认 inventory 缺失静默降级。
- 改了哪些文件：`docs/harness/state/reports/T001-r1.md`（新增）、`state.yaml`、本文件。
- 下一步：`build T001 (fix r1)`。

---

## [2026-10-16] Generator · T001 实现完成（build）

- 时间：2026-10-16
- 角色：Generator（harness-generator 会话）
- 当前任务：`T001`（项目骨架与工具链）
- 本次做了什么：
  1. 写契约 `contracts/T001.md`（A1–A6 可判定验收项）。
  2. **TDD**：先写 `tests/skeleton/test_skeleton.sh` → 红灯 `PASS=1 FAIL=24`。
  3. 实现骨架：`ansible.cfg`、`.yamllint`、`.gitignore`、`Makefile`、`inventory/hosts.example`、
     `group_vars/{all,k8s_master,k8s_node,etcd}/main.yml`、
     `playbooks/{site,control-plane,node,add-node,upgrade}.yml`、`roles/README.md`。
  4. 绿灯：`make test` → `PASS=25 FAIL=0`；连续两次一致。
- 改了哪些文件：上述骨架 + 契约/状态/roadmap；**未写任何 role 逻辑**。
- 怎么验证：
  ```
  make lint     # yamllint + ansible-playbook --syntax-check
  make test     # lint + tests/skeleton/test_skeleton.sh
  ```
- 测试/幂等结果：红→绿通过；重跑结果一致；本任务无运行时幂等要求。
- 遗留问题 / 风险：
  - **验收口径变更（待 Planner 归档）**：环境无 `ansible-lint`（包源取不到），T001 静态门禁改为
    `--syntax-check` + `yamllint`。已更新 `roadmap.md` T001 与 `acceptance-criteria.md` §5，并新增
    `repo-conventions.md` §8 环境说明；但 `spec.md` C10 仍写 `ansible-lint`，**Generator 无权改 spec**，待 Planner 同步。
  - 环境：`ansible-playbook` 不在 PATH，需 `PYTHONPATH=/home/zhangsan/ansible`；`Makefile` 已自动兜底 `$HOME/ansible`。
- 下一步：`eval T001`（交 Evaluator 独立复现与打分）。

---

## [2026-10-16] Planner · 规划完成（plan）

- 时间：2026-10-16
- 角色：Planner（子会话）
- 当前任务：无（`active_task: T001`，尚未开始实现）
- 本次做了什么：
  1. 读 `AGENTS.md` → `state.yaml` → `roles/planner.md` → 根 `README.md` → `standards/repo-conventions.md` → 现有 `roadmap.md` 草案。
  2. 产出 `docs/harness/state/spec.md`（v1 定稿）：目标 G1–G13、非目标 N1–N7、约束 C1–C12、组件清单、
     关键数据流与三类对外接口、验收总纲 A1–A16、风险 R1–R6、开放问题 Q1–Q3、默认决策 D1–D3、需求→落点对照表。
     → **README 的每条「项目目标」「实现要求」均已逐条覆盖并标注落点任务。**
  3. 复核并细化 `roadmap.md`（取代 draft）：16 个任务 T001–T016，每条含可判定验收摘要 + spec 验收项引用、
     依赖、测试方式、QAgate（全 normal）；补齐依赖图、关键路径、里程碑 M1–M7、已知限制。
  4. 更新 `state.yaml`：`phase: BUILDING`、`active_task: T001`、`next_action: "build T001"`、
     `planned_tasks: 16`、`critical_path`、扩展 `defaults`（含 k8s_min_version/kube_proxy/cilium_mode/
     supported_os/artifact_source/upgrade_policy/harness_scope_note）、`updated`。
- 改了哪些文件：`docs/harness/state/spec.md`、`docs/harness/state/roadmap.md`、
  `docs/harness/state/state.yaml`、`docs/harness/state/handoff.md`。**未改任何代码。**
- 怎么验证：检查 `spec.md` §9「需求→落点对照」覆盖 README 全部条目；检查 `roadmap.md` 每条验收摘要含可判定命令/断言、
  依赖无环且拓扑有序；`state.yaml` 字段与角色卡要求一致。
- 测试/幂等结果：不适用（本任务仅规划，无代码/测试产出）。
- 遗留问题 / 风险：
  - **R1（高）**：真实多节点 VM 环境可能缺失，T005/T006 的 VIP 漂移与 T014/T015 的加节点/升级端到端可能只能用容器近似
    → 必须在契约与评估报告中显式声明局限，不得声称等价于真实 HA。
  - **D1 假设**：环境支持 VRRP（同二层网段）。若为云环境不支持 VRRP，需切 `ha_mode: kube-vip`。
  - **开放问题**：Q1 etcd 备份/恢复是否立项（默认不立项，仅升级前备份）；Q2 是否需要完整 air-gap 离线包（默认仅代理+本地制品目录）；
    Q3 是否需跨多个 minor 连续升级与自动回滚（默认仅相邻 minor + 手工回滚）。
  - **范围说明**：README 的「harness 系统」章节已由 `AGENTS.md` + `docs/harness/` 交付，未纳入本 roadmap；如发现 harness 缺陷应新增独立任务。
- 下一步：`build T001`（项目骨架与工具链）——Generator 先写契约 `state/contracts/T001.md`，**先写会失败的测试再实现**；
  验收：`ansible-lint` 0 error、`--syntax-check` 通过、`make help` 列出 lint/syntax/test、仓库不含密钥类文件。

---

## 历史

- [INIT] 空。会话结束后由当前角色更新。
