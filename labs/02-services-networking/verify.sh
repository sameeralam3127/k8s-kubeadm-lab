#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# Verify Lab 02 - services and networking.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/verify.sh"
NS=lab02
K="kubectl -n ${NS}"

title "Lab 02 - Services, DNS and NetworkPolicy"

check "namespace ${NS} exists" kubectl get ns "$NS"
check_ge "Deployment 'backend' has >= 3 ready replicas" 3 \
  $K get deploy backend -o jsonpath='{.status.readyReplicas}'

echo
echo "  Services"
check "ClusterIP service exists" $K get svc backend-clusterip
check_eq "ClusterIP service is type ClusterIP" "ClusterIP" \
  $K get svc backend-clusterip -o jsonpath='{.spec.type}'
check_ge "ClusterIP service has >= 3 endpoints" 3 \
  bash -c "$K get endpoints backend-clusterip -o jsonpath='{.subsets[*].addresses[*].ip}' | wc -w"

check "NodePort service exists" $K get svc backend-nodeport
check_eq "NodePort service is type NodePort" "NodePort" \
  $K get svc backend-nodeport -o jsonpath='{.spec.type}'
check_eq "NodePort is pinned to 30080" "30080" \
  $K get svc backend-nodeport -o jsonpath='{.spec.ports[0].nodePort}'

check "Headless service exists" $K get svc backend-headless
check_eq "Headless service has clusterIP None" "None" \
  $K get svc backend-headless -o jsonpath='{.spec.clusterIP}'

echo
echo "  Connectivity"
check "ClusterIP answers HTTP from inside the cluster" \
  bash -c "$K run verify-curl-\$RANDOM --rm -i --restart=Never --timeout=90s \
    --image=curlimages/curl:8.10.1 -- -sS -m 10 -o /dev/null -w '%{http_code}' \
    http://backend-clusterip 2>/dev/null | grep -q 200"

check "cluster DNS resolves the Service FQDN" \
  bash -c "$K run verify-dns-\$RANDOM --rm -i --restart=Never --timeout=90s \
    --image=busybox:1.36 -- nslookup backend-clusterip.${NS}.svc.cluster.local 2>/dev/null | grep -q Address"

check "NodePort is listening on a node" \
  bash -c "NODE_IP=\$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}');
           $K run verify-np-\$RANDOM --rm -i --restart=Never --timeout=90s \
    --image=curlimages/curl:8.10.1 -- -sS -m 10 -o /dev/null -w '%{http_code}' \
    http://\${NODE_IP}:30080 2>/dev/null | grep -q 200"

echo
echo "  NetworkPolicy (skipped automatically if your CNI does not enforce it)"
if kubectl get ds -A --no-headers 2>/dev/null | grep -qE 'calico-node|cilium'; then
  check "default-deny-ingress policy exists" $K get networkpolicy default-deny-ingress
  check "targeted allow policy exists" $K get networkpolicy allow-labelled-clients-to-backend
  check "labelled client CAN reach backend" \
    bash -c "$K exec deploy/allowed-client -- curl -sS -m 8 -o /dev/null http://backend-clusterip"
  check "unlabelled client CANNOT reach backend" \
    bash -c "! $K exec deploy/denied-client -- curl -sS -m 8 -o /dev/null http://backend-clusterip 2>/dev/null"
else
  hint "Flannel does not enforce NetworkPolicy - policy checks skipped."
  hint "Switch CNI=calico in lab.env and rebuild to practise this section."
fi

summary
