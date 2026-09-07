#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# 20-verify-cluster.sh - end-to-end health check. Run on the control plane.
# Read-only apart from a temporary namespace it creates and deletes.
#
#   sudo ./20-verify-cluster.sh          # full check incl. a live smoke test
#   sudo SMOKE=0 ./20-verify-cluster.sh  # skip the workload smoke test
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NS="lab-verify"
FAILURES=0
mark() { printf '  %-46s' "$1"; }
pass() { printf '%s PASS %s%s\n' "$C_GREEN" "$C_RESET" "${1:-}"; }
bad()  { printf '%s FAIL %s%s\n' "$C_RED" "$C_RESET" "${1:-}"; FAILURES=$((FAILURES+1)); }
meh()  { printf '%s WARN %s%s\n' "$C_YELLOW" "$C_RESET" "${1:-}"; }

section "Control plane"
mark "API server reachable"
if kubectl version -o json >/dev/null 2>&1; then pass "$(kubectl version -o json 2>/dev/null | grep -m1 gitVersion | cut -d'"' -f4)"
else bad "kubectl cannot reach the API server"; exit 1; fi

mark "Static control-plane pods Running"
CP_BAD="$(kubectl -n kube-system get pods -l tier=control-plane --no-headers 2>/dev/null | grep -vc Running || true)"
[ "${CP_BAD:-0}" -eq 0 ] && pass || bad "${CP_BAD} not Running"

mark "Component health (etcd, scheduler, controller)"
if kubectl get --raw='/readyz?verbose' 2>/dev/null | grep -q 'readyz check passed'; then pass
else meh "some readyz checks failing - see: kubectl get --raw='/readyz?verbose'"; fi

section "Nodes"
kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /'
echo
TOTAL="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
READY="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
mark "All nodes Ready"
[ "$TOTAL" -gt 0 ] && [ "$READY" -eq "$TOTAL" ] && pass "${READY}/${TOTAL}" || bad "${READY}/${TOTAL} Ready"

mark "At least one worker joined"
WORKERS="$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' 2>/dev/null | wc -l | tr -d ' ')"
[ "$WORKERS" -ge 1 ] && pass "${WORKERS} worker(s)" || meh "no workers - single-node lab"

section "Cluster networking"
mark "CNI DaemonSet fully rolled out"
CNI_DS="$(kubectl get ds -A --no-headers 2>/dev/null | grep -E 'calico-node|kube-flannel|cilium' | head -1)"
if [ -n "$CNI_DS" ]; then
  DESIRED="$(awk '{print $3}' <<<"$CNI_DS")"; AVAIL="$(awk '{print $6}' <<<"$CNI_DS")"
  [ "$DESIRED" = "$AVAIL" ] && pass "$(awk '{print $2}' <<<"$CNI_DS") ${AVAIL}/${DESIRED}" \
    || bad "$(awk '{print $2}' <<<"$CNI_DS") only ${AVAIL}/${DESIRED} ready"
else bad "no CNI DaemonSet found - pods will never get an IP"; fi

mark "CoreDNS available"
DNS_READY="$(kubectl -n kube-system get deploy coredns -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${DNS_READY:-0}" -ge 1 ] && pass "${DNS_READY} replica(s)" || bad "CoreDNS has no ready replicas"

mark "kube-proxy on every node"
KP="$(kubectl -n kube-system get ds kube-proxy --no-headers 2>/dev/null | awk '{print $6"/"$3}')"
[ -n "$KP" ] && pass "$KP" || meh "kube-proxy DaemonSet not found (cilium kube-proxy replacement?)"

section "System workloads"
NOTOK="$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed' || true)"
if [ -z "$NOTOK" ]; then ok "Every pod in every namespace is Running or Completed"
else warn "Pods needing attention:"; sed 's/^/    /' <<<"$NOTOK"; FAILURES=$((FAILURES+1)); fi

if [ "${SMOKE:-1}" = "1" ]; then
  section "Live smoke test (deploy -> schedule -> DNS -> Service)"
  kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl create ns "$NS" >/dev/null

  kubectl -n "$NS" create deployment web --image=nginx:stable-alpine --replicas=2 >/dev/null
  kubectl -n "$NS" expose deployment web --port=80 >/dev/null

  mark "Deployment becomes available"
  if kubectl -n "$NS" rollout status deploy/web --timeout=180s >/dev/null 2>&1; then pass
  else bad "rollout stalled - kubectl -n ${NS} describe pods"; fi

  mark "Pods received routable IPs"
  IPS="$(kubectl -n "$NS" get pods -o jsonpath='{.items[*].status.podIP}' 2>/dev/null)"
  [ -n "$IPS" ] && pass "$IPS" || bad "no pod IPs - CNI problem"

  mark "Pods spread across nodes"
  NODES_USED="$(kubectl -n "$NS" get pods -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  pass "${NODES_USED}"

  mark "Cluster DNS resolves the Service"
  if kubectl -n "$NS" run dnstest --rm -i --restart=Never --timeout=120s \
       --image=busybox:1.36 -- nslookup web."$NS".svc.cluster.local 2>/dev/null | grep -q 'Address'; then
    pass
  else bad "DNS lookup failed - check CoreDNS and the CNI"; fi

  mark "Service endpoint answers HTTP"
  if kubectl -n "$NS" run curltest --rm -i --restart=Never --timeout=120s \
       --image=curlimages/curl:8.10.1 -- -sS -o /dev/null -w '%{http_code}' \
       "http://web.${NS}.svc.cluster.local" 2>/dev/null | grep -q 200; then
    pass "HTTP 200"
  else bad "Service unreachable from inside the cluster"; fi

  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
  info "Cleaning up namespace ${NS} in the background"
fi

section "Result"
if [ "$FAILURES" -eq 0 ]; then
  ok "Cluster is healthy. Go run the labs in ./labs/."
  exit 0
fi
err "${FAILURES} check(s) failed. Run ./99-diagnostics.sh to collect evidence."
exit 1
