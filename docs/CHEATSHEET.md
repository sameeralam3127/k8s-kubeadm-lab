# Command cheat sheet

Everything in one place. Commands marked **(host)** run on your Mac/Windows
machine; **(node)** run inside a VM over SSH.

---

## The toolkit

| macOS / Linux (host) | Windows (host) | Does |
|---|---|---|
| `./lab check` | `.\lab.ps1 check` | Validate config + SSH to every node |
| `./lab ssh-setup` | `.\lab.ps1 ssh-setup` | Create and install an SSH key |
| `./lab preflight` | `.\lab.ps1 preflight` | Read-only readiness checks |
| `./lab up` | `.\lab.ps1 up` | Build the whole cluster |
| `./lab status` | `.\lab.ps1 status` | One-screen overview |
| `./lab verify` | `.\lab.ps1 verify` | Health check + live smoke test |
| `./lab kubeconfig` | `.\lab.ps1 kubeconfig` | Fetch admin.conf to the host |
| `./lab backup [label]` | `.\lab.ps1 backup` | etcd snapshot, pulled locally |
| `./lab restore [file]` | `.\lab.ps1 restore` | Restore etcd |
| `./lab dr-drill` | `.\lab.ps1 dr-drill` | Guided disaster-recovery exercise |
| `./lab diagnostics` | `.\lab.ps1 diagnostics` | Support bundle from every node |
| `./lab reset all` | `.\lab.ps1 reset all` | Tear the cluster back down |
| `./lab ssh cp` | `.\lab.ps1 ssh cp` | Shell on the control plane |
| `./lab run all <cmd>` | `.\lab.ps1 run all <cmd>` | Run a command on every node |

---

## Cluster inspection

```bash
kubectl get nodes -o wide
kubectl describe node <node>                  # conditions, taints, allocations
kubectl top nodes                             # needs metrics-server
kubectl cluster-info
kubectl get --raw='/readyz?verbose'           # per-component health
kubectl api-resources                         # every resource type + short name
kubectl get componentstatuses                 # deprecated but still informative
kubectl version -o yaml
```

## Pods

```bash
kubectl get pods -A -o wide
kubectl get pods -A --field-selector=status.phase!=Running
kubectl get pods --show-labels
kubectl get pods -l app=web -o name
kubectl get pods --sort-by=.status.startTime
kubectl get pods -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP'

kubectl describe pod <pod>                    # READ THE EVENTS AT THE BOTTOM
kubectl logs <pod>
kubectl logs <pod> -c <container>             # multi-container pods
kubectl logs <pod> --previous                 # the container that just died
kubectl logs -f <pod> --tail=100
kubectl logs -l app=web --all-containers --prefix --tail=20

kubectl exec -it <pod> -- sh
kubectl exec <pod> -c <container> -- env
kubectl cp <pod>:/path/file ./file
kubectl port-forward <pod> 8080:80            # reach a pod from your laptop
kubectl debug -it <pod> --image=busybox --target=<container>   # ephemeral container
```

## Workloads

```bash
kubectl create deployment web --image=nginx --replicas=3
kubectl scale deployment web --replicas=5
kubectl set image deployment/web nginx=nginx:1.27
kubectl set resources deployment/web --containers=nginx --requests=cpu=100m,memory=64Mi

kubectl rollout status deployment/web
kubectl rollout history deployment/web
kubectl rollout undo deployment/web
kubectl rollout undo deployment/web --to-revision=2
kubectl rollout restart deployment/web        # re-create pods without changing spec
kubectl rollout pause deployment/web          # batch several edits, then resume
```

## Services and networking

```bash
kubectl expose deployment web --port=80 --type=NodePort
kubectl get svc,endpoints                     # endpoints is the diagnostic
kubectl get endpointslices

# DNS test
kubectl run t --rm -it --image=busybox:1.36 --restart=Never -- nslookup <svc>.<ns>.svc.cluster.local
# HTTP test from inside the cluster
kubectl run t --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- curl -s http://<svc>
```

## Nodes

```bash
kubectl cordon <node>                         # stop new pods landing
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>                       # allow scheduling again

kubectl taint nodes <node> key=value:NoSchedule
kubectl taint nodes <node> key=value:NoSchedule-        # trailing '-' removes
kubectl label nodes <node> disktype=ssd
kubectl get nodes -o jsonpath='{.items[*].spec.taints}'
```

## Namespaces and context

```bash
kubectl config get-contexts
kubectl config current-context
kubectl config set-context --current --namespace=<ns>
kubectl config view --minify
kubectl api-resources --namespaced=true
```

## RBAC

```bash
kubectl auth can-i <verb> <resource>
kubectl auth can-i --list
kubectl auth can-i get pods --as=jane -n dev
kubectl auth can-i '*' '*' --as=system:serviceaccount:ns:sa

kubectl create serviceaccount reader
kubectl create role pod-reader --verb=get,list,watch --resource=pods
kubectl create rolebinding read --role=pod-reader --serviceaccount=ns:reader
kubectl create clusterrolebinding admin-jane --clusterrole=cluster-admin --user=jane
kubectl describe clusterrole view
```

---

## kubeadm (node)

```bash
kubeadm init --config kubeadm-config.yaml --upload-certs
kubeadm token create --print-join-command      # regenerate an expired join token
kubeadm token list
kubeadm reset -f                               # tear this node down
kubeadm config images list
kubeadm config images pull
kubeadm upgrade plan
kubeadm upgrade apply v1.32.1                  # FIRST control plane
kubeadm upgrade node                           # every other node
kubeadm certs check-expiration                 # certs last 1 year
kubeadm certs renew all
```

## etcd (control-plane node, as root)

```bash
export ETCDCTL_API=3
E="etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

$E endpoint health --write-out=table
$E endpoint status --write-out=table
$E member list --write-out=table
$E get /registry --prefix --keys-only | wc -l

$E snapshot save /opt/etcd-backups/snap.db
etcdutl snapshot status /opt/etcd-backups/snap.db --write-out=table
etcdutl snapshot restore /opt/etcd-backups/snap.db --data-dir=/var/lib/etcd-restored
```

## Node-level (node)

```bash
systemctl status kubelet containerd
journalctl -u kubelet -f
journalctl -u kubelet -n 200 --no-pager
journalctl -u containerd --since '10 min ago'

crictl ps -a                                   # all containers, incl. dead
crictl pods
crictl logs <container-id>
crictl images
crictl inspect <container-id>

swapon --show                                  # must be empty
grep SystemdCgroup /etc/containerd/config.toml # must be true
sysctl net.ipv4.ip_forward                     # must be 1
ls /etc/kubernetes/manifests/                  # static pods (control plane)
```

---

## Output tricks worth knowing

```bash
kubectl get pods -o wide
kubectl get pod <p> -o yaml
kubectl get pod <p> -o jsonpath='{.status.podIP}'
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'
kubectl get deploy -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas'

kubectl get events -A --sort-by=.lastTimestamp | tail -20
kubectl get events --field-selector type=Warning

kubectl explain pod.spec.containers.resources   # built-in API docs
kubectl explain deployment --recursive | less

kubectl diff -f manifest.yaml                   # what would change?
kubectl apply -f manifest.yaml --dry-run=server
kubectl create deployment web --image=nginx --dry-run=client -o yaml > web.yaml
```

## Speed, for exam conditions

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--force --grace-period=0"

k run nginx --image=nginx $do > pod.yaml
k create deploy web --image=nginx $do > deploy.yaml
k delete pod nginx $now

source <(kubectl completion bash)
complete -o default -F __start_kubectl k
```
