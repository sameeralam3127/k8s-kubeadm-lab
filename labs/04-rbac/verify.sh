#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# Verify Lab 04 - RBAC.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/verify.sh"
NS=lab04
K="kubectl -n ${NS}"
SA="system:serviceaccount:${NS}:pod-reader"
NV="system:serviceaccount:${NS}:node-viewer"

title "Lab 04 - RBAC"

check "namespace ${NS} exists" kubectl get ns "$NS"
check "namespace lab04-other exists" kubectl get ns lab04-other

echo
echo "  Namespace-scoped: ServiceAccount + Role + RoleBinding"
check "ServiceAccount 'pod-reader' exists" $K get sa pod-reader
check "Role 'pod-reader' exists" $K get role pod-reader
check "RoleBinding 'pod-reader-binding' exists" $K get rolebinding pod-reader-binding

check "pod-reader CAN list pods in ${NS}" \
  bash -c "kubectl auth can-i list pods --as=${SA} -n ${NS} | grep -q '^yes'"
check "pod-reader CAN get pod logs in ${NS}" \
  bash -c "kubectl auth can-i get pods/log --as=${SA} -n ${NS} | grep -q '^yes'"
check "pod-reader CANNOT delete pods (verb not granted)" \
  bash -c "kubectl auth can-i delete pods --as=${SA} -n ${NS} | grep -q '^no'"
check "pod-reader CANNOT read secrets (resource not granted)" \
  bash -c "kubectl auth can-i list secrets --as=${SA} -n ${NS} | grep -q '^no'"
check "pod-reader CANNOT list pods in lab04-other (Role is namespaced)" \
  bash -c "kubectl auth can-i list pods --as=${SA} -n lab04-other | grep -q '^no'"

echo
echo "  The permission boundary, from inside a pod"
if $K get pod rbac-tester >/dev/null 2>&1; then
  check "pod 'rbac-tester' uses the pod-reader ServiceAccount" \
    bash -c "$K get pod rbac-tester -o jsonpath='{.spec.serviceAccountName}' | grep -q '^pod-reader$'"
  check "rbac-tester CAN list pods with its projected token" \
    bash -c "$K exec rbac-tester -- kubectl get pods >/dev/null 2>&1"
  check "rbac-tester is Forbidden from reading secrets" \
    bash -c "! $K exec rbac-tester -- kubectl get secrets >/dev/null 2>&1"
else
  hint "pod 'rbac-tester' not found - apply manifests/sa-test-pod.yaml"
  FAILED=$((FAILED+1)); FAILURES+=("rbac-tester pod not created")
fi

echo
echo "  Cluster-scoped: ClusterRole + ClusterRoleBinding"
check "ServiceAccount 'node-viewer' exists" $K get sa node-viewer
check "ClusterRole 'node-viewer-cluster' exists" kubectl get clusterrole node-viewer-cluster
check "ClusterRole 'pod-reader-cluster' exists" kubectl get clusterrole pod-reader-cluster
check "ClusterRoleBinding 'node-viewer-binding' exists" kubectl get clusterrolebinding node-viewer-binding

check "node-viewer CAN list nodes (cluster-scoped resource)" \
  bash -c "kubectl auth can-i list nodes --as=${NV} | grep -q '^yes'"
check "node-viewer CANNOT delete nodes" \
  bash -c "kubectl auth can-i delete nodes --as=${NV} | grep -q '^no'"

echo
echo "  ClusterRole bound by RoleBinding (namespace-limited reuse)"
if kubectl -n lab04-other get rolebinding read-in-other >/dev/null 2>&1; then
  check "node-viewer CAN list pods in lab04-other via the RoleBinding" \
    bash -c "kubectl auth can-i list pods --as=${NV} -n lab04-other | grep -q '^yes'"
else
  hint "Task 3's final step not done: create the 'read-in-other' RoleBinding"
  FAILED=$((FAILED+1)); FAILURES+=("read-in-other RoleBinding not created")
fi

summary
