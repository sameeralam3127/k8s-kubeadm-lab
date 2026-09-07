#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# Verify Lab 01 - workloads.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/verify.sh"
NS=lab01
K="kubectl -n ${NS}"

title "Lab 01 - Workloads"

check "namespace ${NS} exists" kubectl get ns "$NS"

check "Deployment 'web' exists" $K get deploy web
check_ge "Deployment 'web' has >= 3 ready replicas" 3 \
  $K get deploy web -o jsonpath='{.status.readyReplicas}'

check "'web' pods define a readinessProbe" \
  bash -c "$K get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' | grep -q ."
check "'web' pods define a livenessProbe" \
  bash -c "$K get deploy web -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}' | grep -q ."

check "'web' containers declare resource requests" \
  bash -c "$K get deploy web -o jsonpath='{.spec.template.spec.containers[0].resources.requests}' | grep -q ."
check "'web' containers declare resource limits" \
  bash -c "$K get deploy web -o jsonpath='{.spec.template.spec.containers[0].resources.limits}' | grep -q ."

check "rollout history has more than one revision" \
  bash -c "[ \$($K rollout history deploy/web 2>/dev/null | grep -c '^[0-9]') -ge 2 ]"
check "current image is a real, pullable nginx tag" \
  bash -c "$K get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -qv 'does-not-exist'"
check "no pods are stuck in ImagePullBackOff" \
  bash -c "! $K get pods -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' | grep -q 'ImagePullBackOff'"

check "Service 'web-svc' exists" $K get svc web-svc
check_ge "Service 'web-svc' has >= 1 endpoint" 1 \
  bash -c "$K get endpoints web-svc -o jsonpath='{.subsets[*].addresses[*].ip}' | wc -w"

check "DaemonSet 'node-logger' exists" $K get ds node-logger
NODES="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
check_eq "DaemonSet runs on all ${NODES} node(s)" "$NODES" \
  $K get ds node-logger -o jsonpath='{.status.numberReady}'

check "CronJob 'pretend-backup' exists" $K get cronjob pretend-backup
check_ge "CronJob has produced at least one Job" 1 \
  bash -c "$K get jobs --no-headers 2>/dev/null | wc -l"

if $K get pods -o wide --no-headers 2>/dev/null | awk '{print $7}' | sort -u | wc -l | grep -qv '^1$'; then
  echo "  ${V_GREEN}note${V_RESET}  pods are spread across more than one node - the scheduler is working"
else
  hint "all pods are on one node; check that k8s-worker1 is Ready"
fi

summary
