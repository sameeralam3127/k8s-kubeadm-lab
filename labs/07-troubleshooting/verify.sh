#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# Verify Lab 07 - troubleshooting. Passes when every scenario is repaired.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/verify.sh"
NS=tshoot
K="kubectl -n ${NS}"

title "Lab 07 - Troubleshooting"

if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  echo "  Namespace ${NS} does not exist - you have not run any scenarios yet."
  echo "  Start with:  ./break-it.sh list"
  echo
  exit 1
fi

echo "  Scenario repairs"
exists() { $K get "$1" "$2" >/dev/null 2>&1; }

if exists deploy pending-app; then
  check "1. pending-app is scheduled and running" \
    bash -c "[ \"\$($K get deploy pending-app -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
else hint "1. not attempted (./break-it.sh break 1)"; fi

if exists deploy badimage-app; then
  check "2. badimage-app pulls a real image" \
    bash -c "[ \"\$($K get deploy badimage-app -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
  check "2. no pod is in ImagePullBackOff" \
    bash -c "! $K get pods -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' | grep -q ImagePull"
else hint "2. not attempted (./break-it.sh break 2)"; fi

if exists deploy crashing-app; then
  check "3. crashing-app stays up" \
    bash -c "[ \"\$($K get deploy crashing-app -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
  check "3. no pod is in CrashLoopBackOff" \
    bash -c "! $K get pods -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' | grep -q CrashLoop"
else hint "3. not attempted (./break-it.sh break 3)"; fi

if exists svc broken-svc; then
  check "4. broken-svc selector now matches the pods" \
    bash -c "$K get svc broken-svc -o jsonpath='{.spec.selector.app}' | grep -qx 'tshoot-app'"
  check_ge "4. broken-svc has >= 1 endpoint" 1 \
    bash -c "$K get endpoints broken-svc -o jsonpath='{.subsets[*].addresses[*].ip}' | wc -w"
else hint "4. not attempted (./break-it.sh break 4)"; fi

if exists deploy config-app; then
  check "5. the missing ConfigMap key now exists" \
    bash -c "$K get configmap app-settings -o jsonpath='{.data.database\\.url}' | grep -q ."
  check "5. config-app starts successfully" \
    bash -c "[ \"\$($K get deploy config-app -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
else hint "5. not attempted (./break-it.sh break 5)"; fi

echo
echo "  Cluster-wide health (scenarios 6, 7 and 8)"
TOTAL="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
check_eq "6. all ${TOTAL} node(s) are Ready (kubelet running everywhere)" "$TOTAL" \
  bash -c "kubectl get nodes --no-headers | awk '\$2==\"Ready\"' | wc -l | tr -d ' '"

check_ge "7. CoreDNS has >= 1 ready replica" 1 \
  kubectl -n kube-system get deploy coredns -o jsonpath='{.status.readyReplicas}'
check "7. cluster DNS actually resolves" \
  bash -c "kubectl -n ${NS} run verify-dns-\$RANDOM --rm -i --restart=Never --timeout=90s \
    --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local 2>/dev/null | grep -q Address"

check "8. no leftover lab.example.com taint on any node" \
  bash -c "! kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' | grep -q 'lab.example.com'"

if exists deploy taint-victim; then
  check_ge "8. taint-victim has all 3 replicas running again" 3 \
    $K get deploy taint-victim -o jsonpath='{.status.readyReplicas}'
fi

echo
echo "  Overall"
check "no pod anywhere is unhealthy" \
  bash -c "! kubectl get pods -A --no-headers | grep -vE 'Running|Completed' | grep -q ."
check "API server passes /readyz" kubectl get --raw=/readyz

summary
