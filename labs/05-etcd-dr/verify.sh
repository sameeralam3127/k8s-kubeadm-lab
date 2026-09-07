#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# Verify Lab 05 - etcd backup and disaster recovery.
# Run this ON THE CONTROL PLANE - it inspects local etcd files.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/verify.sh"

title "Lab 05 - etcd backup and disaster recovery"

if [ ! -f /etc/kubernetes/manifests/etcd.yaml ]; then
  echo
  echo "  This verifier must run on the CONTROL PLANE, where etcd lives."
  echo "  From your host:"
  echo "      ./lab run cp 'sudo bash -s' < labs/05-etcd-dr/verify.sh"
  echo
  exit 1
fi

echo "  Cluster health"
check "etcd static pod manifest is present" test -f /etc/kubernetes/manifests/etcd.yaml
check "etcd pod is Running" \
  bash -c "kubectl -n kube-system get pod -l component=etcd -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "API server answers /readyz" kubectl get --raw=/readyz

echo
echo "  Tooling"
check "etcdctl is installed" command -v etcdctl
check "etcdutl is installed (used for offline snapshot work)" command -v etcdutl

ETCD_ARGS=(--endpoints=https://127.0.0.1:2379
           --cacert=/etc/kubernetes/pki/etcd/ca.crt
           --cert=/etc/kubernetes/pki/etcd/server.crt
           --key=/etc/kubernetes/pki/etcd/server.key)
check "etcd reports itself healthy over mTLS" \
  bash -c "ETCDCTL_API=3 etcdctl ${ETCD_ARGS[*]} endpoint health"

echo
echo "  Backups"
BACKUP_DIR="${BACKUP_DIR:-/opt/etcd-backups}"
check "backup directory ${BACKUP_DIR} exists" test -d "$BACKUP_DIR"
check_ge "at least one snapshot has been taken" 1 \
  bash -c "ls -1 ${BACKUP_DIR}/*.db 2>/dev/null | wc -l"

NEWEST="$(ls -1t "${BACKUP_DIR}"/*.db 2>/dev/null | head -1 || true)"
if [ -n "$NEWEST" ]; then
  echo "  newest snapshot: $(basename "$NEWEST") ($(du -h "$NEWEST" | cut -f1))"
  check "newest snapshot is readable by etcdutl" \
    bash -c "etcdutl snapshot status '$NEWEST' >/dev/null 2>&1 || etcdctl snapshot status '$NEWEST' >/dev/null 2>&1"
  check "newest snapshot has a checksum file" test -f "${NEWEST}.sha256"
  if [ -f "${NEWEST}.sha256" ]; then
    check "checksum verifies (the snapshot is not corrupt)" \
      bash -c "cd '$(dirname "$NEWEST")' && sha256sum -c '$(basename "$NEWEST").sha256' >/dev/null"
  fi
  check "snapshot permissions are 0600 (it contains your secrets)" \
    bash -c "[ \"\$(stat -c '%a' '$NEWEST')\" = '600' ]"
  check "snapshot contains a meaningful number of keys" \
    bash -c "S=\$(etcdutl snapshot status '$NEWEST' --write-out=json 2>/dev/null || etcdctl snapshot status '$NEWEST' --write-out=json 2>/dev/null);
             echo \"\$S\" | grep -oE '\"totalKey\":[0-9]+' | grep -oE '[0-9]+' | awk '{exit !(\$1 > 100)}'"
else
  hint "no snapshot found - run ./lab backup, or Part 2 of the README"
fi

echo
echo "  Restore evidence"
if ls -d /var/lib/etcd-restored* >/dev/null 2>&1; then
  check "a restored data directory exists (you completed a restore)" \
    bash -c "ls -d /var/lib/etcd-restored* >/dev/null"
  check "the live etcd manifest points at the restored data dir" \
    bash -c "grep -q 'data-dir=/var/lib/etcd-restored' /etc/kubernetes/manifests/etcd.yaml"
  check "the hostPath volume was updated to match (the classic mistake)" \
    bash -c "grep -q 'path: /var/lib/etcd-restored' /etc/kubernetes/manifests/etcd.yaml"
else
  hint "no restore performed yet - run ./lab dr-drill, or Part 4 of the README"
fi

echo
echo "  Automation"
if crontab -l 2>/dev/null | grep -q 'etcd-backup'; then
  echo "  ${V_GREEN}note${V_RESET}  a cron entry for etcd backups exists - Part 6 done"
else
  hint "Part 6 optional: add a cron entry so backups happen without you"
fi

summary
