# Lab 07 — Troubleshooting: break it, then fix it

**Time:** ~60 minutes  **Prerequisites:** a healthy cluster and a snapshot
(`./lab backup before-troubleshooting`)

Everything so far has been about building. This lab is about the other 90% of
the job. It ships with `break-it.sh`, which introduces real, realistic faults
one at a time. You diagnose and fix each one.

> **Do not read the fix before you have tried.** The point is to build the
> reflex of looking in the right place, in the right order.

---

## The diagnostic ladder

Work top-down. Almost every problem announces itself at one of these rungs.

```
1. kubectl get nodes                    Is the node even there and Ready?
2. kubectl get pods -A -o wide          What is not Running, and where?
3. kubectl describe pod <pod>           Events at the bottom - read these FIRST
4. kubectl logs <pod> [-c container]    The app's own account of itself
5. kubectl logs <pod> --previous        Why the LAST attempt died (crash loops)
6. kubectl get events -A --sort-by=.lastTimestamp
7. journalctl -u kubelet -f             When the pod never got created at all
8. crictl ps -a / crictl logs <id>      When the kubelet cannot talk to the runtime
```

**Read `describe` events before you read logs.** Scheduling failures, image pull
errors, probe failures and volume mount problems all show up there, and none of
them produce application logs — because the container never started.

---

## Reading pod status

| Status | Where the problem is | First command |
|---|---|---|
| `Pending` | Scheduler — no node fits | `kubectl describe pod` → Events |
| `ContainerCreating` | Kubelet — image, volume, or CNI | `kubectl describe pod`, then `journalctl -u kubelet` |
| `ImagePullBackOff` | Wrong image name/tag, or registry auth | `kubectl describe pod` → Events |
| `CrashLoopBackOff` | The app starts and exits | `kubectl logs --previous` |
| `Error` / `OOMKilled` | Exceeded a limit, or bad exit code | `kubectl describe pod` → Last State |
| `Running` but not `Ready` | Readiness probe failing | `kubectl describe pod` → probe events |
| `Terminating` forever | Finalizer or a stuck volume | `kubectl get pod -o yaml` → `finalizers` |

---

## The scenarios

```bash
./break-it.sh list                # see all scenarios
./break-it.sh break <n>           # introduce fault n
./break-it.sh hint <n>            # a nudge, if you are stuck
./break-it.sh solution <n>        # the explanation and the fix
./break-it.sh fix <n>             # repair it for you
./break-it.sh fix all             # clean up everything
```

Run it from your host (it uses your kubeconfig) or on the control plane.

### 1. Pod stuck in Pending
Resource requests no node can satisfy. Learn to read the scheduler's own
explanation in the pod's events.

### 2. ImagePullBackOff
A typo'd image tag. Trivial once you know where it is stated — and it is stated
very clearly.

### 3. CrashLoopBackOff
The container starts, fails, and exits. The evidence is in the *previous*
container's logs, not the current one's.

### 4. Service with no endpoints
The Service selector does not match the pod labels. This is the single most
common "my app is unreachable" cause in the real world.

### 5. Wrong ConfigMap key
A pod that cannot start because a referenced key does not exist. The error names
the exact key — if you look.

### 6. Node NotReady (kubelet stopped)
The infrastructure-level failure. `kubectl` tells you *that* it happened;
`journalctl` on the node tells you *why*.

### 7. DNS resolution failing
CoreDNS scaled to zero. Everything still "runs" but nothing can find anything —
one of the most disorienting failure modes there is.

### 8. Disk pressure eviction
A node taint you did not add, and pods being evicted because of it. Teaches you
to read node conditions.

---

## Worked example — scenario 4, step by step

```bash
./break-it.sh break 4
```

**Symptom:** the app is unreachable.

```bash
kubectl -n tshoot get pods                     # all Running, all Ready. Puzzling.
kubectl -n tshoot get svc                      # the Service exists, has a ClusterIP
kubectl -n tshoot get endpoints broken-svc     # ENDPOINTS: <none>   <-- there it is
```

`<none>` means the Service matched zero *ready* pods. Two possible causes: the
selector is wrong, or no pod is ready. The pods *are* ready, so:

```bash
kubectl -n tshoot get svc broken-svc -o jsonpath='{.spec.selector}'; echo
kubectl -n tshoot get pods --show-labels
```

Compare the two. They differ. Fix and confirm:

```bash
kubectl -n tshoot patch svc broken-svc -p '{"spec":{"selector":{"app":"tshoot-app"}}}'
kubectl -n tshoot get endpoints broken-svc     # pod IPs appear
```

**The lesson:** when a Service "doesn't work", `kubectl get endpoints` is the
first command, not the fifth. It splits the problem cleanly in half — empty
endpoints is a selector/readiness problem, populated endpoints is a network or
application problem.

---

## Node-level troubleshooting

Some failures never reach the API server. For those, get onto the node:

```bash
./lab ssh worker1

# Is the kubelet even alive?
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u kubelet -f                     # follow it live

# Is the container runtime alive?
sudo systemctl status containerd
sudo crictl ps -a                                 # every container, including dead ones
sudo crictl logs <container-id>
sudo crictl images

# The four classics, in the order they bite:
sudo swapon --show                                # must be EMPTY
grep SystemdCgroup /etc/containerd/config.toml    # must be true
sysctl net.ipv4.ip_forward                        # must be 1
sudo ls /etc/kubernetes/manifests/                # control plane: pods live here
```

Or collect everything at once and read it at your leisure:

```bash
./lab diagnostics
```

---

## Certificate expiry — the one that gets everyone

kubeadm certificates last **one year**. A lab you come back to after twelve
months will refuse every `kubectl` command with a TLS error.

```bash
./lab run cp 'sudo kubeadm certs check-expiration'
```

Renew them:

```bash
./lab ssh cp
sudo kubeadm certs renew all
# The control-plane static pods must restart to pick up the new certs:
sudo systemctl restart kubelet
# Refresh your admin kubeconfig too - it embeds a client cert:
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
exit
./lab kubeconfig
```

---

## Verify your work

```bash
./verify.sh
```

Passes only when every scenario is repaired and the cluster is healthy.

## Clean up

```bash
./break-it.sh fix all
kubectl delete namespace tshoot
```

---

## What to take away

- **Events before logs.** `describe` explains everything that happens before a container starts.
- **`--previous` for crash loops.** The current container has no story to tell; the dead one does.
- **`get endpoints` for Service problems.** It halves the search space instantly.
- **`journalctl -u kubelet` when the pod does not exist.** No pod means no pod logs.
- **`crictl` when the kubelet cannot reach the runtime.** It talks to containerd directly.
- **Node conditions and taints explain evictions.** `kubectl describe node` has them.
- **Certificates expire after a year.** `kubeadm certs check-expiration`.

You have finished the labs. Rebuild the whole cluster from scratch without
notes, timing yourself — that is exactly the CKA exam format:

```bash
./lab reset all && ./lab up
```
