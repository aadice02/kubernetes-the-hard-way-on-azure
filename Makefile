MAKEFLAGS += --silent
SHELL := /usr/bin/env bash
ENV_FILE := $(PWD)/.env
DOCKER_COMPOSE := docker-compose
KUBERNETES_VERSION ?= 1.18.6
ETCD_VERSION ?= 3.4.10
CRICTL_VERSION ?= 1.18.0
RUNC_VERSION ?= 1.0.0-rc91
CONTAINERD_VERSION ?= 1.3.6
CNI_VERSION ?= 0.8.6
AZURE_RESOURCE_GROUP ?= kubernetes

ifneq (,$(wildcard $(ENV_FILE)))
	include $(PWD)/.env
	export
endif

_ensure_test_ssh_key:
	if ! test -f "id_rsa" || ! test -f "id_rsa.pub"; \
	then \
		>&2 echo "INFO: Generating SSH keys for test machine. \
These will not be committed to your Git history."; \
		ssh-keygen -t rsa -f id_rsa -q -N '' && \
			cat ./id_rsa.pub >> ./authorized_keys; \
	fi

_rebuild_dc_service_on_change:
	for changed_service in $$(git status --porcelain | \
		grep ".Dockerfile" | \
		cut -f3 -d ' ' | \
		sed 's/.Dockerfile//'); \
	do \
		>&2 echo "INFO: Rebuilding '$$changed_service'; commit this file to stop this."; \
		$(DOCKER_COMPOSE) build -q $$changed_service; \
	done

env:
	if ! test -f $(ENV_FILE); \
	then \
		>&2 echo "INFO: Creating new env file."; \
		grep -Ev '(^#|^$$)' $(ENV_FILE).example > $(ENV_FILE); \
		>&2 echo "INFO: Done. Open '$(ENV_FILE)' and replace \"change_me\" with real values."; \
	fi

tests: _ensure_test_ssh_key _rebuild_dc_service_on_change
tests:
	docker-compose up -d && \
	$(DOCKER_COMPOSE) run --rm \
		--entrypoint ansible-playbook \
		tests \
		--private-key "/ssh_key" \
		--inventory "test_machine," \
		--extra-vars "azure_tenant_id=$$AZURE_TENANT_ID" \
		--extra-vars "azure_client_id=$$AZURE_CLIENT_ID" \
		--extra-vars "azure_client_secret=$$AZURE_CLIENT_SECRET" \
		--extra-vars "azure_region=$$AZURE_REGION" \
		--extra-vars "azure_resource_group=$(AZURE_RESOURCE_GROUP)" \
    --extra-vars "etcd_version=$(ETCD_VERSION)" \
		--extra-vars "crictl_version=$(CRICTL_VERSION)" \
		--extra-vars "runc_version=$(RUNC_VERSION)" \
		--extra-vars "cni_version=$(CNI_VERSION)" \
		--extra-vars "containerd_version=$(CONTAINERD_VERSION)" \
    --extra-vars "kubernetes_version=$(KUBERNETES_VERSION)" \
		tests.yaml; \
	result=$$?; \
	if test "$(TEARDOWN)" == "true"; \
	then \
		$(DOCKER_COMPOSE) down -t 1; \
	fi; \
	exit $$result; \

# An alias for tests.
test: tests

# TECH NOTE: Why aren't we using Terraform for deployments?
# Terraform adds a BUNCH of complexity to this setup, namely:
# - We will 100% have to use this wrapper to have Terraform and Azure
#   play nicely together: https://github.com/carlosonunez/terraform-azure-wrapper
# - It adds several seconds of time to our tests. Command line arguments are quicker.
# - I would use Terraform if I were writing the next kubeadm or something. Given that
#   provisioning "bare metal" Kubernetes clusters are a solved problem and that this
#   is just for learning/testing docs, using 'az' for these steps is a ton easier.
deploy: _ensure_test_ssh_key _rebuild_dc_service_on_change
deploy:
	docker-compose up -d && \
	$(DOCKER_COMPOSE) run --rm \
		--entrypoint ansible-playbook \
		deployer \
		--private-key "/ssh_key" \
		--inventory "test_machine," \
		--extra-vars "azure_tenant_id=$$AZURE_TENANT_ID" \
		--extra-vars "azure_client_id=$$AZURE_CLIENT_ID" \
		--extra-vars "azure_client_secret=$$AZURE_CLIENT_SECRET" \
		--extra-vars "azure_region=$$AZURE_REGION" \
		--extra-vars "azure_resource_group=$(AZURE_RESOURCE_GROUP)" \
    --extra-vars "etcd_version=$(ETCD_VERSION)" \
		--extra-vars "crictl_version=$(CRICTL_VERSION)" \
		--extra-vars "runc_version=$(RUNC_VERSION)" \
		--extra-vars "cni_version=$(CNI_VERSION)" \
		--extra-vars "containerd_version=$(CONTAINERD_VERSION)" \
    --extra-vars "kubernetes_version=$(KUBERNETES_VERSION)" \
		deploy.yaml; \
	result=$$?; \
	if test "$(TEARDOWN)" == "true"; \
	then \
		$(DOCKER_COMPOSE) down -t 1; \
	fi; \
	>&2 echo "DEBUG: exit $$result"; \
	exit $$result; \

deploy_then_test: deploy tests

debug:
	$(DOCKER_COMPOSE) run --rm --entrypoint bash test-container;

clean:
	>&2 read -p "WARNING: You are going to delete *** YOUR ENTIRE *** Kubernetes lab cluster. Type \"yes\" to continue: " choice; \
	choice_lower=$$(echo "$$choice" | tr '[:upper:]' '[:lower:]'); \
	if test "$$choice_lower"  != "yes"; \
	then \
		>&2 echo "'make clean' stopped."; \
		exit 0; \
	fi; \
	$(DOCKER_COMPOSE) run --rm kthw_az group delete -g "$(AZURE_RESOURCE_GROUP)" --yes && \
		rm -r secrets/* cache/* manifests/*	
