#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# 11-install-cni.sh - install the pod network. Run ONLY on the control plane,
# once, after kubeadm init. Idempotent.
#
#   sudo CNI=calico POD_CIDR=192.168.0.0/16 ./11-install-cni.sh
#
# Env:
#   CNI=calico|flannel|cilium
#   POD_CIDR             must match what kubeadm init used
#   CALICO_VERSION / FLANNEL_VERSION / CILIUM_VERSION
#
# Until a CNI runs, every node is NotReady and every pod stays Pending: the
# kubelet refuses to declare readiness without a working network plugin.
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
strict_mode
require_root
export KUBECONFIG=/etc/kubernetes/admin.conf

CNI="${CNI:-calico}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.2}"
FLANNEL_VERSION="${FLANNEL_VERSION:-v0.25.6}"
CILIUM_VERSION="${CILIUM_VERSION:-1.16.3}"

need kubectl
[ -f "$KUBECONFIG" ] || die "No admin.conf - run 10-init-control-plane.sh first."

if kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
  if kubectl -n kube-system get ds 2>/dev/null | grep -qE 'calico|flannel|cilium'; then
    skip "A CNI is already installed and the node is Ready"
    kubectl get nodes -o wide
    exit 0
  fi
fi

section "Installing CNI: ${CNI} (pod CIDR ${POD_CIDR})"

case "$CNI" in

  calico)
    # Calico ships as an operator (tigera) plus a CR that carries the pod CIDR.
    kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" 2>/dev/null \
      || kubectl replace -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
    wait_for 180 "tigera-operator deployment" \
      kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=10s

    cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: ${POD_CIDR}
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
    wait_for 300 "calico-node pods" bash -c \
      'kubectl -n calico-system get ds calico-node -o jsonpath="{.status.numberReady}" 2>/dev/null | grep -qE "^[1-9]"'
    ;;

  flannel)
    [ "$POD_CIDR" = "10.244.0.0/16" ] || warn "Flannel expects 10.244.0.0/16; you set ${POD_CIDR}"
    TMP="$(mktemp)"
    curl -fsSL "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" -o "$TMP"
    sed -i "s|10.244.0.0/16|${POD_CIDR}|g" "$TMP"
    kubectl apply -f "$TMP"
    rm -f "$TMP"
    wait_for 240 "flannel pods" bash -c \
      'kubectl -n kube-flannel get ds kube-flannel-ds -o jsonpath="{.status.numberReady}" 2>/dev/null | grep -qE "^[1-9]"'
    ;;

  cilium)
    if ! command -v cilium >/dev/null 2>&1; then
      ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && ARCH=amd64 || ARCH=arm64
      CLI_VER="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
      curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${CLI_VER}/cilium-linux-${ARCH}.tar.gz" \
        | tar xz -C /usr/local/bin cilium
      ok "cilium CLI ${CLI_VER} installed"
    fi
    cilium install --version "${CILIUM_VERSION}" \
      --set ipam.operator.clusterPoolIPv4PodCIDRList="${POD_CIDR}"
    cilium status --wait --wait-duration 5m
    ;;

  *) die "Unknown CNI '${CNI}'. Use calico, flannel or cilium." ;;
esac

section "Waiting for the control plane to become Ready"
wait_for 300 "node Ready condition" bash -c \
  'kubectl get nodes --no-headers | awk "{print \$2}" | grep -q "^Ready"'

# CoreDNS stays Pending without a CNI - its readiness is the real proof.
wait_for 240 "CoreDNS" \
  kubectl -n kube-system rollout status deploy/coredns --timeout=10s

echo
kubectl get nodes -o wide
echo
kubectl get pods -A -o wide | grep -vE 'Running|Completed' || ok "All system pods are Running"
echo
ok "Pod network is up."
info "Next: join workers, then run ./20-verify-cluster.sh"
