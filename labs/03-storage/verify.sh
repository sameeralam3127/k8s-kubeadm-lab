#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# Verify Lab 03 - storage.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/verify.sh"
NS=lab03
K="kubectl -n ${NS}"

title "Lab 03 - Storage"

check "namespace ${NS} exists" kubectl get ns "$NS"
check "a default StorageClass exists" \
  bash -c "kubectl get sc -o jsonpath='{.items[*].metadata.annotations}' | grep -q 'is-default-class\":\"true'"

echo
echo "  PersistentVolumeClaim"
check "PVC 'data-claim' exists" $K get pvc data-claim
check_eq "PVC 'data-claim' is Bound" "Bound" \
  $K get pvc data-claim -o jsonpath='{.status.phase}'
check "a PV was dynamically provisioned for it" \
  bash -c "$K get pvc data-claim -o jsonpath='{.spec.volumeName}' | grep -q ."
check "pod 'pvc-writer' is Running" \
  bash -c "$K get pod pvc-writer -o jsonpath='{.status.phase}' | grep -q Running"
check "data written to the PVC survived a pod delete" \
  bash -c "$K exec pvc-writer -- cat /data/proof.txt 2>/dev/null | grep -q 'survives pod deletion'"

echo
echo "  ConfigMap and Secret"
check "ConfigMap 'app-config' exists" $K get configmap app-config
check "Secret 'app-secret' exists" $K get secret app-secret
check "pod 'config-demo' is Running" \
  bash -c "$K get pod config-demo -o jsonpath='{.status.phase}' | grep -q Running"
check "ConfigMap is mounted as a file" \
  bash -c "$K exec config-demo -- test -f /etc/app/app.properties"
check "Secret is mounted as a file" \
  bash -c "$K exec config-demo -- test -f /etc/secret/password"
check "Secret is injected as an env var" \
  bash -c "$K exec config-demo -- printenv DB_PASSWORD | grep -q ."

echo
echo "  StatefulSet"
check "StatefulSet 'web-stateful' exists" $K get statefulset web-stateful
check_ge "StatefulSet has >= 2 ready replicas" 2 \
  $K get statefulset web-stateful -o jsonpath='{.status.readyReplicas}'
check "pods have ordinal names (web-stateful-0)" $K get pod web-stateful-0
check "headless Service 'web-stateful' exists" \
  bash -c "$K get svc web-stateful -o jsonpath='{.spec.clusterIP}' | grep -q None"
check_ge "one PVC per pod was created from the template" 2 \
  bash -c "$K get pvc -o name 2>/dev/null | grep -c 'www-web-stateful'"
check "pod 0 kept its own volume across a delete" \
  bash -c "$K exec web-stateful-0 -- cat /usr/share/nginx/html/id.txt 2>/dev/null | grep -q 'pod 0'"

summary
