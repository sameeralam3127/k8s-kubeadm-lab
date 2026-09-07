#!/usr/bin/env bash
# =============================================================================
# 03-install-containerd.sh - install and configure the container runtime.
# Run on EVERY node. Idempotent.
#
#   sudo ./03-install-containerd.sh
#
# Why this script exists: the single most common kubeadm failure is a runtime
# whose cgroup driver disagrees with kubelet's. kubelet defaults to systemd,
# so containerd must be told to use SystemdCgroup = true. We also pin the
# sandbox (pause) image to the version kubeadm expects.
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
strict_mode
require_root

section "1/4  Install containerd"
if command -v containerd >/dev/null 2>&1; then
  skip "containerd already installed: $(containerd --version | awk '{print $3}')"
else
  export DEBIAN_FRONTEND=noninteractive
  retry 3 5 apt-get update -qq
  apt-get install -y -qq containerd
  ok "containerd installed: $(containerd --version | awk '{print $3}')"
fi

section "2/4  Generate containerd config"
mkdir -p /etc/containerd
if [ ! -s /etc/containerd/config.toml ] || ! grep -q 'SystemdCgroup' /etc/containerd/config.toml; then
  backup_file /etc/containerd/config.toml
  containerd config default > /etc/containerd/config.toml
  ok "Wrote a fresh /etc/containerd/config.toml"
else
  skip "Config already generated"
fi

section "3/4  Enable the systemd cgroup driver"
if grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  skip "SystemdCgroup already true"
else
  sed -i 's/^\(\s*\)SystemdCgroup = false/\1SystemdCgroup = true/' /etc/containerd/config.toml
  grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
    || die "Could not enable SystemdCgroup - inspect /etc/containerd/config.toml by hand"
  ok "SystemdCgroup = true"
fi

# Align the pause image with what kubeadm will ask for. A mismatch leaves pods
# stuck in ContainerCreating with a confusing 'sandbox' error.
if command -v kubeadm >/dev/null 2>&1; then
  PAUSE="$(kubeadm config images list 2>/dev/null | grep -m1 '/pause:' || true)"
  if [ -n "$PAUSE" ] && ! grep -q "sandbox_image = \"${PAUSE}\"" /etc/containerd/config.toml; then
    sed -i -E "s|sandbox_image = \".*\"|sandbox_image = \"${PAUSE}\"|" /etc/containerd/config.toml
    ok "sandbox_image pinned to ${PAUSE}"
  fi
fi

section "4/4  Start and verify"
systemctl daemon-reload
systemctl enable --now containerd >/dev/null
systemctl restart containerd
wait_for 60 "containerd socket" test -S /run/containerd/containerd.sock

# crictl is how you debug a node when kubectl can't help you. Point it at
# containerd now so it is ready when you need it at 2am.
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

systemctl is-active --quiet containerd \
  && ok "containerd is running" \
  || die "containerd failed to start: journalctl -u containerd -n 50"

echo
ok "Runtime ready. Next: sudo ./04-install-kube-tools.sh"
