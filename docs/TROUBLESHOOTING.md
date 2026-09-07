# Troubleshooting reference

Symptom → cause → fix, for the problems this lab actually produces. Start with
`./lab diagnostics` if you want everything collected in one bundle.

---

## Build-time problems

### `./lab check` says a node is unreachable

```bash
ping <node-ip>                       # from your host
ssh <user>@<node-ip>                 # does plain SSH work at all?
```

1. **Wrong IP in `lab.env`.** Log into the VM console and run `ip -4 addr`.
2. **NAT instead of bridged networking.** An address in `10.0.2.x` is
   VirtualBox NAT. The VMs must be **bridged** or they can never see each other.
   Fix the adapter and reboot the VM.
3. **No SSH server.** You did not tick "Install OpenSSH server" during the
   Ubuntu install: `sudo apt install -y openssh-server && sudo systemctl enable --now ssh`.
4. **No key installed.** Run `./lab ssh-setup`.

### `kubeadm init` fails on preflight checks

Read the exact message; kubeadm is specific.

| Message | Fix |
|---|---|
| `[ERROR Swap]` | `sudo swapoff -a` and comment it out of `/etc/fstab` — `02-prep-node.sh` does both |
| `[ERROR NumCPU]` | The VM needs ≥ 2 vCPUs. Shut it down and change the setting |
| `[ERROR Mem]` | Control plane needs ≥ 1700 MB |
| `[ERROR Port-6443]` | Something is already listening. `sudo kubeadm reset -f` first |
| `[ERROR FileAvailable--etc-kubernetes-manifests-...]` | A previous install is present. `sudo kubeadm reset -f` |
| `[ERROR CRI]` | containerd is not running or the socket path is wrong. `sudo systemctl status containerd` |

Then retry:

```bash
sudo kubeadm reset -f
./lab init
```

### Control plane stays `NotReady`

Almost always: **no CNI installed**. The kubelet will not report Ready without a
working network plugin.

```bash
kubectl get pods -n kube-system         # CoreDNS Pending? classic symptom
./lab kubectl get nodes
./lab init                              # re-runs the CNI install idempotently
```

If a CNI *is* installed and the node is still NotReady:

```bash
kubectl describe node <node> | grep -A10 Conditions
./lab run cp 'sudo journalctl -u kubelet -n 100 --no-pager'
```

### Worker joins but never becomes `Ready`

```bash
kubectl describe node k8s-worker1 | grep -A10 Conditions
kubectl get pods -n kube-system -o wide | grep worker
./lab run worker1 'sudo journalctl -u kubelet -n 100 --no-pager'
```

- The CNI pod for that node may still be pulling its image — wait 2 minutes.
- The worker may not be able to reach the control plane on 6443:
  `./lab run worker1 'nc -zv <CP_IP> 6443'`
- Check the cgroup driver matches:
  `./lab run worker1 'grep SystemdCgroup /etc/containerd/config.toml'` must be `true`.

### The join token expired

Tokens last 24 hours.

```bash
./lab join                              # fetches a fresh token automatically
# or, by hand on the control plane:
sudo kubeadm token create --print-join-command
```

### Two nodes register with the same name or IP

You cloned a VM instead of installing fresh. Every node needs a unique hostname,
machine-id and MAC address:

```bash
sudo hostnamectl set-hostname k8s-worker1
sudo rm -f /etc/machine-id /var/lib/dbus/machine-id
sudo systemd-machine-id-setup
sudo reboot
```

