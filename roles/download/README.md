# role: download — 制品下载与代理

通用制品获取 role：按 **URL + 强制 sha256 强校验**下载任意二进制/依赖，支持代理、本地缓存/离线制品目录、
超时重试与幂等跳过。**所有可变项均来自变量，任务中无硬编码 URL/版本/路径。**

## 做什么

| 关注点 | 行为 | tag |
| --- | --- | --- |
| 强校验 | 每个下载项**必须**提供 64 位 hex `sha256`；不符即 **任务失败**（不是 warning、不静默跳过） | `download:validate` |
| 下载 | `ansible.builtin.get_url` 下载到 `dest`（缺省落在制品目录） | `download:fetch` |
| 代理 | `environment: {{ download_proxy_env }}`（缺省引用全局 `proxy_env`），`http_proxy`/`https_proxy`/`no_proxy` 均生效 | `download:fetch` |
| 本地缓存 | 制品**已存在且 sha256 相符** → 跳过，**不改动文件**、不发网络请求（可离线预置制品）；相符但属主/权限不符则仅修正属性 | `download:fetch` |
| 容灾 | 网络抖动自动重试（`download_retries`/`download_retry_delay`，`until` 保证逐项重试） | `download:fetch` |
| 纵深防御 | 落盘后再独立复验一次 sha256（`download_verify_after`） | `download:verify` |

## 用法

```yaml
# playbooks/*.yml（由调用方注入真实制品清单）
- hosts: k8s_master
  become: true
  roles:
    - role: download
      vars:
        proxy_env:
          http_proxy: "http://proxy.example.com:3128"
          no_proxy: "127.0.0.1,localhost,10.0.0.0/8"
        download_items:
          # 版本必须变量化（禁止硬编码），示例：
          - name: kube-apiserver
            url: "{{ k8s_download_url_base }}/v{{ k8s_version }}/bin/linux/{{ k8s_arch }}/kube-apiserver"
            sha256: "{{ k8s_artifact_sha256['kube-apiserver'] }}"
            mode: "0755"
          - name: kubelet
            url: "{{ k8s_download_url_base }}/v{{ k8s_version }}/bin/linux/{{ k8s_arch }}/kubelet"
            sha256: "{{ k8s_artifact_sha256['kubelet'] }}"
            mode: "0755"
```

> 具体 k8s 制品清单（url/sha256）由 T007/T008 等任务以变量定义，本 role 只提供机制。

仅取件、不产生其它副作用（演练/验证用测试 playbook）：

```bash
SB="$(mktemp -d /tmp/opencode/dl.XXXXXX)"
ansible-playbook -i localhost, -c local tests/download/run_role.yml \
  -e "{\"download_root_prefix\":\"$SB\",\"download_items\":[{\"name\":\"hello.bin\",\
\"url\":\"http://127.0.0.1:8000/hello.bin\",\"sha256\":\"<64hex>\"}]}"
# 产物在 $SB/opt/k8s/artifacts/；用后清理：rm -rf "$SB"
```

## 关键变量

见 `defaults/main.yml`。生产环境应在 `group_vars/` 覆盖，勿改 role 默认值：

- `download_items`：下载项列表。每项：`name`（缺省取 url 文件名）、`url`（必填）、`sha256`（必填，64 位 hex）、
  `dest`（缺省 `{{ download_cache_dir }}/<name>`）、`mode`/`owner`/`group`（缺省取 `download_file_*`）。
- `download_cache_dir`：本地缓存/制品目录，缺省 `{{ k8s_artifact_dir }}`（group_vars/all 定义，回退 `/opt/k8s/artifacts`）。
- `download_timeout` / `download_retries` / `download_retry_delay`：网络超时与重试。
- `download_proxy_env`：代理环境变量，缺省 `{{ proxy_env }}`（`http_proxy`/`https_proxy`/`no_proxy`）。
- `download_validate_certs`：HTTPS 证书校验（缺省 true）。
- `download_force`：置 true 则即使已存在且 hash 相符也强制重新下载。
- `download_verify_after`：落盘后独立复验 sha256（缺省 true）。
- `download_file_mode` / `download_file_owner` / `download_file_group`：落盘默认属性。
- `download_root_prefix`：**仅供测试**（空 = 真实系统路径）。

## 幂等语义（重要）

1. 制品已存在且 sha256 相符 → **跳过，不改动文件**（`changed=0`，不发网络请求）。
   若属主/权限与配置不符，则仅修正属性（这是有意的 `changed`）。
2. 制品已存在但 sha256 **不符** → 视为缓存损坏，**重新下载**（`changed=1`）。宁可自愈，也不静默使用被污染的制品。
3. 下载/校验失败 → 任务失败；`get_url` **不会**把未通过校验的文件移入 `dest`，故**不留成品/半成品**
   （不会有「半截文件下次被误跳过」的问题）。

## 测试

```bash
tests/download/test_download_role.sh   # 全离线：mock 源 + mock 代理 + mock 不稳定源
```

> 局限（对应 `spec.md` R1，契约 §5 有完整声明）：本环境 **registry 不可达、无可用镜像**，故不使用
> molecule/testinfra，而用**本地 mock HTTP 源与 mock 正向代理**真实验证；本环境**禁止外网**，
> 故**真实 k8s 官方制品（dl.k8s.io）的下载与 sha256 无法在此验证**，`validate_certs` 仅做变量化断言。
> 真实制品需在联网/真机环境按契约 §6 的步骤复验。
