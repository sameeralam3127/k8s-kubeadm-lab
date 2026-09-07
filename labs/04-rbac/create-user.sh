#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# create-user.sh - create a real Kubernetes "user" backed by a client cert.
# Run on the CONTROL PLANE as root.
#
#   sudo ./create-user.sh jane [group [group ...]]
#
# There is no User object in Kubernetes. A user is a client certificate that the
# cluster CA has signed, where:
#     CN (Common Name)   -> the username
#     O  (Organisation)  -> a group the user belongs to (repeatable)
# The API server reads those fields off the presented certificate and hands them
# to the authorisation layer. That is the entire authentication story.
# =============================================================================
set -Eeuo pipefail

USER_NAME="${1:-}"
shift || true
GROUPS_LIST=("$@")
[ -n "$USER_NAME" ] || { echo "Usage: sudo $0 <username> [group ...]"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }

export KUBECONFIG=/etc/kubernetes/admin.conf
WORK="/root/k8s-users/${USER_NAME}"
mkdir -p "$WORK"; cd "$WORK"

# Build the certificate subject: /CN=<user>/O=<group>/O=<group>...
SUBJ="/CN=${USER_NAME}"
for g in "${GROUPS_LIST[@]:-}"; do [ -n "$g" ] && SUBJ="${SUBJ}/O=${g}"; done

echo "==> 1/6  Generating a private key for ${USER_NAME}"
openssl genrsa -out "${USER_NAME}.key" 2048 2>/dev/null
echo "    ${WORK}/${USER_NAME}.key  (this never leaves the user's possession)"

echo "==> 2/6  Creating a certificate signing request  (subject: ${SUBJ})"
openssl req -new -key "${USER_NAME}.key" -out "${USER_NAME}.csr" -subj "$SUBJ"

echo "==> 3/6  Submitting it to the cluster as a CertificateSigningRequest"
# The cluster CA signs it - so no copying of ca.key around, and the CSR is
# auditable in the API. signerName kubernetes.io/kube-apiserver-client is the
# signer that issues client certs the API server will trust.
kubectl delete csr "${USER_NAME}" --ignore-not-found >/dev/null 2>&1
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}
spec:
  request: $(base64 -w0 < "${USER_NAME}.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000          # 1 year
  usages:
    - client auth
EOF

echo "==> 4/6  Approving the CSR"
# In a real cluster a human or a controller does this - it is the approval gate.
kubectl certificate approve "${USER_NAME}"
sleep 2

echo "==> 5/6  Extracting the signed certificate"
kubectl get csr "${USER_NAME}" -o jsonpath='{.status.certificate}' \
  | base64 -d > "${USER_NAME}.crt"
[ -s "${USER_NAME}.crt" ] || { echo "Certificate is empty - is the CSR approved?"; exit 1; }
openssl x509 -in "${USER_NAME}.crt" -noout -subject -dates

echo "==> 6/6  Building a kubeconfig"
KCFG="${WORK}/${USER_NAME}.kubeconfig"
CLUSTER_NAME="$(kubectl config view -o jsonpath='{.clusters[0].name}')"
SERVER="$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"

kubectl --kubeconfig="$KCFG" config set-cluster "$CLUSTER_NAME" \
  --server="$SERVER" \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true >/dev/null

kubectl --kubeconfig="$KCFG" config set-credentials "$USER_NAME" \
  --client-certificate="${WORK}/${USER_NAME}.crt" \
  --client-key="${WORK}/${USER_NAME}.key" \
  --embed-certs=true >/dev/null

kubectl --kubeconfig="$KCFG" config set-context "${USER_NAME}@${CLUSTER_NAME}" \
  --cluster="$CLUSTER_NAME" --user="$USER_NAME" --namespace=lab04 >/dev/null

kubectl --kubeconfig="$KCFG" config use-context "${USER_NAME}@${CLUSTER_NAME}" >/dev/null
chmod 600 "$KCFG"

cat <<EOF

  Done. kubeconfig: ${KCFG}

  The user exists and can AUTHENTICATE, but has NO permissions yet - RBAC is
  deny-by-default. Prove it:

      kubectl --kubeconfig=${KCFG} get pods
      # Error from server (Forbidden): pods is forbidden: User "${USER_NAME}" cannot list...

  Now grant something and try again:

      kubectl create rolebinding ${USER_NAME}-reader --role=pod-reader --user=${USER_NAME} -n lab04
      kubectl --kubeconfig=${KCFG} get pods -n lab04

  To hand this to a real person, copy ${KCFG} to their machine over a secure
  channel. It embeds their private key, so treat it as a credential.

  To revoke: there is no CRL here, so delete their RoleBindings. The certificate
  stays valid until it expires - which is exactly why short expirations matter.

EOF
