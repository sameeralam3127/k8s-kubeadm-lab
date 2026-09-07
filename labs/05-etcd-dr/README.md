# Lab 05 — etcd backup and disaster recovery

**Time:** ~45 minutes  **Prerequisites:** a healthy cluster with a joined worker

etcd holds **all** cluster state — every namespace, Deployment, Secret, RBAC
rule and ConfigMap. Lose it without a backup and the cluster is gone, even
though the nodes are still running. This is the highest-value skill in the
whole lab and a guaranteed CKA exam topic.

There are two ways through this lab:

- **Guided (recommended first):** `./lab dr-drill` runs the whole cycle for you
  and tells you what it is doing at each step.
- **By hand (what you must be able to do under exam conditions):** everything below.

---

## Part 1 — Understand what you are backing up

SSH to the control plane:

```bash
./lab ssh cp
sudo -i
export KUBECONFIG=/etc/kubernetes/admin.conf
```

etcd runs as a **static pod** — not scheduled by the API server, but started
directly by the kubelet from a file on disk:

```bash
cat /etc/kubernetes/manifests/etcd.yaml
kubectl -n kube-system get pod -l component=etcd
```

Two details from that manifest matter for everything that follows:

```bash
grep -E 'data-dir|listen-client-urls|cert-file|key-file|trusted-ca-file' \
  /etc/kubernetes/manifests/etcd.yaml
```

- `--data-dir` — where the database lives (usually `/var/lib/etcd`)
- the three cert paths — etcd requires mutual TLS; you cannot query it without them

> **Never hard-code these.** After a restore, the data dir changes. Reading them
> back out of the manifest is why `30-etcd-backup.sh` keeps working afterwards.

Talk to etcd directly:

```bash
export ETCDCTL_API=3
ETCD="etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

$ETCD endpoint health --write-out=table
$ETCD endpoint status --write-out=table
$ETCD member list --write-out=table
```

See your cluster as etcd sees it — every object is a key:

```bash
$ETCD get /registry --prefix --keys-only | head -30
$ETCD get /registry --prefix --keys-only | wc -l
```

**Now the security lesson.** Read a Secret straight out of the datastore:

```bash
kubectl create secret generic demo --from-literal=password=hunter2
$ETCD get /registry/secrets/default/demo | strings | grep hunter2
```

There it is, in the clear. **An etcd snapshot is a file containing every secret
in your cluster.** Protect snapshots exactly as you would protect passwords —
which is why `30-etcd-backup.sh` writes them `0600` into a `0700` directory.

---

## Part 2 — Take a backup by hand

```bash
mkdir -p /opt/etcd-backups

$ETCD snapshot save /opt/etcd-backups/manual-snapshot.db

# ALWAYS verify. An unverified backup is a rumour.
etcdutl snapshot status /opt/etcd-backups/manual-snapshot.db --write-out=table
sha256sum /opt/etcd-backups/manual-snapshot.db
```

`snapshot status` shows the revision count and total keys — a snapshot that
reads back is a snapshot you can restore.

Then get it **off the machine**, because a backup on the host you are protecting
is not a backup:

```bash
exit; exit          # back to your own host
./lab backup manual
ls -lh backups/
```

The toolkit's script does all of this plus a health check, a checksum, a `.meta`
file recording the data dir and version, and rotation.

---

## Part 3 — Break the cluster on purpose

Back on the control plane, create something recognisable, then destroy it:

```bash
./lab kubectl create namespace critical-app
./lab kubectl -n critical-app create deployment payments --image=nginx:stable-alpine --replicas=3
./lab kubectl -n critical-app rollout status deploy/payments

./lab backup before-disaster        # snapshot WITH the app present

# The 3am mistake:
./lab kubectl delete namespace critical-app
./lab kubectl get ns critical-app   # NotFound
```

---

## Part 4 — Restore, step by step

This is the sequence to memorise. Each step exists for a reason.

```bash
./lab ssh cp
sudo -i
```

**Step 1 — restore into a NEW directory.** Never restore over a live data dir;
etcd will refuse or corrupt itself.

