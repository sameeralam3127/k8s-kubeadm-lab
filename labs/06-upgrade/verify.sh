#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# Verify Lab 06 - cluster upgrade.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/verify.sh"

title "Lab 06 - Cluster upgrade"

echo "  Version consistency"
SERVER="$(kubectl version -o json 2>/dev/null | grep -A5 serverVersion | grep gitVersion | cut -d'"' -f4)"
echo "  API server: ${SERVER:-unknown}"
kubectl get nodes -o custom-columns='NODE:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,STATUS:.status.conditions[-1].type' 2>/dev/null | sed 's/^/  /'
echo

check "API server version is known" bash -c "[ -n '${SERVER}' ]"

# Every kubelet should be on the same minor as the API server after a full
# upgrade. Skew is legal mid-upgrade but means the job is not finished.
SERVER_MINOR="$(echo "$SERVER" | sed -E 's/^v[0-9]+\.([0-9]+)\..*/\1/')"
SKEWED="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null |
          sed -E 's/^v[0-9]+\.([0-9]+)\..*/\1/' | grep -vc "^${SERVER_MINOR}$" || true)"
check_eq "every kubelet matches the API server minor version" "0" bash -c "echo ${SKEWED:-0}"

check "no kubelet is AHEAD of the API server (unsupported)" \
  bash -c "! kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{\"\n\"}{end}' |
           sed -E 's/^v[0-9]+\.([0-9]+)\..*/\1/' | awk -v s=${SERVER_MINOR} '\$1 > s {found=1} END {exit !found}'"

echo
echo "  Cluster health after the upgrade"
TOTAL="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
check_eq "all ${TOTAL} node(s) are Ready" "$TOTAL" \
  bash -c "kubectl get nodes --no-headers | awk '\$2==\"Ready\"' | wc -l | tr -d ' '"
check "no node is left cordoned (uncordon after draining)" \
  bash -c "! kubectl get nodes --no-headers | grep -q SchedulingDisabled"
check "no system pods are unhealthy" \
  bash -c "! kubectl get pods -n kube-system --no-headers | grep -vE 'Running|Completed' | grep -q ."
check "CoreDNS is available" \
  bash -c "[ \"\$(kubectl -n kube-system get deploy coredns -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
check "API server passes /readyz" kubectl get --raw=/readyz

echo
echo "  Discipline checks"
# These two need shell access to each node, so they are checked when this
# verifier runs ON a node, and reported as reminders otherwise.
if command -v apt-mark >/dev/null 2>&1; then
  check "kubelet, kubeadm and kubectl are held on this node" \
    bash -c "[ \"\$(apt-mark showhold | grep -cE '^(kubelet|kubeadm|kubectl)$')\" -eq 3 ]"
else
  hint "on each node, confirm: apt-mark showhold | grep -E 'kubelet|kubeadm|kubectl'"
fi
if [ -d /opt/etcd-backups ]; then
  check_ge "a pre-upgrade snapshot exists on this control plane" 1 \
    bash -c "ls -1 /opt/etcd-backups/*before-upgrade*.db 2>/dev/null | wc -l"
else
  hint "confirm you snapshotted before starting: ./lab backups"
fi

summary
