# Lab 01 — Workloads: Deployments, rollouts and self-healing

**Time:** ~30 minutes  **Prerequisites:** a healthy 2-node cluster (`./lab verify` passes)

This is where you learn what the cluster actually *does for you*: keeps a stated
number of copies running, replaces them when they die, and rolls new versions
out without downtime.

---

## Setup

```bash
kubectl create namespace lab01
kubectl config set-context --current --namespace=lab01
```

> Everything below assumes namespace `lab01`. Run `kubectl config set-context
> --current --namespace=default` when you are done.

---

## Task 1 — Create a Deployment and watch it converge

```bash
kubectl create deployment web --image=nginx:1.25-alpine --replicas=3
kubectl get pods -o wide -w        # Ctrl-C when all three are Running
```

Look at the `NODE` column. Some pods should be on `k8s-worker1`. If everything
landed on the control plane, the worker is not `Ready` — go fix that first.

**What just happened:** you created a Deployment, which created a ReplicaSet,
which created Pods. The scheduler then chose a node for each Pod.

```bash
kubectl get deploy,rs,pods
kubectl describe deployment web | head -30
```

---

## Task 2 — Prove self-healing

Delete a Pod and watch a replacement appear within seconds:

```bash
kubectl delete pod "$(kubectl get pods -l app=web -o name | head -1)"
kubectl get pods -l app=web
```

The ReplicaSet noticed the count dropped below 3 and created a new Pod. **You
never asked it to.** That reconciliation loop is the core idea of Kubernetes.

Now try something harder — drain the worker and watch the pods relocate:

```bash
kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data
kubectl get pods -o wide          # all pods now on the control plane, or Pending
kubectl uncordon k8s-worker1      # let the node accept work again
```

> If the pods went `Pending` instead of moving, that is correct behaviour on a
> two-node cluster where the control plane still carries its `NoSchedule` taint.

---

## Task 3 — Add health probes

A container that is *running* is not necessarily *working*. Probes are how you
tell Kubernetes the difference.

Apply the manifest in this folder:

```bash
kubectl apply -f manifests/web-probes.yaml
kubectl rollout status deployment/web
kubectl describe pod -l app=web | grep -A3 -E 'Liveness|Readiness'
```

- **readinessProbe** — "should this Pod receive traffic?" A failing readiness
  probe removes the Pod from Service endpoints but leaves it running.
- **livenessProbe** — "is this container wedged?" A failing liveness probe
  restarts the container.

Break the readiness probe on purpose and watch the endpoints shrink:

```bash
POD=$(kubectl get pods -l app=web -o name | head -1)
kubectl exec "$POD" -- rm /usr/share/nginx/html/index.html
kubectl get endpoints web-svc -w      # that Pod's IP disappears; Ctrl-C to stop
kubectl delete "$POD"                 # replaced with a healthy one
```

---

## Task 4 — Rolling update and rollback

```bash
kubectl set image deployment/web nginx=nginx:1.27-alpine
kubectl rollout status deployment/web
kubectl rollout history deployment/web
```

Now deploy something broken and watch the rollout *stall* rather than take the
cluster down:

```bash
kubectl set image deployment/web nginx=nginx:this-tag-does-not-exist
kubectl rollout status deployment/web --timeout=60s     # times out, as it should
kubectl get pods                                        # ImagePullBackOff on the NEW pods only
```

The old pods are still serving. That is `maxUnavailable` protecting you. Roll back:

```bash
kubectl rollout undo deployment/web
kubectl rollout status deployment/web
kubectl get pods
```

---

## Task 5 — Resource requests and limits

```bash
kubectl set resources deployment/web --containers=nginx \
  --requests=cpu=100m,memory=64Mi --limits=cpu=200m,memory=128Mi
kubectl rollout status deployment/web
kubectl describe node k8s-worker1 | grep -A8 'Allocated resources'
```

- **requests** — what the scheduler reserves. Too high and pods go `Pending`.
- **limits** — the hard ceiling. Exceed memory and the container is OOMKilled.

See it for yourself:

```bash
kubectl top pods       # needs metrics-server (./lab addons installs it)
```

---

## Task 6 — A DaemonSet and a CronJob

```bash
kubectl apply -f manifests/node-logger.yaml     # DaemonSet: one pod per node
kubectl get ds,pods -o wide

kubectl apply -f manifests/backup-cronjob.yaml  # CronJob: runs every minute
kubectl get cronjob,jobs
kubectl logs -l job-name --tail=5 --prefix
```

A DaemonSet is how log shippers and CNI agents get onto every node — note that
its pod count tracks your node count automatically.

---

## Verify your work

```bash
./verify.sh
```

## Clean up

```bash
kubectl delete namespace lab01
kubectl config set-context --current --namespace=default
```

---

## What to take away

| Concept | The question it answers |
|---|---|
| Deployment | "Keep N copies of this running, and let me change the version safely." |
| ReplicaSet | The generation-specific worker a Deployment uses to do that. |
| readinessProbe | "Send traffic here?" — controls Service membership. |
| livenessProbe | "Is it wedged?" — controls container restarts. |
| requests | What the scheduler reserves; drives placement. |
| limits | The ceiling; drives throttling and OOMKills. |
| DaemonSet | "One copy per node," forever. |
| CronJob | "Run this on a schedule." |

Next: [Lab 02 — Services and networking](../02-services-networking/README.md)