```bash
etcdutl snapshot restore /opt/etcd-backups/<your-snapshot>.db \
  --data-dir=/var/lib/etcd-restored
ls /var/lib/etcd-restored          # member/
```

**Step 2 — stop the control plane** by moving the static pod manifests out of
the directory the kubelet watches. The kubelet sees them vanish and tears the
pods down.

```bash
mkdir -p /etc/kubernetes/manifests-offline
mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests-offline/

# Wait for the containers to actually exit before touching the data.
crictl ps | grep -E 'etcd|kube-apiserver'      # should become empty
```

**Step 3 — move the old data aside** (do not delete it; it is your rollback).

```bash
mv /var/lib/etcd /var/lib/etcd.old
```

**Step 4 — point etcd at the restored data.** Two places must change together:

```bash
vi /etc/kubernetes/manifests-offline/etcd.yaml
```

- the container arg `--data-dir=/var/lib/etcd` → `/var/lib/etcd-restored`
- the `hostPath` volume with `path: /var/lib/etcd` → `/var/lib/etcd-restored`

> **Forgetting the volume is the classic failure.** etcd then starts against an
> empty directory, the API server comes up, and your cluster looks *restored*
> but empty. Change both.

**Step 5 — restart the control plane.**

```bash
mv /etc/kubernetes/manifests-offline/*.yaml /etc/kubernetes/manifests/
systemctl restart kubelet
```

**Step 6 — verify.** Give it 60–90 seconds.

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get nodes
kubectl get ns critical-app
kubectl -n critical-app get deploy,pods
```

`critical-app` is back. So is everything else that existed when the snapshot was
taken — and anything created *after* it is gone.

The toolkit does all six steps, with verification and a rollback hint, via:

```bash
./lab restore --latest
```

---

## Part 5 — Understand the limits

Run these and reason about the results:

```bash
# 1. A snapshot is point-in-time. Anything after it is not in the backup.
./lab kubectl create ns after-snapshot
./lab restore --latest
./lab kubectl get ns after-snapshot        # NotFound. Expected.

# 2. Worker nodes are NOT in the snapshot's control.
#    They re-register from their own kubelet certs, which is why they come back.
./lab kubectl get nodes

# 3. PersistentVolume DATA is not in the snapshot - only the PV/PVC OBJECTS are.
#    etcd stores the metadata; the bytes live on a disk somewhere else.
```

| Restored by an etcd snapshot | NOT restored |
|---|---|
| Namespaces, Deployments, Pods specs | PersistentVolume **contents** |
| Secrets, ConfigMaps, ServiceAccounts | Container images on nodes |
| RBAC rules, CRDs and custom resources | Anything created after the snapshot |
| Service and Ingress definitions | Node OS state, kubelet config on disk |

---

## Part 6 — Automate it

A backup you have to remember to run is a backup you do not have. Add a cron job
on the control plane:

```bash
./lab ssh cp
sudo crontab -e
```

```cron
# Hourly etcd snapshot, keeping the last 24
0 * * * * /tmp/k8s-lab/scripts/node/30-etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```

> `/tmp` is cleared on reboot. For anything you rely on, copy the scripts to a
> permanent location first:
> ```bash
> sudo cp -r /tmp/k8s-lab/scripts /opt/k8s-lab-scripts
> ```
> then point cron at `/opt/k8s-lab-scripts/node/30-etcd-backup.sh`.

Pull the snapshots to your host on a schedule too — that is the part that makes
them real backups.

---

## Verify your work

```bash
./verify.sh
```

## What to take away

1. **etcd is the cluster.** Nodes are replaceable; etcd is not.
2. **Restore into a new data dir.** Never over a running one.
3. **Change `--data-dir` AND the hostPath volume.** Both, together.
4. **Stop the control plane by moving static pod manifests**, not by killing containers — the kubelet just restarts those.
5. **Verify every snapshot** with `snapshot status` and a checksum.
6. **Copy snapshots off the host.** A backup on the failed machine is not a backup.
7. **Snapshots contain your secrets in recoverable form.** Guard them accordingly.
8. **PV data is not in the snapshot.** Back that up separately.

Next: [Lab 06 — Cluster upgrades](../06-upgrade/README.md)
