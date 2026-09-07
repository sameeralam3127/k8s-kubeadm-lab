# =============================================================================
# k8s-kubeadm-lab - convenience wrappers around ./lab
# Everything here just calls ./lab; use that directly if you prefer.
#   make help
# =============================================================================
.DEFAULT_GOAL := help
.PHONY: help config check ssh-setup preflight up prep init join addons verify \
        status kubeconfig backup backups restore dr-drill diagnostics reset \
        labs lint clean

LAB := ./lab

help: ## Show this help
	@echo "k8s-kubeadm-lab"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Config lives in lab.env  (make config creates it)"

config: lab.env ## Create lab.env from the example
lab.env:
	@cp lab.env.example lab.env
	@echo "Created lab.env - edit it with your node IPs, then run: make check"

check: ## Validate lab.env and SSH reachability
	@$(LAB) check

ssh-setup: ## Create an SSH key and install it on every node
	@$(LAB) ssh-setup

preflight: ## Read-only readiness checks on every node
	@$(LAB) preflight

up: ## Build the entire cluster (preflight -> prep -> init -> join -> verify)
	@$(LAB) up

prep: ## Prepare every node (swap, sysctl, containerd, kube tools)
	@$(LAB) prep

init: ## kubeadm init + CNI on the control plane
	@$(LAB) init

join: ## Join every worker
	@$(LAB) join

addons: ## metrics-server, local-path storage, helm, etcdctl
	@$(LAB) addons

verify: ## Full health check including a live smoke test
	@$(LAB) verify

status: ## One-screen cluster overview
	@$(LAB) status

kubeconfig: ## Fetch admin.conf so local kubectl works
	@$(LAB) kubeconfig

backup: ## Snapshot etcd and pull it to ./backups  (make backup LABEL=nightly)
	@$(LAB) backup $(LABEL)

backups: ## List snapshots, remote and local
	@$(LAB) backups

restore: ## Restore etcd  (make restore SNAP=backups/etcd-snapshot-....db)
	@$(LAB) restore $(or $(SNAP),--latest)

dr-drill: ## Guided disaster-recovery exercise
	@$(LAB) dr-drill

diagnostics: ## Collect support bundles from every node
	@$(LAB) diagnostics

reset: ## Tear the cluster down  (make reset NODE=all)
	@$(LAB) reset $(or $(NODE),all)

labs: ## List the hands-on exercises
	@$(LAB) labs

lint: ## Syntax-check every shell script in the repo
	@fail=0; \
	for f in lab $$(find scripts labs -name '*.sh'); do \
	  if bash -n "$$f" 2>/dev/null; then \
	    printf '  ok    %s\n' "$$f"; \
	  else \
	    printf '  FAIL  %s\n' "$$f"; bash -n "$$f"; fail=1; \
	  fi; \
	done; \
	if command -v shellcheck >/dev/null 2>&1; then \
	  echo; echo "shellcheck:"; \
	  shellcheck -S warning lab $$(find scripts labs -name '*.sh') || fail=1; \
	  [ $$fail -eq 0 ] && echo "  no findings"; \
	else \
	  echo; echo "  (install shellcheck for deeper analysis)"; \
	fi; \
	exit $$fail

clean: ## Remove locally generated files (keeps backups)
	@rm -rf diagnostics kubeconfig .known_hosts
	@echo "Removed diagnostics/, kubeconfig and .known_hosts (backups/ kept)"
