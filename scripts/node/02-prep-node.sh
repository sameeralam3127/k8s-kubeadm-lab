#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# 02-prep-node.sh - OS-level preparation. Run on EVERY node (CP and workers).
# Idempotent: safe to re-run.
#
#   sudo ./02-prep-node.sh
#
# Env:
#   NODE_NAME=k8s-cp              # set the hostname (optional)
#   HOSTS_ENTRIES="ip name\nip name"  # lines appended to /etc/hosts (optional)
#   ROLE=control-plane|worker     # which port set to open (default: worker)
#   CNI=calico|flannel|cilium     # which overlay ports to open
#   FIREWALL_MODE=open-ports      # open-ports (default) | disable | leave
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
strict_mode
require_root

NODE_NAME="${NODE_NAME:-}"
HOSTS_ENTRIES="${HOSTS_ENTRIES:-}"

section "1/6  Hostname"
if [ -n "$NODE_NAME" ] && [ "$(hostname)" != "$NODE_NAME" ]; then
  hostnamectl set-hostname "$NODE_NAME"
  # Keep /etc/hosts consistent so sudo doesn't complain about name resolution.
  if ! grep -qE "^127\.0\.1\.1\s+$NODE_NAME" /etc/hosts; then
    backup_file /etc/hosts
    sed -i '/^127\.0\.1\.1/d' /etc/hosts
    echo "127.0.1.1 ${NODE_NAME}" >> /etc/hosts
  fi
  ok "Hostname set to ${NODE_NAME}"
else
  skip "Hostname already '$(hostname)'"
fi

section "2/6  /etc/hosts entries for the cluster"
if [ -n "$HOSTS_ENTRIES" ]; then
  backup_file /etc/hosts
  # Rewrite our managed block so re-runs never duplicate lines.
  sed -i '/# >>> k8s-lab >>>/,/# <<< k8s-lab <<</d' /etc/hosts
  {
    echo "# >>> k8s-lab >>>"
    printf '%b\n' "$HOSTS_ENTRIES"
    echo "# <<< k8s-lab <<<"
  } >> /etc/hosts
  ok "Cluster hosts block written"
  info "$(sed -n '/# >>> k8s-lab >>>/,/# <<< k8s-lab <<</p' /etc/hosts | sed '1d;$d' | sed 's/^/         /')"
else
  skip "No HOSTS_ENTRIES supplied"
fi

section "3/6  Disable swap"
if [ "$(swapon --show --noheadings | wc -l)" -gt 0 ]; then
  swapoff -a
  ok "Swap turned off for this boot"
else
  skip "Swap already off"
fi
# Comment out swap in fstab so it stays off across reboots.
if grep -qE '^[^#].*\sswap\s' /etc/fstab; then
  backup_file /etc/fstab
  sed -i -E 's|^([^#].*\sswap\s.*)$|# \1  # disabled by k8s-lab|' /etc/fstab
  ok "Swap entries commented out in /etc/fstab"
else
  skip "No active swap entries in /etc/fstab"
fi
# Ubuntu 24.04 ships systemd-zram-generator on some images; it re-adds swap.
if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-zram-setup@'; then
  systemctl mask 'systemd-zram-setup@zram0.service' >/dev/null 2>&1 || true
  info "Masked systemd-zram-setup@zram0 so zram swap cannot come back"
fi

section "4/6  Kernel modules"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
for mod in overlay br_netfilter; do
  if lsmod | grep -q "^${mod}\b"; then
    skip "Module ${mod} already loaded"
  else
    modprobe "$mod" && ok "Loaded ${mod}"
  fi
done

section "5/6  sysctl for the Kubernetes network model"
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
# Required by kube-proxy and every CNI: bridged traffic must traverse iptables
# so Service VIPs and NetworkPolicies are actually enforced.
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
# Pod-to-pod traffic is routed between nodes, so the kernel must forward.
net.ipv4.ip_forward                 = 1
# Busy clusters exhaust the default inotify limits (kubelet watches a lot).
fs.inotify.max_user_instances       = 512
fs.inotify.max_user_watches         = 524288
EOF
sysctl --system >/dev/null
ok "sysctl applied: $(sysctl -n net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables | tr '\n' ' ')"

section "6/6  Firewall"
# We open the specific ports Kubernetes needs rather than turning the firewall
# off. Disabling ufw is still available (FIREWALL_MODE=disable) because some
# lab setups need it, but it is no longer the default - a node with no firewall
# on a home LAN is a genuinely bad habit to teach.
FIREWALL_MODE="${FIREWALL_MODE:-open-ports}"
ROLE="${ROLE:-worker}"
CNI="${CNI:-calico}"

# https://kubernetes.io/docs/reference/networking/ports-and-protocols/
if [ "$ROLE" = "control-plane" ]; then
  K8S_PORTS=(
    "6443/tcp"        # kube-apiserver
    "2379:2380/tcp"   # etcd client and peer
    "10250/tcp"       # kubelet API
    "10257/tcp"       # kube-controller-manager
    "10259/tcp"       # kube-scheduler
  )
else
  K8S_PORTS=(
    "10250/tcp"         # kubelet API
    "10256/tcp"         # kube-proxy health
    "30000:32767/tcp"   # NodePort range
  )
fi

# Overlay/underlay ports differ per CNI and are easy to forget - a cluster
# where pods on different nodes cannot talk is nearly always this.
case "$CNI" in
  calico)  CNI_PORTS=("179/tcp" "4789/udp" "5473/tcp") ;;   # BGP, VXLAN, Typha
  flannel) CNI_PORTS=("8472/udp") ;;                        # VXLAN
  cilium)  CNI_PORTS=("8472/udp" "4240/tcp") ;;             # VXLAN, health
  *)       CNI_PORTS=() ;;
esac

if ! command -v ufw >/dev/null 2>&1; then
  skip "ufw is not installed - nothing to configure"
elif [ "$FIREWALL_MODE" = "leave" ]; then
  skip "FIREWALL_MODE=leave - not touching the firewall"
  info "Kubernetes needs: ${K8S_PORTS[*]} ${CNI_PORTS[*]:-}"
elif [ "$FIREWALL_MODE" = "disable" ]; then
  ufw disable >/dev/null 2>&1 || true
  warn "ufw DISABLED. This is a lab shortcut, not a configuration to copy."
else
  # Allow SSH first. Enabling ufw without it would lock the toolkit out of the
  # node it is currently configuring.
  ufw allow "${SSH_PORT_ON_NODE:-22}/tcp" >/dev/null 2>&1 || true
  for p in "${K8S_PORTS[@]}" ${CNI_PORTS[@]:+"${CNI_PORTS[@]}"}; do
    ufw allow "$p" >/dev/null 2>&1 || warn "could not open ${p}"
  done
  # Nodes must reach each other freely for pod and Service traffic; the pod
  # CIDR is not a fixed port range, so peers are trusted wholesale.
  if [ -n "${HOSTS_ENTRIES:-}" ]; then
    while read -r peer_ip _; do
      [ -n "$peer_ip" ] || continue
      ufw allow from "$peer_ip" >/dev/null 2>&1 || true
    done < <(printf '%b\n' "$HOSTS_ENTRIES")
    info "Cluster peers allowed unrestricted access to this node"
  fi
  ufw --force enable >/dev/null 2>&1 || true
  ok "Firewall active, ${#K8S_PORTS[@]} Kubernetes + ${#CNI_PORTS[@]} ${CNI} port rules"
  info "$(ufw status | head -12 | tail -n +2 | sed 's/^/         /')"
fi

echo
ok "Node prepared. Next: sudo ./03-install-containerd.sh"
