#!/usr/bin/env bash
# =============================================================================
# 31-etcd-restore.sh - restore the cluster from an etcd snapshot.
# Run ONLY on the control plane. DESTRUCTIVE: the cluster reverts to the
# snapshot's point in time and everything created since then disappears.
#
#   sudo ./31-etcd-restore.sh /opt/etcd-backups/etcd-snapshot-2026....db
#   sudo ASSUME_YES=1 ./31-etcd-restore.sh --latest
#
# Env:
#   RESTORE_DIR   new data dir for the restored state (default /var/lib/etcd-restored-<stamp>)
#   BACKUP_DIR    where --latest looks (default /opt/etcd-backups)
#
# How this works, in order:
#   1. etcdctl restores the snapshot into a BRAND NEW data directory.
#      (Never restore over a live /var/lib/etcd - etcd will refuse or corrupt.)
#   2. We move the static pod manifests out of /etc/kubernetes/manifests, which
#      makes the kubelet tear down etcd and the API server.
#   3. We repoint etcd.yaml (both --data-dir and its hostPath volume) at the
#      restored directory.
#   4. We move the manifests back; the kubelet recreates the control plane
#      against the restored data.
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
strict_mode
require_root

BACKUP_DIR="${BACKUP_DIR:-/opt/etcd-backups}"
STAMP="$(date -u +%Y%m%d%H%M%S)"
RESTORE_DIR="${RESTORE_DIR:-/var/lib/etcd-restored-${STAMP}}"
MANIFESTS=/etc/kubernetes/manifests
HOLDING=/etc/kubernetes/manifests-offline
SNAP="${1:-}"

[ -f "${MANIFESTS}/etcd.yaml" ] || [ -f "${HOLDING}/etcd.yaml" ] \
  || die "No etcd static pod manifest found. Run this on the control-plane node."

if [ "$SNAP" = "--latest" ] || [ -z "$SNAP" ]; then
  SNAP="$(ls -1t "${BACKUP_DIR}"/etcd-snapshot-*.db 2>/dev/null | head -1 || true)"
  [ -n "$SNAP" ] || die "No snapshot found in ${BACKUP_DIR}. Pass a path explicitly."
  info "Using the newest snapshot: ${SNAP}"
fi
[ -f "$SNAP" ] || die "Snapshot not found: ${SNAP}"

section "0/6  Pre-flight"
if [ -f "${SNAP}.sha256" ]; then
  (cd "$(dirname "$SNAP")" && sha256sum -c "$(basename "$SNAP").sha256" >/dev/null) \
    && ok "Checksum verified" || die "Checksum MISMATCH - this snapshot is corrupt."
else
  warn "No .sha256 alongside the snapshot - integrity unverified"
fi
command -v etcdctl >/dev/null 2>&1 || die "etcdctl missing - run 13-install-addons.sh"
if command -v etcdutl >/dev/null 2>&1; then
  etcdutl snapshot status "$SNAP" --write-out=table
else
  etcdctl snapshot status "$SNAP" --write-out=table
fi
[ -f "${SNAP}.meta" ] && { info "Snapshot metadata:"; sed 's/^/         /' "${SNAP}.meta"; }

echo
warn "This REPLACES all cluster state with the contents of that snapshot."
warn "Anything created after $(basename "$SNAP") will be gone."
confirm "Proceed with the restore?" || { info "Aborted. Nothing changed."; exit 0; }

section "1/6  Restore the snapshot into a fresh data directory"
[ -e "$RESTORE_DIR" ] && die "${RESTORE_DIR} already exists - pick another RESTORE_DIR."
if command -v etcdutl >/dev/null 2>&1; then
  etcdutl snapshot restore "$SNAP" --data-dir="$RESTORE_DIR"
else
  ETCDCTL_API=3 etcdctl snapshot restore "$SNAP" --data-dir="$RESTORE_DIR"
fi
chown -R root:root "$RESTORE_DIR"
ok "Restored to ${RESTORE_DIR}"

section "2/6  Stop the control plane (move static pod manifests aside)"
mkdir -p "$HOLDING"
shopt -s nullglob
for f in "${MANIFESTS}"/*.yaml; do mv "$f" "$HOLDING/"; done
shopt -u nullglob
ok "Manifests moved to ${HOLDING}"
info "The kubelet watches ${MANIFESTS}; with the files gone it stops etcd and the API server."

# Wait for the containers to actually die before touching the data directory.
info "Waiting for etcd and kube-apiserver containers to exit..."
for _ in $(seq 1 24); do
  RUNNING="$(crictl ps --name 'etcd|kube-apiserver' -q 2>/dev/null | wc -l | tr -d ' ')"
  [ "${RUNNING:-0}" -eq 0 ] && break
  sleep 5
done
ok "Control-plane containers stopped"

section "3/6  Preserve the old data directory"
OLD_DIR="$(awk -F= '/--data-dir/{print $2}' "${HOLDING}/etcd.yaml" | tr -d ' ')"
OLD_DIR="${OLD_DIR:-/var/lib/etcd}"
if [ -d "$OLD_DIR" ]; then
  mv "$OLD_DIR" "${OLD_DIR}.pre-restore-${STAMP}"
  ok "Old data kept at ${OLD_DIR}.pre-restore-${STAMP} (delete it once you trust the restore)"
fi

section "4/6  Point etcd at the restored data"
backup_file "${HOLDING}/etcd.yaml"
# Two places must change together, and forgetting the volume is the classic
# mistake: etcd then starts against an empty dir and the restore silently fails.
sed -i "s|--data-dir=${OLD_DIR}|--data-dir=${RESTORE_DIR}|" "${HOLDING}/etcd.yaml"
sed -i "s|path: ${OLD_DIR}$|path: ${RESTORE_DIR}|" "${HOLDING}/etcd.yaml"
ok "etcd.yaml now references ${RESTORE_DIR}"
grep -nE "data-dir|path: ${RESTORE_DIR}" "${HOLDING}/etcd.yaml" | sed 's/^/         /'

section "5/6  Restart the control plane"
shopt -s nullglob
for f in "${HOLDING}"/*.yaml; do mv "$f" "${MANIFESTS}/"; done
shopt -u nullglob
rmdir "$HOLDING" 2>/dev/null || true
systemctl restart kubelet
ok "Manifests restored; the kubelet is recreating the control plane"

section "6/6  Wait for the API server to come back"
export KUBECONFIG=/etc/kubernetes/admin.conf
if wait_for 300 "API server" kubectl get --raw='/readyz'; then
  echo
  kubectl get nodes
  echo
  kubectl get deploy -A | head -20
  echo
  ok "Restore complete - the cluster is back at the snapshot's point in time."
  info "Workers may take a minute to re-register. Then run ./20-verify-cluster.sh"
else
  err "API server did not come back. Investigate with:"
  info "  crictl ps -a | grep -E 'etcd|apiserver'"
  info "  crictl logs \$(crictl ps -a --name etcd -q | head -1)"
  info "  journalctl -u kubelet -n 100 --no-pager"
  info "Rollback: edit ${MANIFESTS}/etcd.yaml back to ${OLD_DIR} and"
  info "          mv ${OLD_DIR}.pre-restore-${STAMP} ${OLD_DIR}"
  exit 1
fi
