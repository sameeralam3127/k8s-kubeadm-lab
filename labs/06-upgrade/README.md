# Lab 06 — Upgrading the cluster

**Time:** ~45 minutes  **Prerequisites:** a healthy 2-node cluster, and a **fresh
etcd snapshot** (`./lab backup before-upgrade`)

Upgrades are where clusters break. The order is rigid and unforgiving: control
plane first, one minor version at a time, workers after, drain before touching a
node. Practise here so you never improvise it in production.

---

## The rules that matter

1. **One minor version at a time.** 1.31 → 1.32 is supported. 1.31 → 1.33 is not.
   To go two versions you upgrade twice.
2. **Control plane first, then workers.** A kubelet may be **up to two minor
   versions behind** the API server, never ahead.
3. **`kubeadm` upgrades before everything else** on each node — it is the tool
   doing the work, so it must know the target version.
4. **`kubeadm upgrade apply`** on the first control plane; **`kubeadm upgrade
   node`** everywhere else.
5. **Drain before, uncordon after.** Always.
6. **Snapshot etcd first.** `kubeadm upgrade` backs up manifests, not your data.

---

## Step 0 — Snapshot, and record where you are

```bash
./lab backup before-upgrade
./lab kubectl get nodes -o wide
./lab kubectl version -o yaml | grep -A2 serverVersion
```

Write down the current version. If the upgrade goes wrong, `./lab restore` plus
that number is your way back.

---

## Step 1 — Find the target version

On the control plane:

```bash
./lab ssh cp
sudo -i

# The repo is per-minor, so bump it BEFORE looking for the new version.
CURRENT_MINOR=v1.31
NEXT_MINOR=v1.32

sed -i "s|${CURRENT_MINOR}|${NEXT_MINOR}|g" /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/${NEXT_MINOR}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
apt-get update

apt-cache madison kubeadm | head -5
```

Pick the exact package version from that output, e.g. `1.32.1-1.1`.

> Check <https://kubernetes.io/releases/> for what is current before choosing.

---

## Step 2 — Upgrade `kubeadm` on the control plane

```bash
TARGET=1.32.1-1.1

apt-mark unhold kubeadm
apt-get install -y kubeadm=${TARGET}
apt-mark hold kubeadm
kubeadm version -o short
```

---

## Step 3 — Plan, then apply

```bash
kubeadm upgrade plan
```

Read the output properly. It tells you what will change, whether your component
versions are compatible, and whether any manual steps are needed.

```bash
kubeadm upgrade apply v1.32.1
```

This takes a few minutes. Behind the scenes it renews certificates, rewrites the
static pod manifests one component at a time, waits for each to come back
healthy, and updates the cluster config in the `kubeadm-config` ConfigMap. Watch
from another terminal:

```bash
./lab kubectl -n kube-system get pods -w
```

---

## Step 4 — Upgrade the control plane's own kubelet

`kubeadm upgrade apply` handles the control-plane *components*. The kubelet on
that machine is a separate package you upgrade yourself.

```bash
# Drain it first - it is a node like any other.
./lab kubectl drain k8s-cp --ignore-daemonsets --delete-emptydir-data

# Then, on the control plane:
apt-mark unhold kubelet kubectl
apt-get install -y kubelet=${TARGET} kubectl=${TARGET}
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet

./lab kubectl uncordon k8s-cp
./lab kubectl get nodes          # k8s-cp now on the new version
```

---

## Step 5 — Upgrade the worker

Repeat on `k8s-worker1`. The differences: `kubeadm upgrade **node**` instead of
`apply`, and you drain from the control plane before you start.

```bash
# From your host - drain evicts pods gracefully and stops new ones landing.
./lab kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data
./lab kubectl get nodes          # SchedulingDisabled
```

```bash
./lab ssh worker1
sudo -i

sed -i 's|v1.31|v1.32|g' /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
apt-get update

TARGET=1.32.1-1.1
apt-mark unhold kubeadm
apt-get install -y kubeadm=${TARGET}
apt-mark hold kubeadm

# 'node', not 'apply' - this only refreshes the local kubelet config.
kubeadm upgrade node

apt-mark unhold kubelet kubectl
apt-get install -y kubelet=${TARGET} kubectl=${TARGET}
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
exit; exit
```

```bash
./lab kubectl uncordon k8s-worker1
./lab kubectl get nodes -o wide      # both nodes on v1.32.x, both Ready
```

---

## Step 6 — Verify and clean up

```bash
./lab verify
./lab kubectl get pods -A
./lab backup after-upgrade
```

Update `lab.env` so future rebuilds use the new version:

```bash
K8S_MINOR="v1.32"
```

---

## If it goes wrong

**The upgrade fails midway.** `kubeadm` keeps the previous manifests in
`/etc/kubernetes/tmp/`. Read the error first — most failures are a version skew
or an unreachable registry, both fixable in place.

**A node will not come back Ready.**

```bash
./lab run worker1 'sudo journalctl -u kubelet -n 100 --no-pager'
./lab run worker1 'sudo systemctl status containerd'
./lab diagnostics
```

**The cluster is genuinely broken.** This is what Step 0 was for:

```bash
./lab restore backups/etcd-snapshot-<...>-before-upgrade.db
```

Note that restoring etcd reverts the *cluster state*, not the *binaries* on the
nodes. If you also need to downgrade packages:

```bash
apt-mark unhold kubelet kubeadm kubectl
apt-get install -y --allow-downgrades kubelet=<old> kubeadm=<old> kubectl=<old>
apt-mark hold kubelet kubeadm kubectl
```

**Fastest recovery of all, in a lab:** rebuild from scratch. That is a feature of
having the toolkit — `./lab reset all && ./lab up` takes about fifteen minutes.

---

## Verify your work

```bash
./verify.sh
```

## What to take away

- One minor version per hop, control plane first, workers after.
- `kubeadm` package → `kubeadm upgrade` → `kubelet`/`kubectl` packages. That order, on every node.
- `upgrade apply` on the first control plane; `upgrade node` everywhere else.
- Drain before, uncordon after — every node, no exceptions.
- The kubelet may lag the API server by up to two minors; it may never lead it.
- Snapshot etcd before you start. Every time.

Next: [Lab 07 — Troubleshooting](../07-troubleshooting/README.md)
