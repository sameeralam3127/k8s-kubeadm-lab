#!/usr/bin/env bash
# =============================================================================
# 30-etcd-backup.sh - take, verify and rotate an etcd snapshot.
# Run ONLY on the control plane. Safe to run any time; does not stop anything.
#
#   sudo ./30-etcd-backup.sh
#   sudo BACKUP_DIR=/opt/etcd-backups RETENTION=7 ./30-etcd-backup.sh
#
# Env:
#   BACKUP_DIR   where snapshots are written  (default /opt/etcd-backups)
#   RETENTION    how many snapshots to keep   (default 7, 0 = keep all)
#   LABEL        suffix added to the filename (e.g. before-upgrade)
#
# A snapshot is a point-in-time copy of ALL cluster state: every namespace,
# deployment, secret and RBAC rule. It does NOT include PersistentVolume data.
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
strict_mode
require_root

BACKUP_DIR="${BACKUP_DIR:-/opt/etcd-backups}"
RETENTION="${RETENTION:-7}"
LABEL="${LABEL:-}"
PKI=/etc/kubernetes/pki/etcd
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="etcd-snapshot-${STAMP}${LABEL:+-${LABEL}}.db"
SNAP="${BACKUP_DIR}/${NAME}"

[ -f /etc/kubernetes/manifests/etcd.yaml ] \
  || die "No etcd static pod on this host. Run this on the control-plane node."

section "1/5  Locate etcdctl"
if ! command -v etcdctl >/dev/null 2>&1; then
  warn "etcdctl not found - installing it via 13-install-addons.sh"
  WITH_METRICS=0 WITH_LOCALPATH=0 WITH_HELM=0 WITH_ETCDCTL=1 \
    "$(dirname "${BASH_SOURCE[0]}")/13-install-addons.sh"
fi
ok "$(etcdctl version | head -1)"

section "2/5  Read connection details from the live etcd manifest"
# Never hard-code these: a restored or customised cluster can move the certs
# or the listen address. The manifest is the source of truth.
ENDPOINT="$(awk -F= '/--listen-client-urls/{print $2}' /etc/kubernetes/manifests/etcd.yaml | cut -d, -f1 | tr -d ' ')"
ENDPOINT="${ENDPOINT:-https://127.0.0.1:2379}"
CACERT="$(awk -F= '/--trusted-ca-file/{print $2}' /etc/kubernetes/manifests/etcd.yaml | tr -d ' ')"
CERT="$(awk -F= '/--cert-file/{print $2}' /etc/kubernetes/manifests/etcd.yaml | tr -d ' ')"
KEY="$(awk -F= '/--key-file/{print $2}' /etc/kubernetes/manifests/etcd.yaml | tr -d ' ')"
CACERT="${CACERT:-$PKI/ca.crt}"; CERT="${CERT:-$PKI/server.crt}"; KEY="${KEY:-$PKI/server.key}"
# The advertised URL may be the node IP; 127.0.0.1 always works locally.
ENDPOINT="$(sed -E 's|https://[^:]+:|https://127.0.0.1:|' <<<"$ENDPOINT")"

for f in "$CACERT" "$CERT" "$KEY"; do [ -r "$f" ] || die "Cannot read $f"; done
info "endpoint : ${ENDPOINT}"
info "ca       : ${CACERT}"

export ETCDCTL_API=3
ETCD_OPTS=(--endpoints="$ENDPOINT" --cacert="$CACERT" --cert="$CERT" --key="$KEY")

section "3/5  Health check before snapshotting"
etcdctl "${ETCD_OPTS[@]}" endpoint health --write-out=table \
  || die "etcd is unhealthy - fix that before trusting a backup"
etcdctl "${ETCD_OPTS[@]}" endpoint status --write-out=table

section "4/5  Take the snapshot"
mkdir -p "$BACKUP_DIR"; chmod 0700 "$BACKUP_DIR"
etcdctl "${ETCD_OPTS[@]}" snapshot save "$SNAP" >/dev/null
chmod 0600 "$SNAP"
ok "Snapshot written: ${SNAP} ($(du -h "$SNAP" | cut -f1))"

# Verify the snapshot is readable and record its integrity hash. A backup you
# have not verified is a rumour, not a backup.
if command -v etcdutl >/dev/null 2>&1; then
  etcdutl snapshot status "$SNAP" --write-out=table
else
  etcdctl snapshot status "$SNAP" --write-out=table
fi
sha256sum "$SNAP" > "${SNAP}.sha256"
ok "Checksum: $(cut -d' ' -f1 < "${SNAP}.sha256")"

# A tiny manifest makes restores far less guesswork six months from now.
cat > "${SNAP}.meta" <<EOF
snapshot=${NAME}
taken_at=${STAMP}
node=$(hostname)
kubernetes=$(kubeadm version -o short 2>/dev/null || echo unknown)
etcd_data_dir=$(awk -F= '/--data-dir/{print $2}' /etc/kubernetes/manifests/etcd.yaml | tr -d ' ')
pod_cidr=$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl cluster-info dump 2>/dev/null | grep -m1 -- '--cluster-cidr' | sed 's/.*=//;s/",*//' || echo unknown)
sha256=$(cut -d' ' -f1 < "${SNAP}.sha256")
EOF
ok "Metadata: ${SNAP}.meta"

section "5/5  Rotate old snapshots"
if [ "$RETENTION" -gt 0 ]; then
  mapfile -t OLD < <(ls -1t "${BACKUP_DIR}"/etcd-snapshot-*.db 2>/dev/null | tail -n +$((RETENTION + 1)))
  if [ "${#OLD[@]}" -gt 0 ]; then
    for f in "${OLD[@]}"; do rm -f "$f" "$f.sha256" "$f.meta"; info "Pruned $(basename "$f")"; done
    ok "Kept the newest ${RETENTION} snapshot(s)"
  else
    skip "Nothing to prune ($(ls -1 "${BACKUP_DIR}"/etcd-snapshot-*.db 2>/dev/null | wc -l | tr -d ' ') kept)"
  fi
else
  skip "RETENTION=0 - keeping every snapshot"
fi

echo
ls -lh "${BACKUP_DIR}"/etcd-snapshot-*.db | sed 's/^/  /'
echo
ok "Backup complete."
warn "A backup on the same VM is not a backup. Copy it off the host:"
info "  ./lab backup            # from your Mac/Windows host, pulls it locally"
info "  scp ${SSH_USER:-ubuntu}@$(hostname -I | awk '{print $1}'):${SNAP} ."
