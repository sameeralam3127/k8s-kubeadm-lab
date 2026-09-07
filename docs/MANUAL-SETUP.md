# Manual setup — what the scripts do, by hand

The toolkit automates all of this. Do it by hand **once** anyway: on the CKA
exam and on a broken production cluster, nobody hands you a script. Every
command below has a matching script in `scripts/node/` — the comment above each
section names it.

Run everything as root (`sudo -i`) unless noted.

---

## 0. The target

```
[ macOS host ]                         [ Windows host ]
   UTM / VirtualBox VM                    VirtualBox VM
   Ubuntu Server 22.04/24.04              Ubuntu Server 22.04/24.04
   role: control-plane                    role: worker
   hostname: k8s-cp                       hostname: k8s-worker1
   IP: 192.168.1.101 (example)            IP: 192.168.1.102 (example)
        |__________________ same LAN (bridged) __________________|
```

Both VMs must ping each other and reach the internet. **Bridged networking is
non-negotiable** — it is what makes the two VMs peers on your LAN regardless of
which physical machine hosts them.

---

## 1. Hypervisor

| Host | Use |
|---|---|
| Apple Silicon Mac | **UTM** (`brew install --cask utm`) or VMware Fusion |
| Intel Mac | VirtualBox |
| Windows | VirtualBox, or Hyper-V with an **External** virtual switch |
| Linux | VirtualBox, or libvirt/KVM with a bridge |

Automated by: `scripts/host/new-lab-vm.sh` (macOS/Linux),
`windows/New-LabVM.ps1` (Windows).

---

## 2. Create the VMs

| Setting | Control plane | Worker |
|---|---|---|
| Hostname | `k8s-cp` | `k8s-worker1` |
| vCPUs | 2 (minimum — kubeadm refuses fewer) | 2 |
| RAM | 4 GB (2 GB absolute minimum) | 2 GB |
| Disk | 25 GB+ | 25 GB+ |
| Network | **Bridged** | **Bridged** |

During the Ubuntu install, **tick "Install OpenSSH server"**.

Afterwards, on each VM:

```bash
sudo hostnamectl set-hostname k8s-cp        # or k8s-worker1
ip -4 addr                                  # note the IP
```

Add both nodes to `/etc/hosts` on **both** machines:

```bash
sudo tee -a /etc/hosts <<'EOF'
192.168.1.101 k8s-cp
192.168.1.102 k8s-worker1
EOF
```

Confirm they can reach each other before going further:

```bash
ping -c3 k8s-worker1        # from k8s-cp
ping -c3 k8s-cp             # from k8s-worker1
```

---

## 3. Prepare every node

> Script: `scripts/node/02-prep-node.sh`

### 3.1 Disable swap

The kubelet refuses to start with swap enabled — memory accounting and eviction
depend on it being off.

```bash
swapoff -a
sed -i -E 's|^([^#].*\sswap\s.*)$|# \1|' /etc/fstab

# Ubuntu 24.04 images sometimes re-enable zram swap on boot:
systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
```

### 3.2 Kernel modules

```bash
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter
```

`overlay` backs the container filesystem; `br_netfilter` is what lets bridged
traffic reach iptables.

### 3.3 sysctl

```bash
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system
```

Without `bridge-nf-call-iptables`, Service VIPs and NetworkPolicies silently do
nothing. Without `ip_forward`, pod traffic cannot cross between nodes.

---

## 4. Container runtime

> Script: `scripts/node/03-install-containerd.sh`

```bash
apt-get update && apt-get install -y containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# THE most common kubeadm failure: kubelet defaults to the systemd cgroup
# driver, so containerd must agree. A mismatch produces pods that never start
# and a kubelet that logs cgroup errors.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
```

Point `crictl` at containerd now, so it works when you need it later:

```bash
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
```

---

## 5. kubeadm, kubelet, kubectl

> Script: `scripts/node/04-install-kube-tools.sh`

```bash
K8S_MINOR=v1.31

apt-get install -y apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl

# Hold them: an unattended apt upgrade that bumps a minor version mid-life will
# break the cluster.
apt-mark hold kubelet kubeadm kubectl
```

> `pkgs.k8s.io` publishes a **separate repo per minor version**. Upgrading to a
> new minor means editing that URL — which is exactly what Lab 06 does.

The kubelet will crash-loop until `kubeadm init` or `kubeadm join` writes its
config. That is expected; do not chase it.

---

## 6. Initialise the control plane

> Script: `scripts/node/10-init-control-plane.sh` — run on `k8s-cp` only

