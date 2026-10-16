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
YAMLLINT  ?= yamllint

.DEFAULT_GOAL := help
.PHONY: help syntax yamllint lint test clean

help: ## 显示可用目标
	@echo "可用目标:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

syntax: ## 校验 playbook 语法 (ansible-playbook --syntax-check)
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) --syntax-check $(SITE)

yamllint: ## YAML 风格检查
	$(YAMLLINT) -c .yamllint .

lint: yamllint syntax ## 静态检查 (yamllint + syntax-check)

test: lint ## 运行测试套件
	tests/skeleton/test_skeleton.sh

clean: ## 清理运行产物
	@rm -f *.retry
