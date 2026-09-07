#!/usr/bin/env bash
# =============================================================================
# 12-join-worker.sh - join this machine to the cluster as a worker.
# Run ONLY on a worker node. Idempotent (detects an existing membership).
#
#   sudo JOIN_CMD="kubeadm join 192.168.1.101:6443 --token ... --discovery-token-ca-cert-hash sha256:..." \
#        ./12-join-worker.sh
#
# Env:
#   JOIN_CMD    the full command printed by kubeadm init (or `kubeadm token
#               create --print-join-command` on the control plane)
#   NODE_IP     this node's LAN IP, advertised to the API server (recommended
#               when the VM has more than one interface)
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
strict_mode
require_root

JOIN_CMD="${JOIN_CMD:-}"
NODE_IP="${NODE_IP:-$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')}"

if [ -f /etc/kubernetes/kubelet.conf ]; then
  warn "This node is already joined to a cluster (/etc/kubernetes/kubelet.conf exists)."
  confirm "Reset it and re-join?" || { info "Nothing to do."; exit 0; }
  kubeadm reset -f >/dev/null
  rm -rf /etc/cni/net.d
  ok "Node reset"
fi

if [ -z "$JOIN_CMD" ]; then
  err "No JOIN_CMD provided."
  info "On the control plane run:  sudo kubeadm token create --print-join-command"
  info "Then re-run:  sudo JOIN_CMD='kubeadm join ...' $0"
  exit 1
fi

# Strip a leading sudo if the user pasted the command verbatim.
JOIN_CMD="${JOIN_CMD#sudo }"
case "$JOIN_CMD" in
  kubeadm\ join*) : ;;
  *) die "JOIN_CMD does not look like a 'kubeadm join' command." ;;
esac

API_ENDPOINT="$(awk '{print $3}' <<<"$JOIN_CMD")"
API_HOST="${API_ENDPOINT%%:*}"
API_PORT="${API_ENDPOINT##*:}"

section "1/3  Reachability check"
info "API server endpoint: ${API_ENDPOINT}"
if command -v nc >/dev/null 2>&1; then
  nc -z -w 5 "$API_HOST" "$API_PORT" \
    || die "Cannot reach ${API_ENDPOINT}. Fix networking/firewall before joining."
else
  timeout 5 bash -c "cat < /dev/null > /dev/tcp/${API_HOST}/${API_PORT}" \
    || die "Cannot reach ${API_ENDPOINT}. Fix networking/firewall before joining."
fi
ok "Control plane is reachable"

section "2/3  Joining the cluster"
# --node-ip pins which address the kubelet advertises; without it a VM with a
# NAT adapter plus a bridged adapter often registers the wrong (unroutable) IP.
eval "$JOIN_CMD" \
  --cri-socket unix:///run/containerd/containerd.sock \
  --node-name "$(hostname)" 2>&1 | tee /root/kubeadm-join.log \
  || die "Join failed - see /root/kubeadm-join.log"

if [ -n "$NODE_IP" ]; then
  mkdir -p /etc/systemd/system/kubelet.service.d
  cat > /etc/systemd/system/kubelet.service.d/20-node-ip.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}"
EOF
  systemctl daemon-reload
  systemctl restart kubelet
  ok "kubelet advertising node-ip ${NODE_IP}"
fi

section "3/3  Local verification"
wait_for 120 "kubelet to become active" systemctl is-active --quiet kubelet
ok "kubelet is running"

echo
ok "Join complete. Verify from the control plane:"
info "  kubectl get nodes -o wide"
info "It can take a minute for this node to report Ready while the CNI pod starts."
