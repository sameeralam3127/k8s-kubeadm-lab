#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# 90-reset-node.sh - tear this node back down to a clean, pre-kubeadm state.
# DESTRUCTIVE. Use it to rebuild the lab from scratch (great CKA practice).
#
#   sudo ./90-reset-node.sh
#   sudo ASSUME_YES=1 PURGE_PACKAGES=1 ./90-reset-node.sh
#
# Env:
#   PURGE_PACKAGES=1   also apt-remove kubelet/kubeadm/kubectl/containerd
#   KEEP_BACKUPS=1     do not touch /opt/etcd-backups (default: keep them)
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
set -uo pipefail
require_root

echo
warn "This will destroy the Kubernetes installation on $(hostname)."
warn "Pods, cluster membership, certificates and CNI state will all be removed."
confirm "Continue?" || { info "Aborted."; exit 0; }

section "1/6  kubeadm reset"
if command -v kubeadm >/dev/null 2>&1; then
  kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock || warn "kubeadm reset reported errors; continuing"
  ok "kubeadm state removed"
else
  skip "kubeadm not installed"
fi

section "2/6  Stop kubelet"
systemctl stop kubelet 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true
ok "kubelet stopped"

section "3/6  Remove CNI and Kubernetes directories"
for d in /etc/cni/net.d /var/lib/cni /var/lib/kubelet /var/lib/etcd /etc/kubernetes \
         /root/.kube /var/run/kubernetes /opt/cni/bin/calico* ; do
  if compgen -G "$d" >/dev/null 2>&1; then rm -rf $d && info "removed $d"; fi
done
# Leftover virtual interfaces confuse a fresh CNI install.
for i in cni0 flannel.1 vxlan.calico cilium_host cilium_net cilium_vxlan kube-ipvs0 nodelocaldns; do
  ip link show "$i" >/dev/null 2>&1 && ip link delete "$i" 2>/dev/null && info "deleted interface $i"
done
ok "Network and state directories cleared"

section "4/6  Flush iptables / ipvs rules"
if command -v iptables >/dev/null 2>&1; then
  iptables -F; iptables -t nat -F; iptables -t mangle -F; iptables -X 2>/dev/null || true
  ok "iptables flushed"
fi
command -v ipvsadm >/dev/null 2>&1 && ipvsadm -C && ok "ipvs table cleared"

section "5/6  Clean up container state"
if command -v crictl >/dev/null 2>&1; then
  crictl rmp -fa >/dev/null 2>&1 || true
  ok "Removed leftover pod sandboxes"
fi
systemctl restart containerd 2>/dev/null || true

section "6/6  Packages"
if [ "${PURGE_PACKAGES:-0}" = "1" ]; then
  apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq kubelet kubeadm kubectl containerd || true
  apt-get autoremove -y -qq || true
  rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  ok "Kubernetes packages purged"
else
  skip "Packages kept (set PURGE_PACKAGES=1 to remove them)"
fi

if [ "${KEEP_BACKUPS:-1}" != "1" ]; then
  rm -rf /opt/etcd-backups && warn "etcd backups deleted"
else
  info "etcd backups in /opt/etcd-backups were left untouched"
fi

echo
ok "Node reset. Re-run 02-prep-node.sh onwards to rebuild."
info "A reboot is recommended before rebuilding: sudo reboot"
