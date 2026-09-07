#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# 10-init-control-plane.sh - bootstrap the control plane with kubeadm.
# Run ONLY on the control-plane node. Idempotent (detects an existing cluster).
#
#   sudo APISERVER_IP=192.168.1.101 POD_CIDR=192.168.0.0/16 ./10-init-control-plane.sh
#
# Env:
#   APISERVER_IP    IP the API server advertises (this node's LAN IP)
#   POD_CIDR        must match your CNI (calico 192.168.0.0/16, flannel 10.244.0.0/16)
#   SERVICE_CIDR    default 10.96.0.0/12
#   NODE_NAME       node name to register as (defaults to hostname)
#   KUBE_VERSION    e.g. v1.31.4 (defaults to the installed kubeadm version)
#   ALLOW_CP_WORKLOADS=1   remove the control-plane taint (handy on a 1-node lab)
#
# Output: writes /root/kubeadm-join.sh and /etc/kubernetes/admin.conf
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
strict_mode
require_root

POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
APISERVER_IP="${APISERVER_IP:-$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')}"
KUBE_VERSION="${KUBE_VERSION:-}"
CONFIG=/etc/kubernetes/kubeadm-config.yaml

[ -n "$APISERVER_IP" ] || die "Could not determine APISERVER_IP - pass it explicitly."

section "Cluster parameters"
info "node name      : ${NODE_NAME}"
info "advertise addr : ${APISERVER_IP}"
info "pod CIDR       : ${POD_CIDR}"
info "service CIDR   : ${SERVICE_CIDR}"

if [ -f /etc/kubernetes/admin.conf ]; then
  warn "This node already has /etc/kubernetes/admin.conf - a cluster exists here."
  confirm "Reset and re-initialise from scratch? (destroys the current cluster)" || {
    info "Leaving the existing cluster alone. Regenerating a join command instead."
    kubeadm token create --print-join-command > /root/kubeadm-join.sh
    chmod 0600 /root/kubeadm-join.sh
    ok "Join command refreshed at /root/kubeadm-join.sh"
    exit 0
  }
  kubeadm reset -f >/dev/null
  rm -rf /etc/cni/net.d /root/.kube
  ok "Previous cluster reset"
fi

section "1/5  Pre-pull control-plane images"
# Pulling first turns a slow, opaque init into a fast, predictable one.
kubeadm config images pull ${KUBE_VERSION:+--kubernetes-version "$KUBE_VERSION"} >/dev/null
ok "Images cached locally"

section "2/5  Write kubeadm config"
# A config file (rather than a pile of flags) is what real clusters use, and it
# is what you will be asked to edit during upgrades and troubleshooting.
cat > "$CONFIG" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${APISERVER_IP}
  bindPort: 6443
nodeRegistration:
  name: ${NODE_NAME}
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: ${APISERVER_IP}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
${KUBE_VERSION:+kubernetesVersion: ${KUBE_VERSION}}
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
apiServer:
  certSANs:
    - ${APISERVER_IP}
    - ${NODE_NAME}
    - localhost
    - 127.0.0.1
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
# Free disk space aggressively in a small lab VM.
evictionHard:
  imagefs.available: "5%"
  nodefs.available: "5%"
EOF
# kubeadm v1beta4 landed in 1.31. Fall back to v1beta3 for older kubeadm.
KUBEADM_MINOR="$(kubeadm version -o short | sed -E 's/v1\.([0-9]+)\..*/\1/')"
if [ "${KUBEADM_MINOR:-31}" -lt 31 ]; then
  info "kubeadm < 1.31 detected; using the v1beta3 API and flag-style kubeletExtraArgs"
  sed -i 's|kubeadm.k8s.io/v1beta4|kubeadm.k8s.io/v1beta3|' "$CONFIG"
  python3 - "$CONFIG" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"  kubeletExtraArgs:\n    - name: node-ip\n      value: (\S+)\n",
           r"  kubeletExtraArgs:\n    node-ip: \1\n", s)
open(p, "w").write(s)
PY
fi
ok "Config written to ${CONFIG}"

section "3/5  kubeadm init"
kubeadm init --config "$CONFIG" --upload-certs | tee /root/kubeadm-init.log
ok "Control plane initialised"

section "4/5  kubeconfig"
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

# Give the login user a working kubectl too, without needing sudo.
LOGIN_USER="${SUDO_USER:-}"
if [ -n "$LOGIN_USER" ] && [ "$LOGIN_USER" != "root" ]; then
  HOME_DIR="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"
  mkdir -p "${HOME_DIR}/.kube"
  cp -f /etc/kubernetes/admin.conf "${HOME_DIR}/.kube/config"
  chown -R "$(id -u "$LOGIN_USER")":"$(id -g "$LOGIN_USER")" "${HOME_DIR}/.kube"
  ok "kubeconfig installed for ${LOGIN_USER} and root"
else
  ok "kubeconfig installed for root"
fi

section "5/5  Join command"
kubeadm token create --print-join-command > /root/kubeadm-join.sh
chmod 0600 /root/kubeadm-join.sh
ok "Worker join command saved to /root/kubeadm-join.sh"

if [ "${ALLOW_CP_WORKLOADS:-0}" = "1" ]; then
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint nodes "$NODE_NAME" \
    node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  ok "Control-plane taint removed - pods can now schedule here"
fi

echo
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
echo
warn "The node reads NotReady until a CNI is installed. That is expected."
info "Next: sudo ./11-install-cni.sh"