Change the MAC in the hypervisor's network settings too, then `./lab reset
worker1 && ./lab join`.

---

## Runtime problems

### Pod stuck `Pending`

```bash
kubectl describe pod <pod> | tail -20    # Events explain it precisely
```

- `Insufficient cpu/memory` → requests are too high, or the cluster is full
- `had untolerated taint` → node taint (including the control-plane taint)
- `pod has unbound immediate PersistentVolumeClaims` → no matching PV / no default StorageClass
- `node(s) didn't match Pod's node affinity` → nodeSelector or affinity matches nothing

### Pod stuck `ContainerCreating`

```bash
kubectl describe pod <pod> | tail -20
./lab run <node> 'sudo journalctl -u kubelet -n 50 --no-pager'
```

- `failed to setup network for sandbox` → CNI problem
- `MountVolume.SetUp failed` → the ConfigMap/Secret/PVC does not exist
- `failed to pull image` → see `ImagePullBackOff` below

### `ImagePullBackOff` / `ErrImagePull`

```bash
kubectl describe pod <pod> | grep -A5 Events
```

Wrong tag, private registry with no `imagePullSecret`, Docker Hub rate limit, or
an architecture mismatch (an amd64-only image on an arm64 node). The event text
says which.

### `CrashLoopBackOff`

```bash
kubectl logs <pod> --previous            # the run that actually failed
kubectl describe pod <pod> | grep -A6 'Last State'
```

Exit codes: `1` app error · `137` SIGKILL, almost always OOMKilled · `143`
SIGTERM · `0` in a loop means a job-like container with `restartPolicy: Always`.

### `Running` but never `Ready`

A readiness probe is failing.

```bash
kubectl describe pod <pod> | grep -A5 -i readiness
kubectl exec <pod> -- wget -qO- localhost:<port><path>    # test the probe by hand
```

### Service unreachable

```bash
kubectl get endpoints <svc>              # ALWAYS start here
```

- **`<none>`** → the selector matches no pods, or no pod is Ready. Compare
  `kubectl get svc <svc> -o jsonpath='{.spec.selector}'` with
  `kubectl get pods --show-labels`.
- **Populated but still failing** → wrong `targetPort`, a NetworkPolicy, or the
  app not listening where it claims. Test from inside:
  `kubectl run t --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- curl -v http://<pod-ip>:<port>`

### DNS not resolving

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system get endpoints kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
kubectl run t --rm -it --image=busybox:1.36 --restart=Never -- cat /etc/resolv.conf
```

No CoreDNS pods → scaled to zero or unschedulable. CoreDNS `Pending` → the CNI
is broken. `loop detected` in the logs → the host's `/etc/resolv.conf` points at
127.0.0.53; that is a systemd-resolved stub-resolver issue.

### `kubectl` on the host stops working

```bash
./lab kubeconfig                         # re-fetch it
./lab run cp 'sudo kubeadm certs check-expiration'
```

kubeadm certificates expire after one year. Renew them:

```bash
./lab ssh cp
sudo kubeadm certs renew all
sudo systemctl restart kubelet
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
exit
./lab kubeconfig
```

### Everything was fine yesterday and is broken today

Check the two things that change on their own: **time** and **certificates**.

```bash
./lab run all 'timedatectl | head -5'
./lab run cp 'sudo kubeadm certs check-expiration'
./lab run all 'df -h / && free -h'          # full disk / exhausted memory
```

Clock skew between nodes breaks TLS in confusing ways. A full disk triggers
`DiskPressure`, which taints the node and evicts pods.

---

## Restore problems

### After a restore, the API server never comes back

```bash
./lab run cp 'sudo crictl ps -a | grep -E "etcd|apiserver"'
./lab run cp 'sudo crictl logs $(sudo crictl ps -a --name etcd -q | head -1)'
./lab run cp 'sudo journalctl -u kubelet -n 100 --no-pager'
```

The usual cause: `etcd.yaml` was updated in only one of the two places.
**Both** must point at the restored directory:

```bash
./lab run cp 'sudo grep -nE "data-dir|path: /var/lib/etcd" /etc/kubernetes/manifests/etcd.yaml'
```

Rollback: point `etcd.yaml` back at the original data dir and move
`/var/lib/etcd.pre-restore-*` back into place — `31-etcd-restore.sh` prints the
exact commands when it fails.

### The restore succeeded but the cluster is empty

You restored a snapshot taken before those objects existed, or etcd started
against a fresh directory. Check what the snapshot actually contains before
restoring:

```bash
./lab run cp 'sudo etcdutl snapshot status /opt/etcd-backups/<file>.db --write-out=table'
```

A healthy lab snapshot has thousands of keys. A few hundred means it was taken
from a near-empty cluster.

---

## Nuclear options

```bash
./lab reset worker1 && ./lab join worker1     # rebuild one worker
./lab reset all && ./lab up                   # rebuild everything (~15 min)
```

In a lab, rebuilding is often faster than debugging — and rebuilding from
scratch under time pressure is itself the CKA exercise.