```bash
kubeadm config images pull        # makes init fast and predictable

kubeadm init \
  --apiserver-advertise-address=192.168.1.101 \
  --pod-network-cidr=192.168.0.0/16 \
  --upload-certs
```

`--pod-network-cidr` must match your CNI: Calico `192.168.0.0/16`, Flannel
`10.244.0.0/16`.

**Save the `kubeadm join ...` line it prints.** Tokens expire after 24 hours;
regenerate with `kubeadm token create --print-join-command`.

Set up kubectl for your normal user:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl get nodes      # NotReady - expected until a CNI is installed
```

---

## 7. Install a CNI

> Script: `scripts/node/11-install-cni.sh` — run on `k8s-cp` only

**Calico** (enforces NetworkPolicy — recommended):

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml

kubectl create -f - <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        cidr: 192.168.0.0/16
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
EOF
```

**Flannel** (simpler, but does *not* enforce NetworkPolicy):

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.25.6/kube-flannel.yml
```

Then wait and confirm:

```bash
kubectl get nodes           # Ready
kubectl get pods -A         # CoreDNS Running
```

---

## 8. Join the worker

> Script: `scripts/node/12-join-worker.sh` — run on `k8s-worker1` only

```bash
kubeadm join 192.168.1.101:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --cri-socket unix:///run/containerd/containerd.sock
```

If the VM has more than one network interface, pin which IP the kubelet
advertises — otherwise it may register an unroutable NAT address:

```bash
mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/20-node-ip.conf <<'EOF'
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=192.168.1.102"
EOF
systemctl daemon-reload && systemctl restart kubelet
```

---

## 9. Verify

> Script: `scripts/node/20-verify-cluster.sh`

```bash
kubectl get nodes -o wide

kubectl create deployment nginx --image=nginx --replicas=2
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get pods -o wide          # confirm pods land on the worker
kubectl get svc

# From your host:
curl http://192.168.1.101:<nodeport>
curl http://192.168.1.102:<nodeport>      # same Service, either node
```

---

## 10. etcd backup and restore

> Scripts: `scripts/node/30-etcd-backup.sh`, `scripts/node/31-etcd-restore.sh`
> Full walkthrough with explanations: [Lab 05](../labs/05-etcd-dr/README.md)

Install `etcdctl`:

```bash
ETCD_VER=v3.5.16
curl -L "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz" \
  -o /tmp/etcd.tar.gz
tar xzf /tmp/etcd.tar.gz -C /tmp --strip-components=1
install -m 0755 /tmp/etcdctl /tmp/etcdutl /usr/local/bin/
```

Snapshot:

```bash
ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

etcdutl snapshot status /opt/etcd-backup.db --write-out=table
sha256sum /opt/etcd-backup.db
```

Copy it off the VM — a backup on the machine you are protecting is not a backup:

```bash
scp ubuntu@192.168.1.101:/opt/etcd-backup.db ~/Desktop/
```

Restore, in this exact order:

```bash
# 1. Restore into a NEW data directory (never over a live one)
etcdutl snapshot restore /opt/etcd-backup.db --data-dir=/var/lib/etcd-restored

# 2. Stop the control plane by moving the static pod manifests away
mkdir -p /etc/kubernetes/manifests-offline
mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests-offline/
crictl ps | grep -E 'etcd|apiserver'      # wait until empty

# 3. Preserve the old data as a rollback
mv /var/lib/etcd /var/lib/etcd.old

# 4. Edit etcd.yaml - BOTH the --data-dir flag AND the hostPath volume
vi /etc/kubernetes/manifests-offline/etcd.yaml

# 5. Put the manifests back; the kubelet rebuilds the control plane
mv /etc/kubernetes/manifests-offline/*.yaml /etc/kubernetes/manifests/
systemctl restart kubelet

# 6. Verify (allow 60-90 seconds)
kubectl get nodes
kubectl get deployments -A
```

**Step 4 is where people fail.** Changing only the `--data-dir` flag and leaving
the `hostPath` volume pointing at `/var/lib/etcd` gives you a cluster that comes
up looking healthy — and completely empty.

---

## Common gotchas

- **Bridged networking is the #1 failure.** If the VMs cannot ping each other,
  nothing else will work. Fix that first.
- **Clock skew breaks TLS.** Make sure NTP is on: `timedatectl`.
- **Cloned VMs collide.** Unique hostname, machine-id and MAC per node:
  `rm /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup`.
- **Failed `kubeadm init`?** `kubeadm reset -f` before retrying, always.
- **Version compatibility.** Check the kubeadm/kubelet/CNI matrices before
  choosing versions — Kubernetes moves fast.
