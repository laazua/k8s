# 可配置项总表（由 `scripts/gen_vars_doc.py` 从 role defaults 生成）

> 不是手写清单：`make test-e2e-full` 会执行 `scripts/gen_vars_doc.py --check`，
> 任何 defaults 变更未同步到本文档都会让门禁变红。覆盖优先级：
> `-e` / host_vars > group_vars > role defaults。

| 变量 | 默认值 | 说明（来自 defaults 注释） |
| --- | --- | --- |
| **role: add-node** | | |
| `add_node_root_prefix` | `""` | - |
| `add_node_node_name` | `"{{ inventory_hostname }}"` | - |
| `add_node_target_group` | `k8s_node` | - |
| `add_node_forbidden_groups` | `（映射/列表，见 defaults）` | - |
| `add_node_cert_mode` | `sign` | sign      = 用集群 CA 私钥在本节点签发 kubelet 证书（默认，简单路径） preissued = 只校验运维已分发的 kubelet 证书（节点上不需要 CA 私钥，推荐生产） |
| `add_node_config_dir` | `"{{ k8s_config_dir \| default('/etc/kubernetes') }}"` | - |
| `add_node_pki_dir` | `"{{ add_node_root_prefix }}{{ add_node_config_dir }}/pki"` | - |
| `add_node_ca_cert` | `"{{ add_node_pki_dir }}/ca.crt"` | - |
| `add_node_ca_key` | `"{{ add_node_pki_dir }}/ca.key"` | - |
| `add_node_kubelet_cert` | `"{{ add_node_pki_dir }}/kubelet/{{ add_node_node_name }}.crt"` | - |
| `add_node_kubelet_key` | `"{{ add_node_pki_dir }}/kubelet/{{ add_node_node_name }}.key"` | - |
| `add_node_kubelet_common_name` | `"system:node:{{ add_node_node_name }}"` | - |
| `add_node_kubelet_organization` | `system:nodes` | - |
| `add_node_kubelet_extra_sans` | `[]` | - |
| `add_node_node_ip` | `"{{ ansible_host \| default(add_node_node_name) }}"` | - |
| `add_node_pki_build_dir` | `"{{ add_node_root_prefix }}/var/cache/kubernetes-pki"` | - |
| `add_node_cert_state_file` | `"{{ add_node_pki_dir }}/kubelet/{{ add_node_node_name }}.state"` | 一行三个 sha256：<ca> <cert> <key>；首跑签发后写入，重跑据此做内容级比对。 |
| `add_node_cert_renew_before_seconds` | `"{{ pki_renew_before_seconds \| default(2592000) }}"` | - |
| `add_node_kubelet_kubeconfig` | `"{{ add_node_root_prefix }}/var/lib/kubelet/kubelet.conf"` | - |
| `add_node_kubelet_kubeconfig_mode` | `"0600"` | - |
| `add_node_cluster_version` | `"{{ k8s_version \| default('1.31.0') }}"` | - |
| `add_node_kubelet_version` | `"{{ kubelet_version \| default(add_node_cluster_version) }}"` | - |
| `add_node_allow_minor_skew` | `0` | - |
| `add_node_manage_host` | `true` | - |
| `add_node_verify_registration` | `true` | - |
| `add_node_verify_delegate` | `localhost` | - |
| `add_node_verify_kubeconfig` | `"{{ add_node_root_prefix }}{{ add_node_config_dir }}/admin.conf"` | - |
| `add_node_verify_kubectl` | `"{{ add_node_root_prefix }}{{ k8s_bin_dir \| default('/usr/local/bin') }}/kubectl"` | - |
| `add_node_verify_retries` | `60` | - |
| `add_node_verify_delay` | `2` | - |
| `add_node_verify_timeout` | `10` | - |
| **role: base** | | |
| `base_root_prefix` | `""` | 空串 = 使用真实系统路径（生产语义）。测试时置为临时目录，把落盘重定向到沙箱， 从而在不污染宿主的前提下真实验证「渲染 / 落盘 / 权限 / 幂等」。 |
| `base_kernel_modules` | `（映射/列表，见 defaults）` | - |
| `base_sysctl` | `（映射/列表，见 defaults）` | - |
| `base_sysctl_dir` | `"{{ base_root_prefix }}/etc/sysctl.d"` | - |
| `base_modules_dir` | `"{{ base_root_prefix }}/etc/modules-load.d"` | - |
| `base_sysctl_file` | `"{{ base_sysctl_dir }}/99-kubernetes.conf"` | - |
| `base_modules_file` | `"{{ base_modules_dir }}/99-kubernetes.conf"` | - |
| `base_hosts_file` | `"{{ base_root_prefix }}/etc/hosts"` | - |
| `base_fstab_file` | `"{{ base_root_prefix }}/etc/fstab"` | - |
| `base_file_owner` | `root` | - |
| `base_file_group` | `root` | - |
| `base_manage_hostname` | `true` | - |
| `base_hosts_entries` | `[]` | 集群节点解析条目: [{ ip: "10.0.0.11", names: "k8s-master1" }, ...] |
| `base_disable_swap` | `true` | - |
| `base_ntp_enabled` | `true` | - |
| `base_ntp_package` | `chrony` | - |
| `base_ntp_service` | `"{{ 'chronyd' if ansible_os_family == 'RedHat' else 'chrony' }}"` | 服务名随发行版：RedHat 系为 chronyd；Debian/Ubuntu 的 chrony 包为 chrony。 仍可在 group_vars / host_vars / -e 中覆盖（如使用自定义 unit 名）。 |
| `base_timezone` | `"Asia/Shanghai"` | - |
| `base_manage_firewall` | `false` | 是否关闭 firewalld（k8s 场景常用；如需保留防火墙请置 false 并自行放行端口） |
| `base_selinux_state` | `""` | SELinux 目标状态: "" (不管理) \| permissive \| enforcing |
| **role: cilium** | | |
| `cilium_root_prefix` | `""` | - |
| `cilium_version` | `"1.16.3"` | - |
| `cilium_min_version` | `"1.12.0"` | - |
| `cilium_max_version` | `"2.0.0"` | - |
| `cilium_arch` | `"{{ k8s_arch \| default('amd64') }}"` | - |
| `cilium_image_registry` | `"quay.io"` | - |
| `cilium_image_repository` | `"cilium/cilium"` | - |
| `cilium_operator_image_repository` | `"cilium/operator-generic"` | - |
| `cilium_image_pull_policy` | `IfNotPresent` | - |
| `cilium_namespace` | `kube-system` | - |
| `cilium_service_account` | `cilium` | - |
| `cilium_config_map_name` | `cilium-config` | - |
| `cilium_daemonset_name` | `cilium` | - |
| `cilium_operator_enabled` | `true` | - |
| `cilium_operator_name` | `cilium-operator` | - |
| `cilium_operator_service_account` | `cilium-operator` | - |
| `cilium_operator_replicas` | `2` | - |
| `cilium_cluster_name` | `"{{ k8s_cluster_name \| default('kubernetes') }}"` | - |
| `cilium_cluster_id` | `1` | Cilium 以 cluster-id 作为 VXLAN VNI（24-bit）。 |
| `cilium_mode` | `vxlan` | vxlan \| geneve \| native（native = 无隧道；tunnel-port 仍渲染但未使用） |
| `cilium_tunnel_port` | `8472` | - |
| `cilium_mtu` | `1450` | - |
| `cilium_pod_cidr` | `"{{ k8s_pod_cidr \| default('10.244.0.0/16') }}"` | - |
| `cilium_service_cidr` | `"{{ k8s_service_cidr \| default('10.96.0.0/12') }}"` | - |
| `cilium_k8s_api_endpoint` | `（多行，见 defaults）` | - |
| `cilium_ipam` | `cluster-pool` | - |
| `cilium_enable_ipv4` | `true` | - |
| `cilium_enable_ipv6` | `false` | - |
| `cilium_identity_allocation_mode` | `crd` | - |
| `cilium_kube_proxy_replacement` | `false` | 默认保留 kube-proxy（项目默认决策 D2）。 |
| `cilium_kube_proxy_enabled` | `true` | - |
| `cilium_routing_mode` | `"{{ 'tunnel' if cilium_mode in ['vxlan', 'geneve'] else 'native' }}"` | - |
| `cilium_tunnel_protocol` | `"{{ cilium_mode if cilium_mode in ['vxlan', 'geneve'] else '' }}"` | - |
| `cilium_agent_config_dir` | `/tmp/cilium/config-map` | - |
| `cilium_agent_health_port` | `9879` | - |
| `cilium_agent_prometheus_port` | `9962` | - |
| `cilium_config_dir` | `"{{ k8s_config_dir \| default('/etc/kubernetes') }}"` | - |
| `cilium_manifest_dir` | `"{{ cilium_root_prefix }}{{ cilium_config_dir }}/cilium"` | - |
| `cilium_manifest_path` | `"{{ cilium_manifest_dir }}/cilium.yaml"` | - |
| `cilium_manifest_dir_mode` | `"0755"` | - |
| `cilium_manifest_mode` | `"0644"` | - |
| `cilium_root_owner` | `root` | - |
| `cilium_root_group` | `root` | - |
| `cilium_tolerations` | `（映射/列表，见 defaults）` | - |
| `cilium_node_selector` | `{}` | - |
| `cilium_agent_resources` | `（映射/列表，见 defaults）` | - |
| `cilium_operator_tolerations` | `（映射/列表，见 defaults）` | - |
| `cilium_operator_resources` | `（映射/列表，见 defaults）` | - |
| `cilium_daemonset_args` | `[]` | - |
| `cilium_ipv4_cidr_regex` | `（多行，见 defaults）` | - |
| `cilium_version_regex` | `'^[0-9]+\.[0-9]+\.[0-9]+$'` | - |
| `cilium_api_endpoint_regex` | `'^https?://[^/:]+:[0-9]{1,5}$'` | - |
| `cilium_vni_min` | `1` | - |
| `cilium_vni_max` | `16777215` | - |
| `cilium_port_min` | `1` | - |
| `cilium_port_max` | `65535` | - |
| `cilium_mtu_min` | `576` | - |
| `cilium_mtu_max` | `65535` | - |
| `cilium_supported_modes` | `['vxlan', 'geneve', 'native']` | - |
| `cilium_supported_ipam` | `['cluster-pool', 'kubernetes', 'eni', 'azure']` | - |
| `cilium_supported_pull_policies` | `['Always', 'IfNotPresent', 'Never']` | - |
| **role: cluster-addons** | | |
| `cluster_addons_root_prefix` | `""` | - |
| `cluster_addons_k8s_dir` | `"{{ k8s_config_dir \| default('/etc/kubernetes') }}"` | - |
| `cluster_addons_pki_dir` | `"{{ cluster_addons_root_prefix }}{{ k8s_pki_dir \| default('/etc/kubernetes/pki') }}"` | - |
| `cluster_addons_output_dir` | `"{{ cluster_addons_root_prefix }}{{ cluster_addons_k8s_dir }}/addons"` | - |
| `cluster_addons_manifest_dir` | `"{{ cluster_addons_output_dir }}/manifests"` | - |
| `cluster_addons_cluster_name` | `"{{ k8s_cluster_name \| default('kubernetes') }}"` | - |
| `cluster_addons_server` | `（多行，见 defaults）` | - |
| `cluster_addons_admin_kubeconfig` | `"{{ cluster_addons_root_prefix }}{{ cluster_addons_k8s_dir }}/admin.conf"` | - |
| `cluster_addons_kubelet_kubeconfig` | `"{{ cluster_addons_root_prefix }}{{ cluster_addons_k8s_dir }}/kubelet.conf"` | - |
| `cluster_addons_kubeconfig_mode` | `"0600"` | - |
| `cluster_addons_kubeconfig_owner` | `root` | - |
| `cluster_addons_kubeconfig_group` | `root` | - |
| `cluster_addons_rotate_kubeconfigs` | `false` | - |
| `cluster_addons_ca_cert` | `"{{ cluster_addons_pki_dir }}/ca.crt"` | - |
| `cluster_addons_admin_cert` | `"{{ cluster_addons_pki_dir }}/admin.crt"` | - |
| `cluster_addons_admin_key` | `"{{ cluster_addons_pki_dir }}/admin.key"` | - |
| `cluster_addons_admin_user` | `kubernetes-admin` | - |
| `cluster_addons_kubelet_node` | `"{{ inventory_hostname }}"` | kubelet：每节点一份证书（CN=system:node:<node>，O=system:nodes） |
| `cluster_addons_kubelet_cert` | `"{{ cluster_addons_pki_dir }}/kubelet/{{ cluster_addons_kubelet_node }}.crt"` | - |
| `cluster_addons_kubelet_key` | `"{{ cluster_addons_pki_dir }}/kubelet/{{ cluster_addons_kubelet_node }}.key"` | - |
| `cluster_addons_kubelet_user` | `"system:node:{{ cluster_addons_kubelet_node }}"` | - |
| `cluster_addons_kubelet_group` | `system:nodes` | - |
| `cluster_addons_coredns_namespace` | `"{{ k8s_system_namespace \| default('kube-system') }}"` | - |
| `cluster_addons_coredns_service_account` | `coredns` | - |
| `cluster_addons_coredns_version` | `"1.11.3"` | - |
| `cluster_addons_coredns_image_registry` | `docker.io` | - |
| `cluster_addons_coredns_image_repository` | `coredns/coredns` | - |
| `cluster_addons_coredns_image_pull_policy` | `IfNotPresent` | - |
| `cluster_addons_coredns_replicas` | `2` | - |
| `cluster_addons_coredns_service_name` | `kube-dns` | - |
| `cluster_addons_coredns_container_port` | `53` | - |
| `cluster_addons_coredns_metrics_port` | `9153` | - |
| `cluster_addons_coredns_ready_port` | `""` | ready 插件监听地址：留空 → CoreDNS 默认 :8181；测试可指向高位端口 |
| `cluster_addons_cluster_domain` | `cluster.local` | - |
| `cluster_addons_coredns_listen_port` | `53` | - |
| `cluster_addons_coredns_upstream` | `/etc/resolv.conf` | - |
| `cluster_addons_coredns_cache_ttl` | `30` | - |
| `cluster_addons_coredns_cache_seconds` | `30` | - |
| `cluster_addons_coredns_kubernetes_endpoint` | `""` | 为空 → 使用集群内 ServiceAccount（默认）；测试/独立运行可指向沙箱 apiserver。 |
| `cluster_addons_coredns_tls_cert` | `""` | - |
| `cluster_addons_coredns_tls_key` | `""` | - |
| `cluster_addons_coredns_tls_ca` | `""` | - |
| **role: containerd** | | |
| `containerd_root_prefix` | `""` | - |
| `containerd_version` | `"2.0.0"` | - |
| `containerd_arch` | `"{{ k8s_arch \| default('amd64') }}"` | - |
| `containerd_download_url_base` | `"https://github.com/containerd/containerd/releases/download"` | - |
| `containerd_tarball_name` | `"containerd-{{ containerd_version }}-linux-{{ containerd_arch }}.tar.gz"` | - |
| `containerd_download_url` | `"{{ containerd_download_url_base }}/v{{ containerd_version }}/{{ containerd_tarball_name }}"` | - |
| `containerd_checksum_url` | `"{{ containerd_download_url }}.sha256sum"` | - |
| `containerd_checksum_timeout` | `30` | - |
| `containerd_known_sha256` | `（映射/列表，见 defaults）` | 已知版本的官方 sha256（离线/可复现）；换版本时若为空则读取官方 .sha256sum 侧车。 |
| `containerd_sha256` | `"{{ containerd_known_sha256[containerd_version] \| default('') }}"` | - |
| `containerd_artifact_dir` | `"{{ containerd_root_prefix }}{{ k8s_artifact_dir \| default('/opt/k8s/artifacts') }}"` | - |
| `containerd_artifact_path` | `"{{ containerd_artifact_dir }}/{{ containerd_tarball_name }}"` | - |
| `containerd_extract_dir` | `"{{ containerd_artifact_dir }}/containerd-{{ containerd_version }}"` | - |
| `containerd_bin_dir` | `"{{ containerd_root_prefix }}{{ k8s_bin_dir \| default('/usr/local/bin') }}"` | - |
| `containerd_binary` | `"{{ containerd_bin_dir }}/containerd"` | - |
| `containerd_binaries` | `（映射/列表，见 defaults）` | - |
| `containerd_bin_mode` | `"0755"` | - |
| `containerd_root_owner` | `root` | - |
| `containerd_root_group` | `root` | - |
| `containerd_download_timeout` | `120` | - |
| `containerd_download_retries` | `3` | - |
| `containerd_download_retry_delay` | `2` | - |
| `containerd_config_dir` | `"{{ containerd_root_prefix }}/etc/containerd"` | - |
| `containerd_config_path` | `"{{ containerd_config_dir }}/config.toml"` | - |
| `containerd_config_mode` | `"0644"` | - |
| `containerd_config_dir_mode` | `"0755"` | - |
| `containerd_unit_dir` | `"{{ containerd_root_prefix }}{{ kube_systemd_dir \| default('/etc/systemd/system') }}"` | - |
| `containerd_unit_name` | `containerd.service` | - |
| `containerd_unit_path` | `"{{ containerd_unit_dir }}/{{ containerd_unit_name }}"` | - |
| `containerd_unit_mode` | `"0644"` | - |
| `containerd_root_dir` | `"{{ containerd_root_prefix }}/var/lib/containerd"` | - |
| `containerd_state_dir` | `"{{ containerd_root_prefix }}/run/containerd"` | - |
| `containerd_socket` | `"{{ containerd_state_dir }}/containerd.sock"` | - |
| `containerd_cni_bin_dir` | `"{{ containerd_root_prefix }}/opt/cni/bin"` | - |
| `containerd_cni_conf_dir` | `"{{ containerd_root_prefix }}/etc/cni/net.d"` | - |
| `containerd_sandbox_image` | `"registry.k8s.io/pause:3.10"` | - |
| `containerd_cgroup_driver` | `"{{ container_runtime_cgroup_driver \| default('systemd') }}"` | 单一来源：group_vars/all 的 container_runtime_cgroup_driver。 |
| `containerd_systemd_cgroup` | `"{{ 'true' if containerd_cgroup_driver == 'systemd' else 'false' }}"` | - |
| `containerd_require_systemd_cgroup` | `true` | - |
| `containerd_config_version` | `"{{ 3 if containerd_version is version('2.0.0', '>=') else 2 }}"` | containerd 2.x 用 config version 3；1.x 用 version 2（模板分支）。 |
| `containerd_default_runtime_name` | `runc` | - |
| `containerd_config_extra` | `""` | - |
| `containerd_install_runc` | `true` | - |
| `containerd_require_runc` | `true` | - |
| `runc_version` | `"1.2.1"` | - |
| `runc_arch` | `"{{ containerd_arch }}"` | - |
| `runc_download_url_base` | `"https://github.com/opencontainers/runc/releases/download"` | - |
| `runc_download_url` | `"{{ runc_download_url_base }}/v{{ runc_version }}/runc.{{ runc_arch }}"` | - |
| `runc_known_sha256` | `（映射/列表，见 defaults）` | - |
| `runc_sha256` | `"{{ runc_known_sha256[runc_version] \| default('') }}"` | - |
| `runc_artifact_path` | `"{{ containerd_artifact_dir }}/runc.{{ runc_arch }}"` | - |
| `runc_binary` | `"{{ containerd_bin_dir }}/runc"` | - |
| `containerd_install_cni_plugins` | `true` | - |
| `containerd_require_cni_plugins` | `true` | - |
| `cni_plugins_version` | `"1.5.1"` | - |
| `cni_plugins_download_url_base` | `"https://github.com/containernetworking/plugins/releases/download"` | - |
| `cni_plugins_tarball_name` | `"cni-plugins-linux-{{ containerd_arch }}-v{{ cni_plugins_version }}.tgz"` | - |
| `cni_plugins_download_url` | `"{{ cni_plugins_download_url_base }}/v{{ cni_plugins_version }}/{{ cni_plugins_tarball_name }}"` | - |
| `cni_plugins_known_sha256` | `（映射/列表，见 defaults）` | - |
| `cni_plugins_sha256` | `"{{ cni_plugins_known_sha256[cni_plugins_version] \| default('') }}"` | - |
| `cni_plugins_artifact_path` | `"{{ containerd_artifact_dir }}/{{ cni_plugins_tarball_name }}"` | - |
| `cni_plugins_extract_dir` | `"{{ containerd_artifact_dir }}/cni-plugins-{{ cni_plugins_version }}"` | - |
| `cni_plugins_required` | `（映射/列表，见 defaults）` | - |
| `containerd_install_crictl` | `true` | - |
| `crictl_version` | `"1.31.1"` | - |
| `crictl_download_url_base` | `"https://github.com/kubernetes-sigs/cri-tools/releases/download"` | - |
| `crictl_tarball_name` | `"crictl-v{{ crictl_version }}-linux-{{ containerd_arch }}.tar.gz"` | - |
| `crictl_download_url` | `"{{ crictl_download_url_base }}/v{{ crictl_version }}/{{ crictl_tarball_name }}"` | - |
| `crictl_known_sha256` | `（映射/列表，见 defaults）` | - |
| `crictl_sha256` | `"{{ crictl_known_sha256[crictl_version] \| default('') }}"` | - |
| `crictl_artifact_path` | `"{{ containerd_artifact_dir }}/{{ crictl_tarball_name }}"` | - |
| `crictl_extract_dir` | `"{{ containerd_artifact_dir }}/crictl-{{ crictl_version }}"` | - |
| `crictl_binary` | `"{{ containerd_bin_dir }}/crictl"` | - |
| `containerd_manage_service` | `true` | - |
| `containerd_service_enabled` | `true` | - |
| `containerd_service_state` | `started` | - |
| `containerd_service_type` | `notify` | - |
| `containerd_user` | `root` | - |
| `containerd_group` | `root` | - |
| `containerd_restart_sec` | `5` | - |
| `containerd_limit_nofile` | `1048576` | - |
| `containerd_oom_score_adjust` | `-999` | - |
| `containerd_exec_args_extra` | `[]` | - |
| `containerd_verify_endpoint` | `"{{ containerd_manage_service }}"` | - |
| `containerd_verify_retries` | `30` | - |
| `containerd_verify_delay` | `1` | - |
| **role: download** | | |
| `download_root_prefix` | `""` | 空串 = 使用真实系统路径（生产语义）。测试时置为临时目录，把制品落盘整体重定向， 从而在不污染宿主的前提下真实验证「下载 / 校验 / 落盘 / 权限 / 幂等 / 代理」。 |
| `download_cache_dir` | `"{{ download_root_prefix }}{{ k8s_artifact_dir \| default('/opt/k8s/artifacts') }}"` | 复用全局制品目录（group_vars/all: k8s_artifact_dir），未定义时回退保守默认； 由 download_root_prefix 派生，故可整体重定向到沙箱。 |
| `download_cache_dir_mode` | `"0755"` | - |
| `download_items` | `[]` | 每项字段： name   : 可读名称；缺省取 url 的文件名（用于日志与默认 dest） url    : 必填，下载地址 sha256 : 必填，64 位 hex；**强校验**，不符即任务失败（不允许省略/降级为 warning） dest   : 可选，缺省 {{ download_cache_dir }}/<name> mode / owner / group : 可选，缺省取 download_file_* 版本必须变量化（示例，禁止硬编码）： download_items: - name: kube-apiserver url: "{{ k8s_download_url_base }}/v{{ k8s_version }}/bin/linux/{{ k8s_arch }}/kube-apiserver" sha256: "{{ k8s_artifact_sha256['kube-apiserver'] }}" mode: "0755" |
| `download_timeout` | `120` | - |
| `download_retries` | `3` | - |
| `download_retry_delay` | `2` | - |
| `download_validate_certs` | `true` | - |
| `download_force` | `false` | 制品已存在且 sha256 相符 → 跳过（不改动）；置 true 则强制重新下载 |
| `download_verify_after` | `true` | 落盘后再独立复验一次 sha256（纵深防御；与 get_url 的 checksum 互不替代） |
| `download_proxy_env` | `"{{ proxy_env \| default({}) }}"` | proxy_env 形如 { http_proxy: "...", https_proxy: "...", no_proxy: "..." }；默认空 = 不走代理。 |
| `download_file_mode` | `"0644"` | - |
| `download_file_owner` | `root` | - |
| `download_file_group` | `root` | - |
| **role: etcd** | | |
| `etcd_root_prefix` | `""` | - |
| `etcd_version` | `"3.5.16"` | - |
| `etcd_arch` | `"{{ k8s_arch \| default('amd64') }}"` | - |
| `etcd_download_url_base` | `"https://storage.googleapis.com/etcd"` | etcd 官方历史发布桶（GitHub release 资产在本环境被阻断，见 contracts/T005.md §3） |
| `etcd_download_url` | `"{{ etcd_download_url_base }}/v{{ etcd_version }}/etcd-v{{ etcd_version }}-linux-{{ etcd_arch }}.tar.gz"` | - |
| `etcd_artifact_sha256` | `"b414b27a5ad05f7cb01395c447c85d3227e3fb1c176e51757a283b817f645ccc"` | - |
| `etcd_archive_root` | `"etcd-v{{ etcd_version }}-linux-{{ etcd_arch }}"` | - |
| `etcd_artifact_dir` | `"{{ etcd_root_prefix }}{{ k8s_artifact_dir \| default('/opt/k8s/artifacts') }}"` | - |
| `etcd_artifact_path` | `"{{ etcd_artifact_dir }}/{{ etcd_archive_root }}.tar.gz"` | - |
| `etcd_dist_dir` | `"{{ etcd_root_prefix }}/opt/k8s/etcd"` | - |
| `etcd_extract_dir` | `"{{ etcd_dist_dir }}/v{{ etcd_version }}"` | - |
| `etcd_bin_dir` | `"{{ etcd_root_prefix }}{{ k8s_bin_dir \| default('/usr/local/bin') }}"` | - |
| `etcd_install_binaries` | `["etcd", "etcdctl", "etcdutl"]` | - |
| `etcd_bin_mode` | `"0755"` | - |
| `etcd_inventory_group` | `etcd` | - |
| `etcd_members` | `[]` | 显式覆盖：[] 表示从 inventory 分组推导。元素可为 "host" 或 { name, address, client_port, peer_port }（address/端口可覆盖 hostvars）。 |
| `etcd_member_name` | `"{{ inventory_hostname }}"` | - |
| `etcd_port_client` | `2379` | - |
| `etcd_port_peer` | `2380` | - |
| `etcd_min_members` | `3` | 高可用最低成员数（单机开发可显式置 1）；奇数校验始终生效 |
| `etcd_instance_layout` | `per-host` | per-host：每台主机一个成员（生产默认） co-located：同一主机多实例（单机测试/实验），data-dir 与 unit 名按成员名隔离 |
| `etcd_cluster_token` | `k8s-etcd-cluster` | - |
| `etcd_initial_cluster_state` | `new` | - |
| `etcd_data_dir` | `"/var/lib/etcd"` | etcd_data_dir 是基础路径（group_vars/etcd 可覆盖）；沙箱前缀在派生的成员目录上套用。 |
| `etcd_member_data_dir` | `（多行，见 defaults）` | - |
| `etcd_data_dir_mode` | `"0700"` | - |
| `etcd_unit_dir` | `"{{ etcd_root_prefix }}{{ etcd_systemd_dir \| default('/etc/systemd/system') }}"` | - |
| `etcd_unit_name` | `"etcd{{ ('-' ~ etcd_member_name) if etcd_instance_layout == 'co-located' else '' }}.service"` | - |
| `etcd_unit_path` | `"{{ etcd_unit_dir }}/{{ etcd_unit_name }}"` | - |
| `etcd_unit_mode` | `"0644"` | - |
| `etcd_listen_address` | `"0.0.0.0"` | - |
| `etcd_listen_peer_address` | `"{{ etcd_listen_address }}"` | - |
| `etcd_user` | `etcd` | 三段式属主，禁止复用同一个变量： 1) etcd_root_owner/group：systemd unit、二进制、解包/制品目录 —— 永远 root:root。 服务用户绝不能拥有任何可执行/可加载路径（否则 etcd 进程可改写 unit 或替换二进制提权）。 2) etcd_data_owner/group：数据目录 —— 服务用户独占 0700。 3) etcd_cert_owner/group：证书分发目录 —— root 拥有、服务组可读（见下方 TLS 段）。 |
| `etcd_user_group` | `etcd` | - |
| `etcd_manage_user` | `true` | - |
| `etcd_user_shell` | `/usr/sbin/nologin` | - |
| `etcd_root_owner` | `root` | - |
| `etcd_root_group` | `root` | - |
| `etcd_data_owner` | `"{{ etcd_user }}"` | - |
| `etcd_data_group` | `"{{ etcd_user_group }}"` | - |
| `etcd_manage_service` | `true` | - |
| `etcd_service_enabled` | `true` | - |
| `etcd_service_state` | `started` | - |
| `etcd_service_type` | `notify` | - |
| `etcd_restart_sec` | `5` | - |
| `etcd_limit_nofile` | `65536` | - |
| `etcd_heartbeat_interval` | `100` | - |
| `etcd_election_timeout` | `1000` | - |
| `etcd_snapshot_count` | `10000` | - |
| `etcd_extra_args` | `[]` | - |
| `etcd_tls_enabled` | `true` | - |
| `etcd_tls_client_auth` | `true` | - |
| `etcd_tls_peer_client_auth` | `true` | - |
| `etcd_config_dir` | `"{{ k8s_config_dir \| default('/etc/kubernetes') }}"` | - |
| `etcd_pki_dir` | `"{{ etcd_root_prefix }}{{ etcd_config_dir }}/pki/etcd"` | - |
| `etcd_ca_file` | `"{{ etcd_pki_dir }}/ca.crt"` | pki 源文件（T004 产物；默认 root:root 0600 / 目录 0700） |
| `etcd_cert_file` | `"{{ etcd_pki_dir }}/server.crt"` | - |
| `etcd_key_file` | `"{{ etcd_pki_dir }}/server.key"` | - |
| `etcd_peer_cert_file` | `"{{ etcd_pki_dir }}/peer.crt"` | - |
| `etcd_peer_key_file` | `"{{ etcd_pki_dir }}/peer.key"` | - |
| `etcd_share_config_dir` | `"/etc/etcd"` | 背景：pki 以 root:root 0600 + 目录 0700 生成私钥，`User=etcd` 的进程读不到 → 真实 systemd 启动必然失败。这里不放松 pki 源目录（kube-apiserver 等也消费它）， 而是由 etcd role 把运行时需要的 5 个文件复制到独立目录： * 目录 root:<etcd 组> 0750（组可进入，others 不可） * 私钥 root:<etcd 组> 0640（组可读、others 不可、服务用户不可改写） * 证书 root:<etcd 组> 0644 unit 用 Group=<etcd 组> + SupplementaryGroups=<etcd 组> 获得组读权限。 数据目录属主（服务用户 0700）与证书属主（root + 组只读）严格分离。 |
| `etcd_pki_share_dir` | `"{{ etcd_root_prefix }}{{ etcd_share_config_dir }}/pki"` | - |
| `etcd_cert_owner` | `root` | - |
| `etcd_cert_group` | `"{{ etcd_user_group }}"` | - |
| `etcd_cert_dir_mode` | `"0750"` | - |
| `etcd_cert_mode` | `"0644"` | - |
| `etcd_cert_key_mode` | `"0640"` | - |
| `etcd_runtime_ca_file` | `"{{ etcd_pki_share_dir }}/ca.crt"` | 运行时路径（unit 的 --cert-file/--key-file/... 指向分发目录，而非 pki 源 0600 私钥） |
| `etcd_runtime_cert_file` | `"{{ etcd_pki_share_dir }}/server.crt"` | - |
| `etcd_runtime_key_file` | `"{{ etcd_pki_share_dir }}/server.key"` | - |
| `etcd_runtime_peer_cert_file` | `"{{ etcd_pki_share_dir }}/peer.crt"` | - |
| `etcd_runtime_peer_key_file` | `"{{ etcd_pki_share_dir }}/peer.key"` | - |
| `etcd_healthcheck_cert_file` | `"{{ etcd_runtime_cert_file }}"` | 滚动重启后的健康探测（以 root 运行 role；证书用分发目录内的 server 证书，含 clientAuth） |
| `etcd_healthcheck_key_file` | `"{{ etcd_runtime_key_file }}"` | - |
| `etcd_restart_health_retries` | `30` | - |
| `etcd_restart_health_delay` | `2` | - |
| `etcd_service_restart_argv` | `[]` | 测试/无 systemd 环境专用：非空时用该 argv 重启本成员（生产留空 → 走 systemd） |
| **role: haproxy** | | |
| `haproxy_root_prefix` | `"{{ base_root_prefix \| default('') }}"` | 支持统一前缀 `base_root_prefix`（测试沙箱），或单独覆盖 haproxy_root_prefix。 |
| `haproxy_base_prefix` | `"{{ haproxy_root_prefix \| regex_replace('/+$', '') }}"` | - |
| `haproxy_master_group` | `"{{ k8s_master_group \| default('k8s_master') }}"` | - |
| `haproxy_backend_servers` | `[]` | 显式覆盖：[{ name: m1, address: 10.0.0.11, port: 6443 }, ...] [] 表示从 inventory 分组推导（推荐）。 |
| `haproxy_resolved_members` | `[]` | - |
| `haproxy_lb_port` | `"{{ k8s_apiserver_port \| default(6443) }}"` | - |
| `haproxy_backend_port` | `"{{ k8s_apiserver_port \| default(6443) }}"` | - |
| `haproxy_bind_address` | `"{{ k8s_lb_bind_address \| default('0.0.0.0') }}"` | - |
| `haproxy_frontend_name` | `k8s_apiserver` | - |
| `haproxy_backend_name` | `k8s_apiserver` | - |
| `haproxy_balance` | `roundrobin` | - |
| `haproxy_check_inter` | `2s` | - |
| `haproxy_check_fall` | `3` | - |
| `haproxy_check_rise` | `2` | - |
| `haproxy_timeout_connect` | `5s` | - |
| `haproxy_timeout_client` | `1h` | - |
| `haproxy_timeout_server` | `1h` | - |
| `haproxy_maxconn` | `2000` | - |
| `haproxy_config_dir` | `"{{ haproxy_base_prefix }}/etc/haproxy"` | 生产默认 = 发行版 haproxy unit 实际读取的 CONFIG 路径（/etc/haproxy/haproxy.cfg）。 沙箱用 *_root_prefix / base_root_prefix 整体重定向，绝不写宿主 /etc。 |
| `haproxy_config_file` | `"{{ haproxy_base_prefix }}/etc/haproxy/haproxy.cfg"` | - |
| `haproxy_config_mode` | `"0644"` | - |
| `haproxy_pid_file` | `"/run/haproxy.pid"` | - |
| `haproxy_systemd_dropin_dir` | `"{{ haproxy_base_prefix }}/etc/systemd/system/{{ haproxy_service_name }}.service.d"` | 显式重写 ExecStart/ExecStartPre，只加载 haproxy_config_file， 不再依赖发行版 unit 的 $CFGDIR（避免加载包样例/额外文件）。 |
| `haproxy_systemd_dropin_file` | `"{{ haproxy_systemd_dropin_dir }}/10-role-config.conf"` | - |
| `haproxy_manage_package` | `true` | - |
| `haproxy_package_name` | `haproxy` | - |
| `haproxy_binary` | `/usr/sbin/haproxy` | - |
| `haproxy_manage_service` | `true` | - |
| `haproxy_service_name` | `haproxy` | - |
| `haproxy_service_enabled` | `true` | - |
| **role: keepalived** | | |
| `keepalived_root_prefix` | `"{{ base_root_prefix \| default('') }}"` | 支持统一前缀 `base_root_prefix`（测试沙箱），或单独覆盖 keepalived_root_prefix。 |
| `keepalived_base_prefix` | `"{{ keepalived_root_prefix \| regex_replace('/+$', '') }}"` | - |
| `ha_mode` | `"{{ k8s_ha_mode \| default('keepalived') }}"` | - |
| `keepalived_vip` | `"{{ k8s_vip \| default('') }}"` | - |
| `keepalived_vip_prefix` | `32` | - |
| `keepalived_interface` | `"{{ k8s_vip_interface \| default('') }}"` | - |
| `keepalived_instance_name` | `k8s_apiserver` | - |
| `keepalived_virtual_router_id` | `51` | - |
| `keepalived_state` | `BACKUP` | - |
| `keepalived_advert_int` | `1` | - |
| `keepalived_auth_type` | `PASS` | - |
| `keepalived_auth_pass` | `"k8s-ha"` | - |
| `keepalived_nopreempt` | `false` | - |
| `keepalived_garp_master_delay` | `5` | - |
| `keepalived_master_group` | `"{{ k8s_master_group \| default('k8s_master') }}"` | - |
| `keepalived_priority_base` | `150` | - |
| `keepalived_priority_step` | `10` | - |
| `keepalived_host_index` | `（多行，见 defaults）` | - |
| `keepalived_priority` | `"{{ (keepalived_priority_base \| int) - (keepalived_host_index \| int) * (keepalived_priority_step \| int) }}"` | - |
| `keepalived_check_interval` | `2` | - |
| `keepalived_check_timeout` | `2` | - |
| `keepalived_check_fall` | `2` | - |
| `keepalived_check_rise` | `2` | - |
| `keepalived_haproxy_pid_file` | `"{{ haproxy_pid_file \| default('/run/haproxy.pid') }}"` | - |
| `keepalived_config_dir` | `"{{ keepalived_base_prefix }}/etc/keepalived"` | 生产默认 = keepalived 服务实际读取的路径（/etc/keepalived/keepalived.conf）。 沙箱用 *_root_prefix / base_root_prefix 整体重定向，绝不写宿主 /etc。 |
| `keepalived_config_file` | `"{{ keepalived_base_prefix }}/etc/keepalived/keepalived.conf"` | - |
| `keepalived_config_mode` | `"0644"` | - |
| `keepalived_script_dir` | `"{{ keepalived_config_dir }}/scripts"` | - |
| `keepalived_check_script` | `"{{ keepalived_script_dir }}/chk_haproxy.sh"` | - |
| `keepalived_notify_script` | `"{{ keepalived_script_dir }}/notify.sh"` | - |
| `keepalived_state_log` | `"{{ keepalived_config_dir }}/state.log"` | - |
| `keepalived_script_mode` | `"0755"` | - |
| `keepalived_systemd_dropin_dir` | `"{{ keepalived_base_prefix }}/etc/systemd/system/{{ keepalived_service_name }}.service.d"` | - |
| `keepalived_systemd_dropin_file` | `"{{ keepalived_systemd_dropin_dir }}/10-role-config.conf"` | - |
| `kube_vip_image` | `"ghcr.io/kube-vip/kube-vip:v0.8.0"` | - |
| `kube_vip_manifest_dir` | `"{{ keepalived_base_prefix }}/etc/kubernetes/manifests"` | - |
| `kube_vip_manifest_file` | `"{{ kube_vip_manifest_dir }}/kube-vip.yaml"` | - |
| `kube_vip_kubeconfig` | `"/etc/kubernetes/admin.conf"` | kube-vip manager 在静态 Pod 模式下自动读取该 kubeconfig（节点真实路径， 不随沙箱前缀重定向——它由 kubelet 的 hostPath 挂载）。 |
| `kube_vip_cp_enable` | `true` | - |
| `kube_vip_leaderelection` | `true` | - |
| `kube_vip_leaseduration` | `5` | - |
| `kube_vip_renewdeadline` | `3` | - |
| `kube_vip_retryperiod` | `1` | - |
| `keepalived_manage_package` | `true` | - |
| `keepalived_package_name` | `keepalived` | - |
| `keepalived_binary` | `/usr/sbin/keepalived` | - |
| `keepalived_manage_service` | `true` | - |
| `keepalived_service_name` | `keepalived` | - |
| `keepalived_service_enabled` | `true` | - |
| **role: kube-apiserver** | | |
| `kube_apiserver_root_prefix` | `""` | - |
| `kube_apiserver_version` | `"{{ k8s_version \| default('1.31.0') }}"` | - |
| `kube_apiserver_arch` | `"{{ k8s_arch \| default('amd64') }}"` | - |
| `kube_apiserver_download_url_base` | `"https://dl.k8s.io"` | - |
| `kube_apiserver_download_url` | `（多行，见 defaults）` | - |
| `kube_apiserver_known_sha256` | `（映射/列表，见 defaults）` | 已知版本的官方 sha256（离线/可复现）；换版本时若为空则自动读取官方 .sha256 侧车。 |
| `kube_apiserver_sha256` | `"{{ kube_apiserver_known_sha256[kube_apiserver_version] \| default('') }}"` | - |
| `kube_apiserver_checksum_timeout` | `30` | - |
| `kube_apiserver_artifact_dir` | `"{{ kube_apiserver_root_prefix }}{{ k8s_artifact_dir \| default('/opt/k8s/artifacts') }}"` | - |
| `kube_apiserver_artifact_path` | `"{{ kube_apiserver_artifact_dir }}/kube-apiserver"` | - |
| `kube_apiserver_bin_dir` | `"{{ kube_apiserver_root_prefix }}{{ k8s_bin_dir \| default('/usr/local/bin') }}"` | - |
| `kube_apiserver_binary` | `"{{ kube_apiserver_bin_dir }}/kube-apiserver"` | - |
| `kube_apiserver_bin_mode` | `"0755"` | - |
| `kube_apiserver_root_owner` | `root` | - |
| `kube_apiserver_root_group` | `root` | - |
| `kube_apiserver_download_timeout` | `120` | - |
| `kube_apiserver_download_retries` | `3` | - |
| `kube_apiserver_download_retry_delay` | `2` | - |
| `kube_apiserver_config_dir` | `"{{ kube_apiserver_root_prefix }}{{ k8s_config_dir \| default('/etc/kubernetes') }}"` | - |
| `kube_apiserver_pki_dir` | `"{{ kube_apiserver_config_dir }}/pki"` | - |
| `kube_apiserver_unit_dir` | `"{{ kube_apiserver_root_prefix }}{{ kube_systemd_dir \| default('/etc/systemd/system') }}"` | - |
| `kube_apiserver_unit_name` | `kube-apiserver.service` | - |
| `kube_apiserver_unit_path` | `"{{ kube_apiserver_unit_dir }}/{{ kube_apiserver_unit_name }}"` | - |
| `kube_apiserver_unit_mode` | `"0644"` | - |
| `kube_apiserver_config_dir_mode` | `"0755"` | - |
| `kube_apiserver_bind_address` | `"0.0.0.0"` | - |
| `kube_apiserver_advertise_address` | `（多行，见 defaults）` | 生产必须可从 inventory 推导；无法推导时 fail-fast（validate） |
| `kube_apiserver_secure_port` | `"{{ k8s_apiserver_port \| default(6443) }}"` | - |
| `kube_apiserver_kubeconfig_server` | `（多行，见 defaults）` | kubeconfig 的 server：默认走 VIP（HA 前置 LB）；单机可覆盖 |
| `kube_apiserver_kubeconfig_cluster_name` | `kubernetes` | - |
| `kube_apiserver_etcd_group` | `etcd` | - |
| `kube_apiserver_etcd_scheme` | `https` | - |
| `kube_apiserver_etcd_port` | `"{{ etcd_port_client \| default(2379) }}"` | - |
| `kube_apiserver_etcd_servers` | `[]       # 显式完整 URL 列表（优先）` | - |
| `kube_apiserver_etcd_members` | `[]       # 显式成员名/地址列表（其次）；空 = 取 inventory 分组` | - |
| `kube_apiserver_etcd_prefix` | `/registry` | - |
| `kube_apiserver_etcd_ca_file` | `"{{ kube_apiserver_pki_dir }}/etcd/ca.crt"` | - |
| `kube_apiserver_etcd_cert_file` | `"{{ kube_apiserver_pki_dir }}/apiserver-etcd-client.crt"` | - |
| `kube_apiserver_etcd_key_file` | `"{{ kube_apiserver_pki_dir }}/apiserver-etcd-client.key"` | - |
| `kube_apiserver_tls_cert_file` | `"{{ kube_apiserver_pki_dir }}/apiserver.crt"` | - |
| `kube_apiserver_tls_private_key_file` | `"{{ kube_apiserver_pki_dir }}/apiserver.key"` | - |
| `kube_apiserver_client_ca_file` | `"{{ kube_apiserver_pki_dir }}/ca.crt"` | - |
| `kube_apiserver_kubelet_client_certificate` | `"{{ kube_apiserver_pki_dir }}/apiserver-kubelet-client.crt"` | - |
| `kube_apiserver_kubelet_client_key` | `"{{ kube_apiserver_pki_dir }}/apiserver-kubelet-client.key"` | - |
| `kube_apiserver_kubelet_preferred_address_types` | `"InternalIP,ExternalIP,Hostname"` | - |
| `kube_apiserver_front_proxy_ca_file` | `"{{ kube_apiserver_pki_dir }}/front-proxy-ca.crt"` | 聚合层 / 前端代理（T004 产出 front-proxy-ca 与 front-proxy-client） |
| `kube_apiserver_proxy_client_cert_file` | `"{{ kube_apiserver_pki_dir }}/front-proxy-client.crt"` | - |
| `kube_apiserver_proxy_client_key_file` | `"{{ kube_apiserver_pki_dir }}/front-proxy-client.key"` | - |
| `kube_apiserver_requestheader_client_ca_file` | `"{{ kube_apiserver_front_proxy_ca_file }}"` | - |
| `kube_apiserver_requestheader_allowed_names` | `front-proxy-client` | - |
| `kube_apiserver_requestheader_extra_headers_prefix` | `X-Remote-Extra-` | - |
| `kube_apiserver_requestheader_group_headers` | `X-Remote-Group` | - |
| `kube_apiserver_requestheader_username_headers` | `X-Remote-User` | - |
| `kube_apiserver_authorization_mode` | `"RBAC,Node"` | - |
| `kube_apiserver_anonymous_auth` | `false` | - |
| `kube_apiserver_require_secure_defaults` | `true` | 强制安全默认：开启时 validate 拒绝「不含 RBAC」或「匿名认证=true」的配置 |
| `kube_apiserver_profiling` | `false` | - |
| `kube_apiserver_enable_admission_plugins` | `["NodeRestriction"]` | - |
| `kube_apiserver_disable_admission_plugins` | `[]` | - |
| `kube_apiserver_enable_bootstrap_token_auth` | `true` | - |
| `kube_apiserver_service_account_key_file` | `"{{ kube_apiserver_pki_dir }}/sa.pub"` | - |
| `kube_apiserver_service_account_signing_key_file` | `"{{ kube_apiserver_pki_dir }}/sa.key"` | - |
| `kube_apiserver_service_account_issuer` | `"https://kubernetes.default.svc.{{ k8s_dns_domain \| default('cluster.local') }}"` | - |
| `kube_apiserver_service_account_max_token_expiration` | `"8760h"` | 注意：该 flag 是 time.Duration，必须带单位（8760h = 365 天） |
| `kube_apiserver_service_cluster_ip_range` | `"{{ k8s_service_cidr \| default('10.96.0.0/12') }}"` | - |
| `kube_apiserver_allow_privileged` | `true` | - |
| `kube_apiserver_log_level` | `2` | - |
| `kube_apiserver_audit_log_path` | `""` | - |
| `kube_apiserver_extra_args` | `[]` | - |
| `kube_apiserver_manage_service` | `true` | - |
| `kube_apiserver_service_enabled` | `true` | - |
| `kube_apiserver_service_state` | `started` | - |
| `kube_apiserver_service_type` | `simple` | - |
| `kube_apiserver_user` | `root` | - |
| `kube_apiserver_group` | `root` | - |
| `kube_apiserver_restart_sec` | `5` | - |
| `kube_apiserver_limit_nofile` | `65536` | - |
| `kube_apiserver_check_port_conflict` | `true` | - |
| `kube_apiserver_manage_kubeconfigs` | `true` | - |
| `kube_apiserver_client_cert_build_dir` | `"{{ kube_apiserver_root_prefix }}/var/cache/kubernetes-kubeconfig"` | - |
| `kube_apiserver_client_cert_cleanup_build_dir` | `true` | - |
| `kube_apiserver_client_cert_days` | `3650` | - |
| `kube_apiserver_client_cert_renew_before_seconds` | `2592000` | - |
| `kube_apiserver_key_type` | `"{{ pki_key_type \| default('RSA') }}"` | - |
| `kube_apiserver_key_size` | `"{{ pki_key_size \| default(2048) }}"` | - |
| `kube_apiserver_key_algorithm` | `"{{ pki_key_algorithm \| default('RSA') }}"` | - |
| `kube_apiserver_key_generation_opt` | `"{{ pki_key_generation_opt \| default('rsa_keygen_bits:2048') }}"` | - |
| `kube_apiserver_digest` | `"{{ pki_digest \| default('sha256') }}"` | - |
| `kube_apiserver_ca_file` | `"{{ kube_apiserver_pki_dir }}/ca.crt"` | - |
| `kube_apiserver_ca_key_file` | `"{{ kube_apiserver_pki_dir }}/ca.key"` | - |
| `kube_apiserver_key_mode` | `"0600"` | - |
| `kube_apiserver_cert_mode` | `"0644"` | - |
| `kube_apiserver_client_certs` | `（映射/列表，见 defaults）` | - |
| `kube_apiserver_admin_kubeconfig` | `"{{ kube_apiserver_config_dir }}/admin.conf"` | - |
| `kube_apiserver_controller_manager_kubeconfig` | `"{{ kube_apiserver_config_dir }}/controller-manager.conf"` | - |
| `kube_apiserver_scheduler_kubeconfig` | `"{{ kube_apiserver_config_dir }}/scheduler.conf"` | - |
| `kube_apiserver_kubeconfig_mode` | `"0600"` | - |
| `kube_apiserver_kubeconfig_owner` | `"{{ kube_apiserver_root_owner }}"` | - |
| `kube_apiserver_kubeconfig_group` | `"{{ kube_apiserver_root_group }}"` | - |
| `kube_apiserver_kubeconfigs` | `（映射/列表，见 defaults）` | - |
| `kube_apiserver_required_files` | `（映射/列表，见 defaults）` | - |
| **role: kube-controller-manager** | | |
| `kube_controller_manager_root_prefix` | `""` | - |
| `kube_controller_manager_version` | `"{{ k8s_version \| default('1.31.0') }}"` | - |
| `kube_controller_manager_arch` | `"{{ k8s_arch \| default('amd64') }}"` | - |
| `kube_controller_manager_download_url_base` | `"https://dl.k8s.io"` | - |
| `kube_controller_manager_download_url` | `（多行，见 defaults）` | - |
| `kube_controller_manager_known_sha256` | `（映射/列表，见 defaults）` | - |
| `kube_controller_manager_sha256` | `"{{ kube_controller_manager_known_sha256[kube_controller_manager_version] \| default('') }}"` | - |
| `kube_controller_manager_checksum_timeout` | `30` | - |
| `kube_controller_manager_artifact_dir` | `"{{ kube_controller_manager_root_prefix }}{{ k8s_artifact_dir \| default('/opt/k8s/artifacts') }}"` | - |
| `kube_controller_manager_artifact_path` | `"{{ kube_controller_manager_artifact_dir }}/kube-controller-manager"` | - |
| `kube_controller_manager_bin_dir` | `"{{ kube_controller_manager_root_prefix }}{{ k8s_bin_dir \| default('/usr/local/bin') }}"` | - |
| `kube_controller_manager_binary` | `"{{ kube_controller_manager_bin_dir }}/kube-controller-manager"` | - |
| `kube_controller_manager_bin_mode` | `"0755"` | - |
| `kube_controller_manager_root_owner` | `root` | - |
| `kube_controller_manager_root_group` | `root` | - |
| `kube_controller_manager_download_timeout` | `120` | - |
| `kube_controller_manager_download_retries` | `3` | - |
| `kube_controller_manager_download_retry_delay` | `2` | - |
| `kube_controller_manager_config_dir` | `（多行，见 defaults）` | - |
| `kube_controller_manager_pki_dir` | `"{{ kube_controller_manager_config_dir }}/pki"` | - |
| `kube_controller_manager_unit_dir` | `（多行，见 defaults）` | - |
| `kube_controller_manager_unit_name` | `kube-controller-manager.service` | - |
| `kube_controller_manager_unit_path` | `（多行，见 defaults）` | - |
| `kube_controller_manager_unit_mode` | `"0644"` | - |
| `kube_controller_manager_kubeconfig` | `"{{ kube_controller_manager_config_dir }}/controller-manager.conf"` | - |
| `kube_controller_manager_client_ca_file` | `"{{ kube_controller_manager_pki_dir }}/ca.crt"` | - |
| `kube_controller_manager_front_proxy_ca_file` | `"{{ kube_controller_manager_pki_dir }}/front-proxy-ca.crt"` | - |
| `kube_controller_manager_requestheader_allowed_names` | `front-proxy-client` | - |
| `kube_controller_manager_requestheader_extra_headers_prefix` | `X-Remote-Extra-` | - |
| `kube_controller_manager_requestheader_group_headers` | `X-Remote-Group` | - |
| `kube_controller_manager_requestheader_username_headers` | `X-Remote-User` | - |
| `kube_controller_manager_service_account_private_key_file` | `"{{ kube_controller_manager_pki_dir }}/sa.key"` | - |
| `kube_controller_manager_root_ca_file` | `"{{ kube_controller_manager_pki_dir }}/ca.crt"` | - |
| `kube_controller_manager_cluster_signing_cert_file` | `"{{ kube_controller_manager_pki_dir }}/ca.crt"` | - |
| `kube_controller_manager_cluster_signing_key_file` | `"{{ kube_controller_manager_pki_dir }}/ca.key"` | - |
| `kube_controller_manager_use_service_account_credentials` | `true` | - |
| `kube_controller_manager_allocate_node_cidrs` | `false` | - |
| `kube_controller_manager_leader_elect` | `true` | - |
| `kube_controller_manager_bind_address` | `"127.0.0.1"` | - |
| `kube_controller_manager_secure_port` | `10257` | - |
| `kube_controller_manager_profiling` | `false` | - |
| `kube_controller_manager_log_level` | `2` | - |
| `kube_controller_manager_extra_args` | `[]` | - |
| `kube_controller_manager_manage_service` | `true` | - |
| `kube_controller_manager_service_enabled` | `true` | - |
| `kube_controller_manager_service_state` | `started` | - |
| `kube_controller_manager_service_type` | `simple` | - |
| `kube_controller_manager_user` | `root` | - |
| `kube_controller_manager_group` | `root` | - |
| `kube_controller_manager_restart_sec` | `5` | - |
| `kube_controller_manager_limit_nofile` | `65536` | - |
| `kube_controller_manager_check_port_conflict` | `true` | - |
| `kube_controller_manager_required_files` | `（映射/列表，见 defaults）` | - |
| **role: kube-proxy** | | |
| `kube_proxy_root_prefix` | `""` | - |
| `kube_proxy_version` | `"{{ k8s_version \| default('1.31.0') }}"` | - |
| `kube_proxy_arch` | `"{{ k8s_arch \| default('amd64') }}"` | - |
| `kube_proxy_download_url_base` | `"https://dl.k8s.io"` | - |
| `kube_proxy_download_url` | `（多行，见 defaults）` | - |
| `kube_proxy_known_sha256` | `（映射/列表，见 defaults）` | - |
| `kube_proxy_sha256` | `"{{ kube_proxy_known_sha256[kube_proxy_version] \| default('') }}"` | - |
| `kube_proxy_checksum_timeout` | `30` | - |
| `kube_proxy_artifact_dir` | `"{{ kube_proxy_root_prefix }}{{ k8s_artifact_dir \| default('/opt/k8s/artifacts') }}"` | - |
| `kube_proxy_artifact_path` | `"{{ kube_proxy_artifact_dir }}/kube-proxy"` | - |
| `kube_proxy_bin_dir` | `"{{ kube_proxy_root_prefix }}{{ k8s_bin_dir \| default('/usr/local/bin') }}"` | - |
| `kube_proxy_binary` | `"{{ kube_proxy_bin_dir }}/kube-proxy"` | - |
| `kube_proxy_bin_mode` | `"0755"` | - |
| `kube_proxy_root_owner` | `root` | - |
| `kube_proxy_root_group` | `root` | - |
| `kube_proxy_download_timeout` | `120` | - |
| `kube_proxy_download_retries` | `3` | - |
| `kube_proxy_download_retry_delay` | `2` | - |
| `kube_proxy_config_dir` | `"{{ kube_proxy_root_prefix }}{{ k8s_config_dir \| default('/etc/kubernetes') }}"` | - |
| `kube_proxy_config_path` | `"{{ kube_proxy_config_dir }}/kube-proxy.yaml"` | - |
| `kube_proxy_config_mode` | `"0644"` | - |
| `kube_proxy_config_dir_mode` | `"0750"` | - |
| `kube_proxy_kubeconfig_path` | `"{{ kube_proxy_config_dir }}/kube-proxy.conf"` | - |
| `kube_proxy_kubeconfig_mode` | `"0600"` | - |
| `kube_proxy_unit_dir` | `"{{ kube_proxy_root_prefix }}{{ kube_systemd_dir \| default('/etc/systemd/system') }}"` | - |
| `kube_proxy_unit_name` | `kube-proxy.service` | - |
| `kube_proxy_unit_path` | `"{{ kube_proxy_unit_dir }}/{{ kube_proxy_unit_name }}"` | - |
| `kube_proxy_unit_mode` | `"0644"` | - |
| `kube_proxy_kubeconfig_source_mode` | `source` | source  : 复制既有 kubeconfig（默认 T007 的 admin.conf；生产应换专用凭据） embedded: 由 ca/cert/key 渲染内嵌证书的 kubeconfig（证书由 PKI 签发，本 role 只消费） |
| `kube_proxy_kubeconfig_source` | `"{{ kube_proxy_config_dir }}/admin.conf"` | - |
| `kube_proxy_kubeconfig_user` | `"system:kube-proxy"` | - |
| `kube_proxy_pki_dir` | `"{{ kube_proxy_config_dir }}/pki"` | - |
| `kube_proxy_client_ca_file` | `"{{ kube_proxy_pki_dir }}/ca.crt"` | - |
| `kube_proxy_client_cert_file` | `"{{ kube_proxy_pki_dir }}/kube-proxy.crt"` | - |
| `kube_proxy_client_key_file` | `"{{ kube_proxy_pki_dir }}/kube-proxy.key"` | - |
| `kube_proxy_apiserver_url` | `（多行，见 defaults）` | - |
| `kube_proxy_proxy_mode` | `iptables` | 仅支持 iptables / ipvs（其它值 fail-fast）。 |
| `kube_proxy_cluster_cidr` | `"{{ k8s_pod_cidr \| default('10.244.0.0/16') }}"` | cluster-cidr 语义为 **Pod CIDR**（detectLocalMode=ClusterCIDR 时用于判定本地流量）。 |
| `kube_proxy_ipv4_cidr_regex` | `（多行，见 defaults）` | - |
| `kube_proxy_bind_address` | `"0.0.0.0"` | - |
| `kube_proxy_healthz_bind_address` | `"127.0.0.1:10256"` | - |
| `kube_proxy_metrics_bind_address` | `"127.0.0.1:10249"` | - |
| `kube_proxy_hostname_override` | `"{{ inventory_hostname }}"` | - |
| `kube_proxy_detect_local_mode` | `ClusterCIDR` | - |
| `kube_proxy_node_port_addresses` | `[]` | - |
| `kube_proxy_extra_args` | `[]` | - |
| `kube_proxy_log_level` | `2` | - |
| `kube_proxy_accept_content_types` | `"application/vnd.kubernetes.protobuf,application/json"` | - |
| `kube_proxy_content_type` | `"application/vnd.kubernetes.protobuf"` | - |
| `kube_proxy_qps` | `5` | - |
| `kube_proxy_burst` | `10` | - |
| `kube_proxy_conntrack_max_per_core` | `0` | - |
| `kube_proxy_conntrack_min` | `0` | - |
| `kube_proxy_conntrack_tcp_established_timeout` | `24h0m0s` | - |
| `kube_proxy_conntrack_tcp_close_wait_timeout` | `1h0m0s` | - |
| `kube_proxy_iptables_masquerade_all` | `false` | - |
| `kube_proxy_iptables_masquerade_bit` | `14` | - |
| `kube_proxy_iptables_sync_period` | `30s` | - |
| `kube_proxy_iptables_min_sync_period` | `1s` | - |
| `kube_proxy_iptables_localhost_node_ports` | `false` | - |
| `kube_proxy_ipvs_scheduler` | `rr` | - |
| `kube_proxy_ipvs_sync_period` | `30s` | - |
| `kube_proxy_ipvs_min_sync_period` | `2s` | - |
| `kube_proxy_ipvs_strict_arp` | `false` | - |
| `kube_proxy_ipvs_tcp_timeout` | `0s` | - |
| `kube_proxy_ipvs_tcp_fin_timeout` | `0s` | - |
| `kube_proxy_ipvs_udp_timeout` | `0s` | - |
| `kube_proxy_iptables_binary` | `iptables` | - |
| `kube_proxy_ipvs_proc_path` | `/proc/net/ip_vs` | - |
| `kube_proxy_manage_service` | `true` | - |
| `kube_proxy_service_enabled` | `true` | - |
| `kube_proxy_service_state` | `started` | - |
| `kube_proxy_service_type` | `simple` | - |
| `kube_proxy_user` | `root` | - |
| `kube_proxy_group` | `root` | - |
| `kube_proxy_restart_sec` | `10` | - |
| `kube_proxy_limit_nofile` | `1048576` | - |
| **role: kube-scheduler** | | |
| `kube_scheduler_root_prefix` | `""` | - |
| `kube_scheduler_version` | `"{{ k8s_version \| default('1.31.0') }}"` | - |
| `kube_scheduler_arch` | `"{{ k8s_arch \| default('amd64') }}"` | - |
| `kube_scheduler_download_url_base` | `"https://dl.k8s.io"` | - |
| `kube_scheduler_download_url` | `（多行，见 defaults）` | - |
| `kube_scheduler_known_sha256` | `（映射/列表，见 defaults）` | - |
| `kube_scheduler_sha256` | `"{{ kube_scheduler_known_sha256[kube_scheduler_version] \| default('') }}"` | - |
| `kube_scheduler_checksum_timeout` | `30` | - |
| `kube_scheduler_artifact_dir` | `"{{ kube_scheduler_root_prefix }}{{ k8s_artifact_dir \| default('/opt/k8s/artifacts') }}"` | - |
| `kube_scheduler_artifact_path` | `"{{ kube_scheduler_artifact_dir }}/kube-scheduler"` | - |
| `kube_scheduler_bin_dir` | `"{{ kube_scheduler_root_prefix }}{{ k8s_bin_dir \| default('/usr/local/bin') }}"` | - |
| `kube_scheduler_binary` | `"{{ kube_scheduler_bin_dir }}/kube-scheduler"` | - |
| `kube_scheduler_bin_mode` | `"0755"` | - |
| `kube_scheduler_root_owner` | `root` | - |
| `kube_scheduler_root_group` | `root` | - |
| `kube_scheduler_download_timeout` | `120` | - |
| `kube_scheduler_download_retries` | `3` | - |
| `kube_scheduler_download_retry_delay` | `2` | - |
| `kube_scheduler_config_dir` | `"{{ kube_scheduler_root_prefix }}{{ k8s_config_dir \| default('/etc/kubernetes') }}"` | - |
| `kube_scheduler_pki_dir` | `"{{ kube_scheduler_config_dir }}/pki"` | - |
| `kube_scheduler_unit_dir` | `"{{ kube_scheduler_root_prefix }}{{ kube_systemd_dir \| default('/etc/systemd/system') }}"` | - |
| `kube_scheduler_unit_name` | `kube-scheduler.service` | - |
| `kube_scheduler_unit_path` | `"{{ kube_scheduler_unit_dir }}/{{ kube_scheduler_unit_name }}"` | - |
| `kube_scheduler_unit_mode` | `"0644"` | - |
| `kube_scheduler_kubeconfig` | `"{{ kube_scheduler_config_dir }}/scheduler.conf"` | - |
| `kube_scheduler_client_ca_file` | `"{{ kube_scheduler_pki_dir }}/ca.crt"` | - |
| `kube_scheduler_front_proxy_ca_file` | `"{{ kube_scheduler_pki_dir }}/front-proxy-ca.crt"` | - |
| `kube_scheduler_requestheader_allowed_names` | `front-proxy-client` | - |
| `kube_scheduler_requestheader_extra_headers_prefix` | `X-Remote-Extra-` | - |
| `kube_scheduler_requestheader_group_headers` | `X-Remote-Group` | - |
| `kube_scheduler_requestheader_username_headers` | `X-Remote-User` | - |
| `kube_scheduler_leader_elect` | `true` | - |
| `kube_scheduler_bind_address` | `"127.0.0.1"` | - |
| `kube_scheduler_secure_port` | `10259` | - |
| `kube_scheduler_profiling` | `false` | - |
| `kube_scheduler_log_level` | `2` | - |
| `kube_scheduler_extra_args` | `[]` | - |
| `kube_scheduler_manage_service` | `true` | - |
| `kube_scheduler_service_enabled` | `true` | - |
| `kube_scheduler_service_state` | `started` | - |
| `kube_scheduler_service_type` | `simple` | - |
| `kube_scheduler_user` | `root` | - |
| `kube_scheduler_group` | `root` | - |
| `kube_scheduler_restart_sec` | `5` | - |
| `kube_scheduler_limit_nofile` | `65536` | - |
| `kube_scheduler_check_port_conflict` | `true` | - |
| `kube_scheduler_required_files` | `（映射/列表，见 defaults）` | - |
| **role: kubelet** | | |
| `kubelet_root_prefix` | `""` | - |
| `kubelet_version` | `"{{ k8s_version \| default('1.31.0') }}"` | - |
| `kubelet_arch` | `"{{ k8s_arch \| default('amd64') }}"` | - |
| `kubelet_download_url_base` | `"https://dl.k8s.io"` | - |
| `kubelet_download_url` | `（多行，见 defaults）` | - |
| `kubelet_known_sha256` | `（映射/列表，见 defaults）` | - |
| `kubelet_sha256` | `"{{ kubelet_known_sha256[kubelet_version] \| default('') }}"` | - |
| `kubelet_checksum_timeout` | `30` | - |
| `kubelet_artifact_dir` | `"{{ kubelet_root_prefix }}{{ k8s_artifact_dir \| default('/opt/k8s/artifacts') }}"` | - |
| `kubelet_artifact_path` | `"{{ kubelet_artifact_dir }}/kubelet"` | - |
| `kubelet_bin_dir` | `"{{ kubelet_root_prefix }}{{ k8s_bin_dir \| default('/usr/local/bin') }}"` | - |
| `kubelet_binary` | `"{{ kubelet_bin_dir }}/kubelet"` | - |
| `kubelet_bin_mode` | `"0755"` | - |
| `kubelet_root_owner` | `root` | - |
| `kubelet_root_group` | `root` | - |
| `kubelet_download_timeout` | `120` | - |
| `kubelet_download_retries` | `3` | - |
| `kubelet_download_retry_delay` | `2` | - |
| `kubelet_config_dir` | `"{{ kubelet_root_prefix }}{{ k8s_config_dir \| default('/etc/kubernetes') }}"` | - |
| `kubelet_pki_dir` | `"{{ kubelet_config_dir }}/pki"` | - |
| `kubelet_root_dir` | `"{{ kubelet_root_prefix }}/var/lib/kubelet"` | - |
| `kubelet_cert_dir` | `"{{ kubelet_root_dir }}/pki"` | - |
| `kubelet_config_path` | `"{{ kubelet_root_dir }}/config.yaml"` | - |
| `kubelet_kubeconfig_path` | `"{{ kubelet_root_dir }}/kubelet.conf"` | - |
| `kubelet_root_dir_mode` | `"0750"` | - |
| `kubelet_config_mode` | `"0644"` | - |
| `kubelet_kubeconfig_mode` | `"0600"` | - |
| `kubelet_unit_dir` | `"{{ kubelet_root_prefix }}{{ kube_systemd_dir \| default('/etc/systemd/system') }}"` | - |
| `kubelet_unit_name` | `kubelet.service` | - |
| `kubelet_unit_path` | `"{{ kubelet_unit_dir }}/{{ kubelet_unit_name }}"` | - |
| `kubelet_unit_mode` | `"0644"` | - |
| `kubelet_client_ca_file` | `"{{ kubelet_pki_dir }}/ca.crt"` | - |
| `kubelet_client_cert_file` | `"{{ kubelet_pki_dir }}/kubelet/{{ inventory_hostname }}.crt"` | - |
| `kubelet_client_key_file` | `"{{ kubelet_pki_dir }}/kubelet/{{ inventory_hostname }}.key"` | - |
| `kubelet_expected_common_name` | `"system:node:{{ inventory_hostname }}"` | - |
| `kubelet_expected_organization` | `system:nodes` | - |
| `kubelet_hostname_override` | `"{{ inventory_hostname }}"` | - |
| `kubelet_node_ip` | `"{{ ansible_host \| default(inventory_hostname) }}"` | - |
| `kubelet_apiserver_url` | `（多行，见 defaults）` | - |
| `kubelet_cluster_domain` | `"{{ k8s_dns_domain \| default('cluster.local') }}"` | - |
| `kubelet_container_runtime_endpoint` | `"unix:///run/containerd/containerd.sock"` | - |
| `kubelet_cgroup_driver` | `"{{ container_runtime_cgroup_driver \| default('systemd') }}"` | - |
| `kubelet_require_systemd_cgroup` | `true` | - |
| `kubelet_fail_swap_on` | `true` | - |
| `kubelet_address` | `"0.0.0.0"` | - |
| `kubelet_port` | `10250` | - |
| `kubelet_healthz_port` | `10248` | - |
| `kubelet_read_only_port` | `0` | - |
| `kubelet_resolv_conf` | `/etc/resolv.conf` | - |
| `kubelet_static_pod_path` | `""` | - |
| `kubelet_log_level` | `2` | - |
| `kubelet_extra_args` | `[]` | - |
| `kubelet_anonymous_auth` | `false` | - |
| `kubelet_authorization_mode` | `"Webhook"` | - |
| `kubelet_webhook_auth_enabled` | `true` | - |
| `kubelet_rotate_certificates` | `false` | - |
| `kubelet_manage_service` | `true` | - |
| `kubelet_service_enabled` | `true` | - |
| `kubelet_service_state` | `started` | - |
| `kubelet_service_type` | `simple` | - |
| `kubelet_user` | `root` | - |
| `kubelet_group` | `root` | - |
| `kubelet_restart_sec` | `10` | - |
| `kubelet_limit_nofile` | `1048576` | - |
| **role: pki** | | |
| `pki_root_prefix` | `""` | - |
| `pki_config_dir` | `"{{ k8s_config_dir \| default('/etc/kubernetes') }}"` | - |
| `pki_dir` | `"{{ pki_root_prefix }}{{ pki_config_dir }}/pki"` | - |
| `pki_etcd_dir` | `"{{ pki_dir }}/etcd"` | - |
| `pki_kubelet_dir` | `"{{ pki_dir }}/kubelet"` | - |
| `pki_build_dir` | `"{{ pki_root_prefix }}/var/cache/kubernetes-pki"` | 构建目录：CSR / openssl 扩展 / CA 序列号；默认用后即清理，不污染 PKI 目录 |
| `pki_cleanup_build_dir` | `true` | - |
| `pki_dir_mode` | `"0700"` | - |
| `pki_cert_mode` | `"0644"` | - |
| `pki_key_mode` | `"0600"` | - |
| `pki_pub_mode` | `"0644"` | - |
| `pki_file_owner` | `"{{ k8s_pki_owner \| default('root') }}"` | 沙箱测试时置为 {{ omit }}（以普通用户运行也能验证内容与权限） |
| `pki_file_group` | `"{{ k8s_pki_group \| default('root') }}"` | - |
| `pki_key_type` | `RSA                 # RSA \| EC` | - |
| `pki_key_size` | `2048                # RSA 位数` | - |
| `pki_ec_curve` | `prime256v1          # EC 曲线（pki_key_type=EC 时生效）` | - |
| `pki_digest` | `sha256` | - |
| `pki_organization` | `Kubernetes` | - |
| `pki_ca_duration_days` | `3650` | - |
| `pki_cert_duration_days` | `3650` | - |
| `pki_key_algorithm` | `"{{ 'RSA' if pki_key_type \| upper == 'RSA' else 'EC' }}"` | - |
| `pki_key_generation_opt` | `（多行，见 defaults）` | - |
| `pki_renew_before_seconds` | `2592000` | 证书剩余有效期小于该秒数 → 视为需要重签（默认 30 天） |
| `pki_force_regen` | `false` | 显式强制全量重签（例如 SAN 集合发生变化后；默认 false = 不打扰既有有效证书） |
| `pki_verify_chain` | `true` | 落盘后做链式校验（openssl verify + 有效期），失败即让 role 失败 |
| `pki_master_group` | `k8s_master` | - |
| `pki_node_group` | `k8s_node` | - |
| `pki_etcd_group` | `etcd` | - |
| `k8s_vip` | `""` | 集群 VIP（复用全局变量 k8s_vip；未定义/为空则不写入 apiserver SAN） |
| `pki_host_addresses` | `{}` | 主机地址显式覆盖：{ "<inventory_host>": "<address>" }；缺省取 hostvars[*].ansible_host |
| `pki_dns_domain` | `"{{ k8s_dns_domain \| default('cluster.local') }}"` | - |
| `pki_kubernetes_service_name` | `kubernetes` | - |
| `pki_service_cidr` | `"{{ k8s_service_cidr \| default('10.96.0.0/12') }}"` | - |
| `pki_apiserver_service_ip_override` | `""` | kubernetes.default 的 ClusterIP：默认取服务网段第一个可用地址（可用变量显式覆盖） |
| `_pki_service_octets` | `"{{ (pki_service_cidr \| string).split('/')[0].split('.') }}"` | - |
| `pki_apiserver_service_ip` | `（多行，见 defaults）` | - |
| `pki_ca_common_name` | `kubernetes-ca` | - |
| `pki_etcd_ca_common_name` | `etcd-ca` | - |
| `pki_front_proxy_ca_common_name` | `front-proxy-ca` | - |
| `pki_apiserver_common_name` | `kube-apiserver` | - |
| `pki_admin_common_name` | `kubernetes-admin` | - |
| `pki_admin_organization` | `system:masters` | - |
| `pki_kubelet_common_name_prefix` | `"system:node:"` | - |
| `pki_kubelet_organization` | `system:nodes` | - |
| `pki_etcd_server_common_name` | `etcd-server` | - |
| `pki_etcd_peer_common_name` | `etcd-peer` | - |
| `pki_apiserver_etcd_client_common_name` | `kube-apiserver-etcd-client` | - |
| `pki_front_proxy_client_common_name` | `front-proxy-client` | - |
| `pki_localhost_sans` | `["localhost", "127.0.0.1"]` | - |
| `pki_include_nodes_in_apiserver_sans` | `true` | 是否把工作节点也写进 apiserver 证书 SAN（验收要求「覆盖 VIP 与全部 master/节点名」） |
| `pki_apiserver_extra_sans` | `[]` | - |
| `pki_etcd_extra_sans` | `[]` | - |
| `pki_etcd_peer_extra_sans` | `[]` | - |
| `pki_kubelet_extra_sans` | `[]` | - |
| `pki_sa_key_path` | `"{{ pki_dir }}/sa.key"` | - |
| `pki_sa_pub_path` | `"{{ pki_dir }}/sa.pub"` | - |
| `pki_cas` | `（映射/列表，见 defaults）` | - |
| `pki_certs` | `（映射/列表，见 defaults）` | sans 引用 tasks/facts.yml 推导出的变量（inventory 分组 + k8s_vip + 服务网段） |
| **role: taints** | | |
| `taints_kubectl` | `/usr/local/bin/kubectl` | 必须是绝对路径（validate 会 stat 并断言可执行）。 |
| `taints_kubeconfig` | `/etc/kubernetes/admin.conf` | - |
| `taints_kubectl_extra_args` | `[]` | 额外 kubectl 参数（例如沙箱缓存目录：["--cache-dir", "/tmp/.../cache"]） |
| `taints_control_plane_nodes` | `"{{ groups['k8s_master'] \| default([]) }}"` | 默认直接取 inventory 的 [k8s_master] 分组；可显式覆盖为节点名列表。 |
| `taints_control_plane_taint_key` | `node-role.kubernetes.io/control-plane` | - |
| `taints_control_plane_taint_value` | `""` | - |
| `taints_control_plane_taint_effect` | `NoSchedule` | - |
| `taints_expected_taint` | `（多行，见 defaults）` | 形如 key=value:effect；value 为空时输出 key:effect（kubectl taint 语法）。 |
| `taints_allowed_effects` | `（映射/列表，见 defaults）` | - |
| `taints_key_pattern` | `'^([A-Za-z0-9][-A-Za-z0-9_.]*/)?[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$'` | Kubernetes 标识符字符集（key 允许一个 DNS 前缀；value 允许为空）。 |
| `taints_value_pattern` | `'^([A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?)?$'` | - |
| `taints_manage_taint` | `true` | 是否写入污点（false 时只管理标签） |
| `taints_manage_label` | `true` | - |
| `taints_control_plane_label_key` | `node-role.kubernetes.io/control-plane` | - |
| `taints_control_plane_label_value` | `""` | - |
| `taints_require_control_plane_membership` | `true` | true：执行 role 的主机必须属于 inventory 的 [k8s_master] 分组。 |
| `taints_wait_for_nodes` | `true` | true：等待 Node 对象出现（控制面 kubelet 可能稍后才注册）。 |
| `taints_wait_retries` | `30` | - |
| `taints_wait_delay` | `2` | - |
| **role: upgrade** | | |
| `upgrade_action` | `upgrade` | - |
| `upgrade_version` | `"{{ k8s_version \| default('') }}"` | - |
| `upgrade_allow_minor_jump` | `false` | - |
| `upgrade_allow_downgrade` | `false` | - |
| `upgrade_arch` | `"{{ k8s_arch \| default('amd64') }}"` | - |
| `upgrade_control_plane_components` | `（映射/列表，见 defaults）` | - |
| `upgrade_node_components` | `（映射/列表，见 defaults）` | - |
| `upgrade_is_worker` | `"{{ inventory_hostname in (groups['k8s_node'] \| default([])) }}"` | 由 inventory 分组自动判定当前主机角色（cp / worker） |
| `upgrade_components` | `"{{ upgrade_node_components if upgrade_is_worker else upgrade_control_plane_components }}"` | - |
| `upgrade_component_version_args` | `（映射/列表，见 defaults）` | 版本探测参数（kubectl 不支持 --version，只能 `kubectl version --client`） |
| `upgrade_version_probe_component` | `"{{ upgrade_components \| first }}"` | 版本探针：控制面取 kube-apiserver、节点取 kubelet（清单首项） |
| `upgrade_root_prefix` | `""` | - |
| `upgrade_root_owner` | `root` | - |
| `upgrade_root_group` | `root` | - |
| `upgrade_bin_dir` | `"{{ upgrade_root_prefix }}/usr/local/bin"` | - |
| `upgrade_artifact_dir` | `"{{ upgrade_root_prefix }}/opt/k8s/artifacts"` | - |
| `upgrade_staging_dir` | `"{{ upgrade_root_prefix }}/opt/k8s/staging"` | 可执行探针暂存目录（缓存制品可能 0644；探测前复制为 0755，不改缓存本身） |
| `upgrade_pki_dir` | `"{{ upgrade_root_prefix }}/etc/kubernetes/pki"` | - |
| `upgrade_kubeconfig_files_control_plane` | `（映射/列表，见 defaults）` | kubeconfig / 节点配置文件（相对系统根的路径；任务内拼 upgrade_root_prefix） |
| `upgrade_kubeconfig_files_node` | `（映射/列表，见 defaults）` | - |
| `upgrade_kubeconfig_files` | `（多行，见 defaults）` | - |
| `upgrade_kubectl` | `"{{ upgrade_root_prefix }}/usr/local/bin/kubectl"` | - |
| `upgrade_kubeconfig` | `"{{ upgrade_root_prefix }}/etc/kubernetes/admin.conf"` | - |
| `upgrade_download_url_base` | `"https://dl.k8s.io"` | - |
| `upgrade_download_timeout` | `120` | - |
| `upgrade_download_retries` | `3` | - |
| `upgrade_download_retry_delay` | `2` | - |
| `upgrade_known_sha256` | `（映射/列表，见 defaults）` | 官方 sha256 固定表（离线可复现；新版本必须显式补充，否则拒绝升级） |
| `upgrade_backup_root` | `"{{ upgrade_root_prefix }}/var/backups/kubernetes/upgrade"` | - |
| `upgrade_backup_retention` | `5` | - |
| `upgrade_backup_etcd` | `"{{ not (upgrade_is_worker \| bool) }}"` | - |
| `upgrade_backup_pki` | `true` | - |
| `upgrade_backup_min_files` | `4` | - |
| `upgrade_etcdctl` | `"{{ upgrade_root_prefix }}/usr/local/bin/etcdctl"` | - |
| `upgrade_etcd_endpoints` | `["https://127.0.0.1:2379"]` | - |
| `upgrade_etcd_ca_file` | `"{{ upgrade_pki_dir }}/etcd/ca.crt"` | - |
| `upgrade_etcd_cert_file` | `"{{ upgrade_pki_dir }}/apiserver-etcd-client.crt"` | - |
| `upgrade_etcd_key_file` | `"{{ upgrade_pki_dir }}/apiserver-etcd-client.key"` | - |
| `upgrade_etcd_snapshot_timeout` | `120` | - |
| `upgrade_verify_cluster_version` | `true` | - |
| `upgrade_require_ready_nodes` | `true` | - |
| `upgrade_expected_nodes` | `"{{ groups['k8s_node'] \| default([]) }}"` | - |
| `upgrade_needed` | `true` | 是否需要变更（validate 阶段由二进制/集群版本计算；默认 true 便于单跑子 tag） |
| `upgrade_manage_service` | `true` | - |
| `upgrade_service_names_control_plane` | `（映射/列表，见 defaults）` | - |
| `upgrade_service_names_node` | `（映射/列表，见 defaults）` | - |
| `upgrade_service_names` | `（多行，见 defaults）` | - |
| `upgrade_etcd_service_name` | `etcd` | - |
| `upgrade_rollback_dir` | `""` | - |
| `upgrade_rollback_etcd_offline_ack` | `false` | 替换 etcd 数据目录前必须确认 etcd 已停止（沙箱显式 ack；生产由 role 停服务） |
| `upgrade_rollback_etcd_data_dir` | `"{{ upgrade_root_prefix }}/var/lib/etcd"` | - |
| `upgrade_rollback_etcd_member_name` | `default` | 单成员默认值。多成员集群必须显式覆盖（与 roles/etcd 的 etcd_member_name: "{{ inventory_hostname }}" + TLS peer 对齐）： -e upgrade_rollback_etcd_member_name=<inventory_hostname> -e upgrade_rollback_etcd_initial_peer_url=https://<peer_ip>:2380 （member 名必须与快照中的成员名一致，否则 restore 后 peer 地址错位） |
| `upgrade_rollback_etcd_initial_peer_url` | `"http://localhost:2380"` | restore 的初始集群（名称必须与快照中的成员名一致；单成员用本机 peer URL 即可） |
| `upgrade_rollback_etcd_initial_cluster` | `"{{ upgrade_rollback_etcd_member_name }}={{ upgrade_rollback_etcd_initial_peer_url }}"` | - |
| `upgrade_rollback_etcd_data_owner` | `etcd` | - |
| `upgrade_rollback_etcd_data_group` | `etcd` | - |
| `upgrade_rollback_etcd_data_mode` | `"0700"` | - |

共 **886** 个默认变量。
