#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# 04-install-kube-tools.sh - install kubeadm, kubelet and kubectl from the
# official pkgs.k8s.io repository. Run on EVERY node. Idempotent.
#
#   sudo K8S_MINOR=v1.31 ./04-install-kube-tools.sh
#
# Env:
#   K8S_MINOR=v1.31          # which per-minor repo to add (required series)
#   K8S_PKG_VERSION=1.31.4-1.1   # exact version to pin (optional)
#
# Note: pkgs.k8s.io hosts a SEPARATE repo per minor version. Upgrading to a new
# minor means changing the repo URL, which is exactly what 06-upgrade lab does.
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
strict_mode
require_root

K8S_MINOR="${K8S_MINOR:-v1.31}"
K8S_PKG_VERSION="${K8S_PKG_VERSION:-}"
KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
LIST="/etc/apt/sources.list.d/kubernetes.list"
export DEBIAN_FRONTEND=noninteractive

section "1/4  Base packages"
retry 3 5 apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg
ok "Prerequisites present"

section "2/4  Add the Kubernetes ${K8S_MINOR} apt repository"
mkdir -p /etc/apt/keyrings
if [ -f "$KEYRING" ] && grep -q "${K8S_MINOR}/deb" "$LIST" 2>/dev/null; then
  skip "Repo for ${K8S_MINOR} already configured"
else
  rm -f "$KEYRING"
  retry 3 5 bash -c "curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key \
    | gpg --dearmor -o '${KEYRING}'"
  chmod 644 "$KEYRING"
  echo "deb [signed-by=${KEYRING}] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" > "$LIST"
  chmod 644 "$LIST"
  ok "Repository added for ${K8S_MINOR}"
fi
retry 3 5 apt-get update -qq

section "3/4  Install kubelet, kubeadm, kubectl"
# Packages are held to stop an unattended apt upgrade from breaking the cluster.
apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
if [ -n "$K8S_PKG_VERSION" ]; then
  info "Pinning to ${K8S_PKG_VERSION}"
  apt-get install -y -qq --allow-downgrades \
    "kubelet=${K8S_PKG_VERSION}" "kubeadm=${K8S_PKG_VERSION}" "kubectl=${K8S_PKG_VERSION}"
else
  apt-get install -y -qq kubelet kubeadm kubectl
fi
apt-mark hold kubelet kubeadm kubectl >/dev/null
ok "Installed and held: $(kubeadm version -o short)"

section "4/4  Enable kubelet and shell completion"
systemctl enable kubelet >/dev/null 2>&1
# kubelet crash-loops until kubeadm init/join writes its config. That is normal
# and expected at this point - do not chase it.
info "kubelet is enabled; it will crash-loop until kubeadm init/join runs. That is normal."

for f in /etc/bash_completion.d/kubectl /etc/bash_completion.d/kubeadm; do
  cmd="$(basename "$f")"
  "$cmd" completion bash > "$f" 2>/dev/null || true
done
if ! grep -q "alias k=kubectl" /etc/profile.d/k8s-lab.sh 2>/dev/null; then
  cat > /etc/profile.d/k8s-lab.sh <<'EOF'
# k8s-lab conveniences
alias k=kubectl
complete -o default -F __start_kubectl k 2>/dev/null || true
export KUBE_EDITOR="${KUBE_EDITOR:-vi}"
EOF
fi
ok "Completion installed; 'k' is an alias for kubectl on the next login"

echo
kubeadm version -o short
kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1 || true
echo
ok "Tools ready."
info "Control plane -> sudo ./10-init-control-plane.sh"
info "Worker        -> run the join command from the control plane"
