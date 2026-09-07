# Lab 02 — Services, DNS and NetworkPolicy

**Time:** ~35 minutes  **Prerequisites:** Lab 01, or any healthy cluster

Pods are disposable and their IPs change constantly. Services are the stable
address in front of them. This lab covers the three Service types you will
actually use, how cluster DNS finds them, and how to lock traffic down.

---

## Setup

```bash
kubectl create namespace lab02
kubectl config set-context --current --namespace=lab02
kubectl apply -f manifests/backend.yaml
kubectl rollout status deployment/backend
```

---

## Task 1 — ClusterIP: the default, in-cluster only

```bash
kubectl apply -f manifests/services.yaml
kubectl get svc backend-clusterip
kubectl get endpoints backend-clusterip
```

The `ENDPOINTS` column is the crux of Services. A Service is a **label selector
plus a virtual IP**; the endpoints controller fills in the list of matching,
*ready* Pod IPs. If endpoints is `<none>`, your selector does not match your pod
labels — that is the single most common Service bug.

Prove it works from inside the cluster:

```bash
kubectl run test --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -s http://backend-clusterip
```

Now break the selector on purpose and watch endpoints empty out:

```bash
kubectl patch svc backend-clusterip -p '{"spec":{"selector":{"app":"typo"}}}'
kubectl get endpoints backend-clusterip        # <none>
kubectl patch svc backend-clusterip -p '{"spec":{"selector":{"app":"backend"}}}'
kubectl get endpoints backend-clusterip        # back again
```

---

## Task 2 — Cluster DNS

Every Service gets a DNS name: `<service>.<namespace>.svc.cluster.local`.

```bash
kubectl run dns --rm -it --image=busybox:1.36 --restart=Never -- sh
# inside the pod:
nslookup backend-clusterip
nslookup backend-clusterip.lab02.svc.cluster.local
nslookup kubernetes.default.svc.cluster.local
cat /etc/resolv.conf     # note the search domains - this is why the short name works
exit
```

The `search lab02.svc.cluster.local svc.cluster.local cluster.local` line in
`/etc/resolv.conf` is why `backend-clusterip` alone resolves from inside the
namespace but not from another one.

If DNS fails here, check CoreDNS first:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
```

---

## Task 3 — NodePort: reaching the cluster from your laptop

```bash
kubectl get svc backend-nodeport
```

A NodePort opens the *same* high port (30000–32767) on **every** node. Hit
either node's LAN IP from your Mac or Windows machine:

```bash
# from your host, using the IPs in lab.env
curl http://<CP_IP>:30080
curl http://<WORKER_IP>:30080     # same Service, either node works
```

Both work even though the pods only run on one of them — kube-proxy forwards
the traffic across the cluster network. That is the piece that makes a
Kubernetes Service feel like a load balancer.

```bash
# Watch which pod answers - repeat this and the hostname changes.
for i in $(seq 5); do curl -s http://<CP_IP>:30080 | grep -o 'backend-[a-z0-9-]*'; done
```

---

## Task 4 — Headless Services and per-pod DNS

Set `clusterIP: None` and Kubernetes stops assigning a VIP; DNS returns the pod
IPs directly. StatefulSets rely on this for stable per-pod addressing.

```bash
kubectl get svc backend-headless
kubectl run dns --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup backend-headless.lab02.svc.cluster.local
```

You should see **multiple A records** — one per ready pod — instead of a single
virtual IP.

---

## Task 5 — NetworkPolicy: default-deny, then allow what you need

> Requires a policy-capable CNI. **Calico and Cilium enforce policies; Flannel
> does not.** If you chose Flannel in `lab.env`, read this section and move on.

Right now anything can talk to `backend`. Confirm that:

```bash
kubectl apply -f manifests/client.yaml
kubectl exec deploy/allowed-client -- curl -s -m 5 http://backend-clusterip     # works
kubectl exec deploy/denied-client  -- curl -s -m 5 http://backend-clusterip     # also works
```

Now apply a default-deny policy plus one targeted allow:

```bash
kubectl apply -f manifests/networkpolicy.yaml
sleep 5
kubectl exec deploy/allowed-client -- curl -s -m 5 http://backend-clusterip     # still works
kubectl exec deploy/denied-client  -- curl -s -m 5 http://backend-clusterip     # times out
```

**The mental model:** NetworkPolicies are additive allow-lists. The moment *any*
policy selects a pod, that pod is deny-by-default for the directions the policy
names, and only explicitly allowed traffic gets through.

---

## Verify your work

```bash
./verify.sh
```

## Clean up

```bash
kubectl delete namespace lab02
kubectl config set-context --current --namespace=default
```

---

## What to take away

| Thing | What it really is |
|---|---|
| ClusterIP | A virtual IP + label selector. In-cluster only. The default. |
| Endpoints / EndpointSlice | The live list of *ready* pod IPs behind a Service. Check this first when a Service "doesn't work". |
| NodePort | The same port on every node, forwarded into the Service. |
| Headless (`clusterIP: None`) | No VIP; DNS returns pod IPs. For StatefulSets and client-side balancing. |
| Cluster DNS | `<svc>.<ns>.svc.cluster.local`, plus a search path that makes short names work in-namespace. |
| NetworkPolicy | Additive allow-list. Selecting a pod makes it default-deny. Needs a CNI that enforces it. |

Next: [Lab 03 — Storage](../03-storage/README.md)
