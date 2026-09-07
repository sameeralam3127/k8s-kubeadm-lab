# Kubernetes Practical Lab: 2-Node Cluster (Mac + Windows) with etcd Backup

**Goal:** Build a real multi-node Kubernetes cluster using `kubeadm` — one control-plane node on a VM running on your Mac, one worker node on a VM running on your spare Windows machine — then practice `etcd` backup and restore.

---

## 0. Overall Architecture

```
[ macOS host ]                         [ Windows host ]
   VirtualBox/UTM VM                      VirtualBox VM
   Ubuntu 22.04 Server                    Ubuntu 22.04 Server
   role: control-plane                    role: worker
   hostname: k8s-cp                       hostname: k8s-worker1
   IP: 192.168.1.101 (example)            IP: 192.168.1.102 (example)
        |__________________ same LAN (bridged network) __________________|
```

Both VMs must be able to **ping each other** and reach the internet. The easiest way is to set both VM network adapters to **Bridged Networking** so they get IPs directly on your home/office LAN — this makes the Mac VM and Windows VM behave like two independent machines on the same network, regardless of which physical host they run on.

---

## 1. Install a Hypervisor

**On macOS:**

- Apple Silicon (M1/M2/M3): use **UTM** (free, https://mac.getutm.app) or **VMware Fusion** (free for personal use)
- Intel Mac: **VirtualBox** (https://www.virtualbox.org) works fine

**On Windows:**

- **VirtualBox** (https://www.virtualbox.org), or enable **Hyper-V** if you prefer (Pro/Enterprise editions only)

> Tip: Using VirtualBox on both sides keeps the steps identical for both machines.

---

## 2. Create the VMs

Create **two Ubuntu Server 22.04 LTS** VMs (download ISO from ubuntu.com):

| Setting  | Control Plane VM (on Mac) | Worker VM (on Windows) |
| -------- | ------------------------- | ---------------------- |
| Hostname | `k8s-cp`                  | `k8s-worker1`          |
| vCPUs    | 2 (min)                   | 2 (min)                |
| RAM      | 4 GB (min)                | 2 GB (min)             |
| Disk     | 20 GB+                    | 20 GB+                 |
| Network  | Bridged Adapter           | Bridged Adapter        |

During Ubuntu install, enable **OpenSSH server** so you can SSH into each VM from your Mac terminal instead of using the VM console.

After install, on **each VM**, set the hostname and get its IP:

```bash
sudo hostnamectl set-hostname k8s-cp        # on the control-plane VM
sudo hostnamectl set-hostname k8s-worker1   # on the worker VM
ip a                                        # note down the IP address
```

From your Mac, confirm they can see each other:

```bash
ssh ubuntu@<worker-ip>
```

Add both to `/etc/hosts` on **both** VMs (replace with your actual IPs):

```bash
sudo tee -a /etc/hosts <<EOF
192.168.1.101 k8s-cp
192.168.1.102 k8s-worker1
EOF
```

---

## 3. Prep Every Node (run on BOTH VMs)

### 3.1 Disable swap (kubelet requires this)

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

### 3.2 Load kernel modules & sysctl settings

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 3.3 Install containerd (container runtime)

```bash
sudo apt update && sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Enable systemd cgroup driver (required for kubelet)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### 3.4 Install kubeadm, kubelet, kubectl

```bash
sudo apt install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

(Adjust `v1.30` to whichever current stable minor version you want — check https://kubernetes.io/releases/ if unsure.)

---

## 4. Initialize the Control Plane (run ONLY on `k8s-cp`)

```bash
sudo kubeadm init \
  --apiserver-advertise-address=<k8s-cp-IP> \
  --pod-network-cidr=192.168.0.0/16
```

`--pod-network-cidr` is set to `192.168.0.0/16` because we'll install **Calico** as the CNI (adjust if you choose Flannel — use `10.244.0.0/16` instead).

When it finishes, it prints a `kubeadm join ...` command with a token — **copy this, you'll need it on the worker.** Tokens expire after 24h; regenerate later with `kubeadm token create --print-join-command` if needed.

Then, as a normal (non-root) user on `k8s-cp`:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Verify:

```bash
kubectl get nodes
# k8s-cp   NotReady   control-plane   ...   <- NotReady until CNI is installed
```

---

## 5. Install a Pod Network Add-on (CNI) — on `k8s-cp`

Using **Calico**:

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml
```

Wait a minute, then check:

```bash
kubectl get nodes
# k8s-cp   Ready   control-plane   ...
kubectl get pods -n calico-system
```

---

## 6. Join the Worker Node (run ONLY on `k8s-worker1`)

Use the exact command printed by `kubeadm init` earlier — it looks like:

```bash
sudo kubeadm join <k8s-cp-IP>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

If you lost it, regenerate from the control plane:

```bash
kubeadm token create --print-join-command
```

---

## 7. Verify the Cluster — back on `k8s-cp`

```bash
kubectl get nodes -o wide
```

Expected:

```
NAME          STATUS   ROLES           AGE   VERSION
k8s-cp        Ready    control-plane   10m   v1.30.x
k8s-worker1   Ready    <none>          2m    v1.30.x
```

Deploy a quick test workload:

```bash
kubectl create deployment nginx --image=nginx --replicas=2
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get pods -o wide     # confirm pods are scheduled onto k8s-worker1
kubectl get svc
```

---

## 8. etcd Backup

`etcd` is the cluster's key-value store — it holds **all** cluster state (nodes, pods, secrets, configs). Practicing backup/restore is a core CKA-style skill.

### 8.1 Locate etcd's certs (control plane only)

Static pod manifest is at `/etc/kubernetes/manifests/etcd.yaml`. Certs are typically here:

```
/etc/kubernetes/pki/etcd/ca.crt
/etc/kubernetes/pki/etcd/server.crt
/etc/kubernetes/pki/etcd/server.key
```

### 8.2 Install etcdctl (if not present)

```bash
ETCD_VER=v3.5.15
curl -L https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd.tar.gz
tar xzvf /tmp/etcd.tar.gz -C /tmp
sudo mv /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
etcdctl version
```

### 8.3 Take a snapshot

```bash
sudo ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

### 8.4 Verify the snapshot

```bash
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup.db --write-out=table
```

Copy this file off the VM (e.g., `scp` it to your Mac) so it's a real off-cluster backup:

```bash
scp ubuntu@<k8s-cp-IP>:/opt/etcd-backup.db ~/Desktop/
```

---

## 9. etcd Restore (practice disaster recovery)

**Simulate a disaster:** delete a namespace or deployment to see the "damage", then restore.

```bash
kubectl delete deployment nginx   # simulate accidental deletion
```

### 9.1 Stop the API server / etcd static pods

```bash
sudo mkdir -p /etc/kubernetes/manifests-backup
sudo mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests-backup/
# kubelet watches this dir — moving files out stops etcd, apiserver, etc.
```

### 9.2 Restore the snapshot into a new data directory

```bash
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd-restored
```

### 9.3 Point etcd's manifest at the restored data dir

Edit `/etc/kubernetes/manifests-backup/etcd.yaml` (before moving it back):

- Find the `--data-dir=` flag and the `hostPath` volume pointing to `/var/lib/etcd`
- Change both references to `/var/lib/etcd-restored`

### 9.4 Restart static pods

```bash
sudo mv /etc/kubernetes/manifests-backup/*.yaml /etc/kubernetes/manifests/
```

Kubelet will notice the manifests and recreate etcd, kube-apiserver, etc. Wait ~30–60s.

### 9.5 Verify recovery

```bash
kubectl get deployments
# nginx should be back, as of the snapshot's point in time
```

---

## 10. Suggested Order to Practice (checklist)

- [ ] VMs created, networked, pinging each other
- [ ] containerd + kubeadm/kubelet/kubectl installed on both
- [ ] `kubeadm init` on control plane
- [ ] CNI installed, control plane shows `Ready`
- [ ] `kubeadm join` on worker, worker shows `Ready`
- [ ] Test deployment scheduled and reachable
- [ ] etcd snapshot taken and copied off-VM
- [ ] Simulated failure + full etcd restore
- [ ] (Bonus) Repeat cluster build from scratch without notes, timing yourself — this is exactly the CKA exam format

---

## Notes & Common Gotchas

- **Bridged networking is the #1 failure point.** If the two VMs can't ping each other, nothing else will work — fix networking first.
- **Clock skew** between nodes breaks TLS certs; make sure both VMs have NTP/time sync on.
- If `kubeadm init` fails on preflight checks, re-run with `sudo kubeadm reset` first, then retry.
- Every node needs a **unique hostname and unique MAC address** — if you cloned a VM instead of installing fresh, regenerate the machine-id: `sudo rm /etc/machine-id /var/lib/dbus/machine-id && sudo systemd-machine-id-setup`.
- Kubernetes version, kubeadm version, and CNI version should all be checked against current compatibility matrices before you start, since Kubernetes moves fast — I used v1.30 above as an example.
