#!/usr/bin/env bash
# =============================================================================
# 99-diagnostics.sh - collect everything you would want when the lab misbehaves,
# into one tarball you can read offline or attach to a question.
# Read-only. Run on any node.
#
#   sudo ./99-diagnostics.sh
#   sudo OUT_DIR=/tmp ./99-diagnostics.sh
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
set -uo pipefail
require_root

OUT_DIR="${OUT_DIR:-/tmp}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
D="${OUT_DIR}/diagnostics-$(hostname)-${STAMP}"
mkdir -p "$D"/{system,runtime,kubelet,cluster}

cap() { # cap <file> <command...>
  local f="$1"; shift
  { echo "\$ $*"; echo; "$@" 2>&1; } > "$f" || true
}

section "Collecting host facts"
cap "$D/system/uname.txt"       uname -a
cap "$D/system/os-release.txt"  cat /etc/os-release
cap "$D/system/resources.txt"   bash -c 'echo "== cpu =="; nproc; echo; echo "== memory =="; free -h; echo; echo "== disk =="; df -h; echo; echo "== swap =="; swapon --show'
cap "$D/system/uptime.txt"      uptime
cap "$D/system/time.txt"        timedatectl
cap "$D/system/hosts.txt"       cat /etc/hosts
cap "$D/system/hostname.txt"    hostnamectl
cap "$D/system/sysctl.txt"      sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables
cap "$D/system/modules.txt"     lsmod
cap "$D/system/ip-addr.txt"     ip -d addr
cap "$D/system/ip-route.txt"    ip route
cap "$D/system/listening.txt"   ss -tulpn
cap "$D/system/iptables-nat.txt" iptables -t nat -S
cap "$D/system/firewall.txt"    bash -c 'ufw status verbose 2>/dev/null; iptables -L -n | head -50'
ok "Host facts collected"

section "Collecting container runtime state"
cap "$D/runtime/containerd-version.txt" containerd --version
cap "$D/runtime/containerd-status.txt"  systemctl status containerd --no-pager -l
cap "$D/runtime/containerd-journal.txt" journalctl -u containerd -n 500 --no-pager
cap "$D/runtime/cgroup-driver.txt"      grep -n 'SystemdCgroup\|sandbox_image' /etc/containerd/config.toml
cap "$D/runtime/crictl-ps.txt"          crictl ps -a
cap "$D/runtime/crictl-pods.txt"        crictl pods
cap "$D/runtime/crictl-images.txt"      crictl images
cap "$D/runtime/crictl-info.txt"        crictl info
ok "Runtime state collected"

section "Collecting kubelet state"
cap "$D/kubelet/status.txt"    systemctl status kubelet --no-pager -l
cap "$D/kubelet/journal.txt"   journalctl -u kubelet -n 1000 --no-pager
cap "$D/kubelet/config.txt"    cat /var/lib/kubelet/config.yaml
cap "$D/kubelet/flags.txt"     cat /var/lib/kubelet/kubeadm-flags.env
cap "$D/kubelet/dropins.txt"   bash -c 'ls -R /etc/systemd/system/kubelet.service.d/ 2>/dev/null && cat /etc/systemd/system/kubelet.service.d/* 2>/dev/null'
cap "$D/kubelet/manifests.txt" bash -c 'ls -l /etc/kubernetes/manifests/ 2>/dev/null'
for m in /etc/kubernetes/manifests/*.yaml; do
  [ -f "$m" ] && cp "$m" "$D/kubelet/$(basename "$m")"
done
ok "kubelet state collected"

section "Collecting cluster state"
export KUBECONFIG=/etc/kubernetes/admin.conf
if [ -f "$KUBECONFIG" ] && kubectl version -o json >/dev/null 2>&1; then
  cap "$D/cluster/version.txt"      kubectl version -o yaml
  cap "$D/cluster/nodes.txt"        kubectl get nodes -o wide
  cap "$D/cluster/nodes-describe.txt" kubectl describe nodes
  cap "$D/cluster/pods-all.txt"     kubectl get pods -A -o wide
  cap "$D/cluster/pods-unhealthy.txt" bash -c "kubectl get pods -A --no-headers | grep -vE 'Running|Completed'"
  cap "$D/cluster/events.txt"       kubectl get events -A --sort-by=.lastTimestamp
  cap "$D/cluster/svc.txt"          kubectl get svc -A
  cap "$D/cluster/endpoints.txt"    kubectl get endpoints -A
  cap "$D/cluster/deploy.txt"       kubectl get deploy,ds,sts -A
  cap "$D/cluster/pv-pvc.txt"       kubectl get pv,pvc -A
  cap "$D/cluster/readyz.txt"       kubectl get --raw=/readyz?verbose
  cap "$D/cluster/coredns-logs.txt" kubectl -n kube-system logs -l k8s-app=kube-dns --tail=300
  # Logs from every non-Running pod: usually where the real answer is.
  kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed' | \
  while read -r ns name _; do
    cap "$D/cluster/logs-${ns}-${name}.txt" kubectl -n "$ns" logs "$name" --all-containers --tail=200 --previous
    cap "$D/cluster/describe-${ns}-${name}.txt" kubectl -n "$ns" describe pod "$name"
  done
  ok "Cluster state collected"
else
  echo "No usable kubeconfig on this node (normal for a worker)." > "$D/cluster/NOTE.txt"
  skip "No API access from this node - collected host-level data only"
fi

section "Packaging"
TAR="${D}.tar.gz"
tar czf "$TAR" -C "$(dirname "$D")" "$(basename "$D")"
rm -rf "$D"
chmod 0640 "$TAR"
ok "Diagnostics bundle: ${TAR} ($(du -h "$TAR" | cut -f1))"
echo
info "Pull it to your host with:"
info "  ./lab diagnostics        # collects from every node automatically"
info "Quick first look inside:"
info "  tar xzf ${TAR} && less */kubelet/journal.txt"
