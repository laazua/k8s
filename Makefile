# =============================================================================
#  Kubernetes 二进制部署 · 开发入口
#  用法: make help
# =============================================================================
SHELL := /bin/bash

# --- Ansible 探测：优先 $ANSIBLE_PLAYBOOK，其次 PATH，最后 $HOME/ansible 本地安装 ---
ANSIBLE_PLAYBOOK ?= $(shell command -v ansible-playbook 2>/dev/null || echo "$$HOME/ansible/bin/ansible-playbook")
ANSIBLE_HOME     := $(patsubst %/bin/ansible-playbook,%,$(ANSIBLE_PLAYBOOK))
ifneq ($(wildcard $(ANSIBLE_PLAYBOOK)),)
export PYTHONPATH := $(ANSIBLE_HOME)$(if $(PYTHONPATH),:$(PYTHONPATH),)
endif

INVENTORY ?= inventory/hosts.example
SITE      ?= playbooks/site.yml
PLAYBOOKS ?= $(wildcard playbooks/*.yml)
YAMLLINT  ?= yamllint

.DEFAULT_GOAL := help
.PHONY: help syntax yamllint smoke lint test test-download test-pki test-etcd test-ha test-control-plane test-node clean

help: ## 显示可用目标
	@echo "可用目标:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

syntax: ## 校验全部 playbook 语法 (ansible-playbook --syntax-check)
	@set -e; for p in $(PLAYBOOKS); do \
		echo "  syntax-check $$p"; \
		$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) --syntax-check $$p >/dev/null; \
	done
	@echo "  all playbooks OK"

yamllint: ## YAML 风格检查
	$(YAMLLINT) -c .yamllint .

smoke: ## 真实执行冒烟（localhost，验证配置可加载且可运行）
	$(ANSIBLE_PLAYBOOK) -i localhost, -c local $(SITE)

lint: yamllint syntax ## 静态检查 (yamllint + syntax-check)

test: lint smoke ## 运行测试套件（含真实执行冒烟）
	tests/skeleton/test_skeleton.sh
	tests/base/test_base_role.sh
	tests/download/test_download_role.sh
	tests/pki/test_pki_role.sh
	tests/etcd/test_etcd_role.sh
	tests/ha/test_ha_role.sh
	tests/control-plane/test_control_plane_roles.sh
	tests/node/test_node_roles.sh

test-download: ## 运行 download role 测试套件（全离线 mock 源/代理）
	tests/download/test_download_role.sh

test-pki: ## 运行 pki role 测试套件（离线 + 沙箱真实签发，宿主零污染）
	tests/pki/test_pki_role.sh

test-etcd: ## 运行 etcd role 测试套件（单机 3 实例真实集群 + 故障恢复，宿主零污染）
	tests/etcd/test_etcd_role.sh

test-ha: ## 运行 HA role 测试套件（netns 真实 VRRP 漂移 + haproxy 负载均衡）
	tests/ha/test_ha_role.sh

test-control-plane: ## 运行控制平面 role 测试套件（真实 etcd + 三组件进程，宿主零污染）
	tests/control-plane/test_control_plane_roles.sh

test-node: ## 运行节点运行时 role 测试套件（真实 containerd + kubelet + 控制面，宿主零污染）
	tests/node/test_node_roles.sh

clean: ## 清理运行产物
	@rm -f *.retry
