# Lab 03 — Storage: volumes, PVs, PVCs and StatefulSets

**Time:** ~30 minutes  **Prerequisites:** `./lab addons` (installs the
`local-path` StorageClass)

Containers are ephemeral. Everything written inside one disappears on restart.
This lab is about the three ways to make data outlive a pod.

---

## Setup

```bash
kubectl create namespace lab03
kubectl config set-context --current --namespace=lab03
kubectl get storageclass          # local-path should be marked (default)
```

If there is no default StorageClass, run `./lab addons` from your host first.

---

## Task 1 — Prove that container filesystems are ephemeral

```bash
kubectl run ephemeral --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/ephemeral --timeout=60s

kubectl exec ephemeral -- sh -c 'echo "important data" > /data.txt; cat /data.txt'
kubectl delete pod ephemeral
kubectl run ephemeral --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/ephemeral --timeout=60s
kubectl exec ephemeral -- cat /data.txt      # No such file. The data is gone.
kubectl delete pod ephemeral
```

---

## Task 2 — emptyDir: shared scratch space between containers

```bash
kubectl apply -f manifests/emptydir-pod.yaml
kubectl wait --for=condition=Ready pod/sidecar-demo --timeout=90s
kubectl logs sidecar-demo -c reader --tail=5
```

Two containers, one volume. The writer produces, the reader consumes. This is
the sidecar pattern — log shippers and config reloaders all work this way.

`emptyDir` lives and dies with the **Pod**, not the container: a container
restart keeps the data, deleting the pod loses it.

```bash
kubectl exec sidecar-demo -c writer -- ls -la /shared
kubectl delete pod sidecar-demo
```

---

## Task 3 — PersistentVolumeClaim: storage that outlives the pod

```bash
kubectl apply -f manifests/pvc-app.yaml
kubectl get pvc,pv
kubectl wait --for=condition=Ready pod/pvc-writer --timeout=120s
```

Watch the binding happen:

```bash
kubectl get pvc data-claim -o wide
# STATUS should be Bound, and a PV should have been created automatically
kubectl describe pv "$(kubectl get pvc data-claim -o jsonpath='{.spec.volumeName}')"
```

**Dynamic provisioning** is what just happened: you asked for 1Gi via a
StorageClass, and the provisioner created the PV for you. No admin involved.

Now write data, destroy the pod, and get the data back:

```bash
kubectl exec pvc-writer -- sh -c 'echo "survives pod deletion" > /data/proof.txt'
kubectl exec pvc-writer -- cat /data/proof.txt

kubectl delete pod pvc-writer
kubectl apply -f manifests/pvc-app.yaml
kubectl wait --for=condition=Ready pod/pvc-writer --timeout=120s
kubectl exec pvc-writer -- cat /data/proof.txt      # still there
```

> **Important lab caveat:** `local-path` volumes live on **one specific node's**
> disk. Check which:
> ```bash
> kubectl get pod pvc-writer -o wide
> ```
> The pod is pinned to that node forever. This is exactly why real clusters use
> networked storage (NFS, Ceph, a cloud disk) — and it is also why **an etcd
> snapshot does not back up your PV data.** Lab 05 makes that point again.

---

## Task 4 — ConfigMaps and Secrets as volumes

```bash
kubectl apply -f manifests/config-and-secret.yaml
kubectl wait --for=condition=Ready pod/config-demo --timeout=90s

kubectl exec config-demo -- cat /etc/app/app.properties
kubectl exec config-demo -- ls -la /etc/secret
kubectl exec config-demo -- cat /etc/secret/password
kubectl exec config-demo -- env | grep -E 'APP_MODE|DB_PASSWORD'
```

Mounted ConfigMaps update in place (within a minute or so) without a restart;
values injected as environment variables do **not**. Prove it:

```bash
kubectl patch configmap app-config --type merge -p '{"data":{"app.properties":"mode=updated\nreplicas=9\n"}}'
sleep 70
kubectl exec config-demo -- cat /etc/app/app.properties   # updated
kubectl exec config-demo -- env | grep APP_MODE           # unchanged
```

**On Secrets:** they are base64-encoded, **not encrypted**, and anyone with read
access to the namespace can decode them:

```bash
kubectl get secret app-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Real clusters add encryption-at-rest for etcd and an external secret manager.
Note the connection to Lab 05: **your etcd snapshot contains every Secret in
plaintext-recoverable form**, which is why snapshots need protecting like
credentials.

---

## Task 5 — StatefulSet: stable identity plus per-pod storage

```bash
kubectl apply -f manifests/statefulset.yaml
kubectl rollout status statefulset/web-stateful --timeout=180s
kubectl get pods -l app=web-stateful -o wide
kubectl get pvc
```

Notice three things a Deployment would never give you:

1. **Ordered, predictable names** — `web-stateful-0`, `-1`, not random suffixes.
2. **One PVC per pod**, created automatically from `volumeClaimTemplates`.
3. **Stable DNS per pod**, via the headless Service:
   `web-stateful-0.web-stateful.lab03.svc.cluster.local`

```bash
kubectl exec web-stateful-0 -- sh -c 'echo "I am pod 0" > /usr/share/nginx/html/id.txt'
kubectl exec web-stateful-1 -- sh -c 'echo "I am pod 1" > /usr/share/nginx/html/id.txt'

kubectl delete pod web-stateful-0
kubectl wait --for=condition=Ready pod/web-stateful-0 --timeout=120s
kubectl exec web-stateful-0 -- cat /usr/share/nginx/html/id.txt   # "I am pod 0"
```

The replacement pod reattached to *pod 0's* volume. That identity-to-storage
binding is the whole reason StatefulSets exist — it is how databases run on
Kubernetes.

---

## Verify your work

```bash
./verify.sh
```

## Clean up

```bash
kubectl delete namespace lab03
# StatefulSet PVCs are deliberately NOT deleted with the namespace's workloads:
kubectl -n lab03 delete pvc --all 2>/dev/null
kubectl config set-context --current --namespace=default
```

---

## What to take away

| Volume type | Lifetime | Use it for |
|---|---|---|
| container filesystem | the container | nothing you care about |
| `emptyDir` | the Pod | scratch space, sidecar handoff |
| PVC + PV | independent of any pod | application data |
| ConfigMap volume | the object | config files; updates propagate |
| Secret volume | the object | credentials; base64, not encrypted |
| StatefulSet `volumeClaimTemplates` | per-pod, stable | databases, queues, anything with identity |

Next: [Lab 04 — RBAC](../04-rbac/README.md)
