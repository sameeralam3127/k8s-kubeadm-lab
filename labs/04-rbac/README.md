# Lab 04 — RBAC: identities, roles and least privilege

**Time:** ~35 minutes  **Prerequisites:** a healthy cluster

Every request to the API server is authenticated (who are you?) then authorised
(may you do that?). This lab covers both halves for the two kinds of identity
Kubernetes recognises: **ServiceAccounts** (in-cluster) and **users** (outside,
identified by a client certificate).

---

## Setup

```bash
kubectl create namespace lab04
kubectl create namespace lab04-other
kubectl config set-context --current --namespace=lab04
```

---

## Task 1 — `auth can-i`, the tool that answers every RBAC question

```bash
kubectl auth can-i create deployments                 # as you (cluster-admin): yes
kubectl auth can-i delete nodes
kubectl auth can-i '*' '*' --all-namespaces           # yes - admin.conf is cluster-admin
```

Now ask on someone else's behalf — this is how you debug RBAC without ever
logging in as them:

```bash
kubectl auth can-i list pods --as=system:serviceaccount:lab04:default
kubectl auth can-i list pods --as=jane
```

Both should say `no`. Nothing is permitted until you grant it.

---

## Task 2 — ServiceAccount + Role + RoleBinding (namespace-scoped)

```bash
kubectl apply -f manifests/serviceaccount-rbac.yaml
kubectl get sa,role,rolebinding
```

Read [`manifests/serviceaccount-rbac.yaml`](manifests/serviceaccount-rbac.yaml)
before continuing — the comments explain each field.

Check the grant took effect:

```bash
SA=system:serviceaccount:lab04:pod-reader

kubectl auth can-i list pods    --as=$SA                    # yes
kubectl auth can-i get  pods    --as=$SA                    # yes
kubectl auth can-i delete pods  --as=$SA                    # no  (verb not granted)
kubectl auth can-i list secrets --as=$SA                    # no  (resource not granted)
kubectl auth can-i list pods    --as=$SA -n lab04-other     # no  (Role is namespaced)
```

Those four "no"s are the whole point: a Role grants **exactly** the verbs on
exactly the resources in exactly one namespace.

Now use the identity for real. This pod runs `kubectl` as that ServiceAccount:

```bash
kubectl apply -f manifests/sa-test-pod.yaml
kubectl wait --for=condition=Ready pod/rbac-tester --timeout=120s

kubectl exec rbac-tester -- kubectl get pods                     # works
kubectl exec rbac-tester -- kubectl get secrets                  # Forbidden
kubectl exec rbac-tester -- kubectl -n lab04-other get pods      # Forbidden
```

The pod authenticated with the token the kubelet projected into
`/var/run/secrets/kubernetes.io/serviceaccount/`. Look at it:

```bash
kubectl exec rbac-tester -- ls /var/run/secrets/kubernetes.io/serviceaccount/
```

---

## Task 3 — ClusterRole + ClusterRoleBinding (cluster-wide)

```bash
kubectl apply -f manifests/clusterrole-rbac.yaml

SA=system:serviceaccount:lab04:node-viewer
kubectl auth can-i list nodes --as=$SA                  # yes - nodes are cluster-scoped
kubectl auth can-i list pods --as=$SA --all-namespaces  # yes - ClusterRoleBinding is global
kubectl auth can-i delete nodes --as=$SA                # no
```

**The four-way matrix worth memorising:**

| Role type | Binding type | Effect |
|---|---|---|
| `Role` | `RoleBinding` | Permissions in **that one namespace** |
| `ClusterRole` | `RoleBinding` | The ClusterRole's rules, but **limited to the binding's namespace** — the reusable pattern |
| `ClusterRole` | `ClusterRoleBinding` | Permissions **everywhere**, plus cluster-scoped resources |
| `Role` | `ClusterRoleBinding` | **Invalid.** Does not work. |

Row 2 is the one people miss. Define a `ClusterRole` once, bind it per namespace:

```bash
kubectl create rolebinding read-in-other \
  --clusterrole=pod-reader-cluster \
  --serviceaccount=lab04:node-viewer \
  -n lab04-other
kubectl auth can-i list pods --as=$SA -n lab04-other      # now yes
```

---

## Task 4 — A real human user with a client certificate

Kubernetes has no `User` object. A "user" is just a client certificate whose
**CN is the username** and whose **O fields are the groups**, signed by the
cluster CA. Run this on the control plane:

```bash
./lab ssh cp
sudo bash /tmp/k8s-lab/scripts/node/../../labs/04-rbac/create-user.sh jane developers
```

Or, more simply, from your host:

```bash
./lab run cp 'sudo bash -s' < labs/04-rbac/create-user.sh jane
```

The script walks you through: generate a key, create a `CertificateSigningRequest`,
approve it with `kubectl certificate approve`, extract the signed cert, and build
a kubeconfig. Read it — every line is commented.

Then grant `jane` something and test:

```bash
kubectl create rolebinding jane-reader --role=pod-reader --user=jane -n lab04
kubectl auth can-i list pods --as=jane -n lab04       # yes
kubectl auth can-i list pods --as=jane -n default     # no
```

---

## Task 5 — Find out what a role can actually do

Auditing beats guessing:

```bash
# Everything a ClusterRole grants
kubectl describe clusterrole view | head -40

# Who is bound to cluster-admin?
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " +
         ([.subjects[]? | .kind + "/" + .name] | join(", "))'

# Every binding that touches your ServiceAccount
kubectl get rolebindings,clusterrolebindings -A -o json | \
  jq -r '.items[] | select(.subjects[]?.name=="pod-reader") | .metadata.name'
```

> No `jq` on the node? `sudo apt install -y jq`, or use
> `kubectl get clusterrolebindings -o wide | grep cluster-admin`.

---

## Verify your work

```bash
./verify.sh
```

## Clean up

```bash
kubectl delete namespace lab04 lab04-other
kubectl delete clusterrole pod-reader-cluster node-viewer-cluster 2>/dev/null
kubectl delete clusterrolebinding node-viewer-binding 2>/dev/null
kubectl config set-context --current --namespace=default
```

---

## What to take away

- **Deny by default.** Nothing is permitted until a binding grants it.
- **Roles are additive.** There is no "deny" rule — you cannot subtract a permission.
- `Role`/`RoleBinding` = namespaced. `ClusterRole`/`ClusterRoleBinding` = cluster-wide.
- A `ClusterRole` bound with a `RoleBinding` is namespace-limited — define once, bind many times.
- `kubectl auth can-i <verb> <resource> --as=<subject>` answers every "why is this Forbidden?" question.
- Users are certificates. The CN is the username, the O fields are the groups.
- `admin.conf` is `cluster-admin`. Treat it like a root password; do not hand it out.

Next: [Lab 05 — etcd backup and disaster recovery](../05-etcd-dr/README.md)
