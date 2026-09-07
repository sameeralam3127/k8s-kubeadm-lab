#!/usr/bin/env bash
# =============================================================================
# 13-install-addons.sh - optional quality-of-life add-ons for the lab.
# Run ONLY on the control plane. Idempotent. Everything here is opt-out.
#
#   sudo ./13-install-addons.sh
#
# Env (set any to 0 to skip):
#   WITH_METRICS=1        metrics-server, so `kubectl top` works
#   WITH_LOCALPATH=1      local-path-provisioner + default StorageClass
#   WITH_HELM=1           helm CLI
#   WITH_ETCDCTL=1        etcdctl + etcdutl binaries for the backup labs
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
strict_mode
require_root
export KUBECONFIG=/etc/kubernetes/admin.conf

METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.7.2}"
ETCDCTL_VERSION="${ETCDCTL_VERSION:-v3.5.16}"
LOCALPATH_VERSION="${LOCALPATH_VERSION:-v0.0.30}"
ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && ARCH=amd64 || ARCH=arm64

if [ "${WITH_METRICS:-1}" = "1" ]; then
  section "metrics-server"
  if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
    skip "already installed"
  else
    kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
    # Lab clusters use self-signed kubelet certs, which metrics-server rejects
    # by default. This flag is the standard lab workaround - not for production.
    kubectl -n kube-system patch deploy metrics-server --type=json -p \
      '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    wait_for 180 "metrics-server" kubectl -n kube-system rollout status deploy/metrics-server --timeout=10s
    ok "metrics-server ready - try: kubectl top nodes"
  fi
fi

if [ "${WITH_LOCALPATH:-1}" = "1" ]; then
  section "local-path-provisioner (dynamic PVs)"
  if kubectl get sc local-path >/dev/null 2>&1; then
    skip "StorageClass local-path already exists"
  else
    kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCALPATH_VERSION}/deploy/local-path-storage.yaml"
    wait_for 180 "local-path-provisioner" \
      kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=10s
    kubectl patch storageclass local-path -p \
      '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    ok "local-path is now the default StorageClass"
  fi
fi

if [ "${WITH_HELM:-1}" = "1" ]; then
  section "helm"
  if command -v helm >/dev/null 2>&1; then
    skip "already installed: $(helm version --short)"
  else
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    ok "$(helm version --short)"
  fi
fi

if [ "${WITH_ETCDCTL:-1}" = "1" ]; then
  section "etcdctl / etcdutl"
  if command -v etcdctl >/dev/null 2>&1 && etcdctl version 2>/dev/null | grep -q "${ETCDCTL_VERSION#v}"; then
    skip "etcdctl ${ETCDCTL_VERSION} already installed"
  else
    TMP="$(mktemp -d)"
    TARBALL="etcd-${ETCDCTL_VERSION}-linux-${ARCH}.tar.gz"
    retry 3 5 curl -fsSL \
      "https://github.com/etcd-io/etcd/releases/download/${ETCDCTL_VERSION}/${TARBALL}" \
      -o "${TMP}/etcd.tar.gz"
    tar xzf "${TMP}/etcd.tar.gz" -C "$TMP" --strip-components=1
    install -m 0755 "${TMP}/etcdctl" /usr/local/bin/etcdctl
    [ -f "${TMP}/etcdutl" ] && install -m 0755 "${TMP}/etcdutl" /usr/local/bin/etcdutl
    rm -rf "$TMP"
    ok "$(etcdctl version | head -1)"
  fi
fi

echo
ok "Add-ons done."
kubectl get sc 2>/dev/null || true
