#!/usr/bin/env bash
# =============================================================================
# 02-prep-node.sh - OS-level preparation. Run on EVERY node (CP and workers).
# Idempotent: safe to re-run.
#
#   sudo ./02-prep-node.sh
#
# Env:
#   NODE_NAME=k8s-cp              # set the hostname (optional)
#   HOSTS_ENTRIES="ip name\nip name"  # lines appended to /etc/hosts (optional)
#   DISABLE_UFW=1                 # turn the firewall off (lab convenience)
# =============================================================================
strict_mode_src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$strict_mode_src"
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
if [ "${DISABLE_UFW:-0}" = "1" ] && command -v ufw >/dev/null 2>&1; then
  ufw disable >/dev/null 2>&1 || true
  ok "ufw disabled (lab convenience - do NOT do this in production)"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  warn "ufw is active. Either run with DISABLE_UFW=1 or open these ports:"
  info "control-plane: 6443/tcp 2379-2380/tcp 10250/tcp 10257/tcp 10259/tcp"
  info "workers:       10250/tcp 10256/tcp 30000-32767/tcp"
else
  skip "No active firewall to adjust"
fi

echo
ok "Node prepared. Next: sudo ./03-install-containerd.sh"
