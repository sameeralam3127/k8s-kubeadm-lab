#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# break-it.sh - introduce realistic faults into the lab cluster, then help you
# diagnose and repair them.
#
#   ./break-it.sh list
#   ./break-it.sh break 3
#   ./break-it.sh hint 3
#   ./break-it.sh solution 3
#   ./break-it.sh fix 3
#   ./break-it.sh fix all
#
# Scenarios 1-5 and 7-8 are cluster-side and run from anywhere with kubectl.
# Scenario 6 stops a kubelet and needs SSH, so run it via ./lab from your host.
# =============================================================================
set -uo pipefail

NS=tshoot
K="kubectl -n ${NS}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  V_BOLD=$'\033[1m'; V_DIM=$'\033[2m'; V_RESET=$'\033[0m'
else
  V_BOLD=''; V_DIM=''; V_RESET=''
fi

banner() {
  echo
  echo "${V_BOLD}$1${V_RESET}"
  printf '%s%s%s\n' "$V_DIM" "$(printf '%.0s=' $(seq 1 ${#1}))" "$V_RESET"
}

# list, hint and solution are pure documentation and must work with no cluster.
# break and fix touch the cluster, so those check for one first.
need_cluster() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "kubectl not found. Run this on the control plane, or fetch a kubeconfig:"
    echo "    ./lab kubeconfig && export KUBECONFIG=\$PWD/kubeconfig"
    exit 1
  }
  if [ -z "${KUBECONFIG:-}" ]; then
    for c in "$HOME/.kube/config" /etc/kubernetes/admin.conf \
             "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/kubeconfig"; do
      [ -r "$c" ] && { export KUBECONFIG="$c"; break; }
    done
  fi
  kubectl version -o json >/dev/null 2>&1 || {
    echo "kubectl cannot reach the API server (KUBECONFIG=${KUBECONFIG:-unset})."
    exit 1
  }
}

ensure_ns() { kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null; }

# ---------------------------------------------------------------------------
cmd_list() {
  banner "Troubleshooting scenarios"
  cat <<'EOF'
   1  Pod stuck in Pending             scheduler cannot place it
   2  ImagePullBackOff                 the image does not exist
   3  CrashLoopBackOff                 the container starts then exits
   4  Service with no endpoints        selector does not match pod labels
   5  Pod cannot start: missing config  a referenced ConfigMap key is absent
   6  Node NotReady                    kubelet stopped (needs SSH - see below)
   7  DNS resolution failing           CoreDNS scaled to zero
   8  Pods evicted by a node taint     an unexpected NoExecute taint

  Usage:
     ./break-it.sh break <n>       introduce the fault
     ./break-it.sh hint <n>        a nudge in the right direction
     ./break-it.sh solution <n>    what it was and how to fix it
     ./break-it.sh fix <n>         repair it
     ./break-it.sh fix all         repair everything and clean up

  Scenario 6 stops a service on a worker node. Run it from your host:
     ./lab run worker1 'sudo systemctl stop kubelet'      # break
     ./lab run worker1 'sudo systemctl start kubelet'     # fix
EOF
  echo
}

# --- 1: Pending -------------------------------------------------------------
break_1() {
  ensure_ns
  $K delete deploy pending-app --ignore-not-found >/dev/null 2>&1
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: pending-app, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: pending-app } }
  template:
    metadata: { labels: { app: pending-app } }
    spec:
      containers:
        - name: app
          image: nginx:stable-alpine
          resources:
            requests:
              cpu: "64"          # no lab node has 64 cores
              memory: "256Gi"
EOF
  echo "Broken. Investigate:  kubectl -n ${NS} get pods"
}
hint_1() {
  echo "The pod is Pending, which means the SCHEDULER could not place it."
  echo "The scheduler always explains itself. Where does it write that explanation?"
  echo "  kubectl -n ${NS} describe pod -l app=pending-app | tail -20"
}
solution_1() {
  cat <<EOF
CAUSE
  The pod requests 64 CPUs and 256Gi of memory. No node in your lab has that,
  so the scheduler has nowhere to put it and leaves the pod Pending forever.

DIAGNOSIS
  kubectl -n ${NS} describe pod -l app=pending-app | tail -20
  -> Events: "0/2 nodes are available: 2 Insufficient cpu, 2 Insufficient memory."

  Compare what is asked for against what exists:
  kubectl describe nodes | grep -A6 'Allocatable'

FIX
  kubectl -n ${NS} set resources deploy/pending-app --containers=app \\
    --requests=cpu=100m,memory=64Mi

NOTE
  Pending has other causes with the same symptom and different events: node
  taints the pod does not tolerate, an unbound PVC, or nodeSelector/affinity
  matching nothing. The Events block distinguishes them - always read it.
EOF
}
fix_1() { $K set resources deploy/pending-app --containers=app --requests=cpu=100m,memory=64Mi >/dev/null 2>&1; echo "Fixed."; }

# --- 2: ImagePullBackOff ----------------------------------------------------
break_2() {
  ensure_ns
  $K delete deploy badimage-app --ignore-not-found >/dev/null 2>&1
  $K create deployment badimage-app --image=nginx:1.99-does-not-exist >/dev/null
  echo "Broken. Investigate:  kubectl -n ${NS} get pods"
}
hint_2() {
  echo "The pod never starts, so there are no application logs to read."
  echo "Something failed BEFORE the container ran. Which command shows you that?"
  echo "  kubectl -n ${NS} describe pod -l app=badimage-app | tail -15"
}
solution_2() {
  cat <<EOF
CAUSE
  The image tag nginx:1.99-does-not-exist is not in the registry.

DIAGNOSIS
  kubectl -n ${NS} get pods
  -> STATUS: ImagePullBackOff (or ErrImagePull on the first attempts)

  kubectl -n ${NS} describe pod -l app=badimage-app | tail -15
  -> Events: Failed to pull image ...: not found

  kubectl -n ${NS} logs -l app=badimage-app
  -> "container ... is waiting to start" - there are no logs, because there is
     no container. This is why 'describe' comes before 'logs'.

FIX
  kubectl -n ${NS} set image deploy/badimage-app nginx=nginx:stable-alpine

REAL-WORLD VARIANTS
  Same symptom, different causes: a private registry with no imagePullSecret,
  a rate-limited Docker Hub pull, or an amd64-only image on an arm64 node. The
  Events text distinguishes them - read the exact message, not just the status.
EOF
}
fix_2() { $K set image deploy/badimage-app nginx=nginx:stable-alpine >/dev/null 2>&1; echo "Fixed."; }

# --- 3: CrashLoopBackOff ----------------------------------------------------
break_3() {
  ensure_ns
  $K delete deploy crashing-app --ignore-not-found >/dev/null 2>&1
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: crashing-app, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: crashing-app } }
  template:
    metadata: { labels: { app: crashing-app } }
    spec:
      containers:
        - name: app
          image: busybox:1.36
          command:
            - /bin/sh
            - -c
            - 'echo "starting up..."; echo "FATAL: cannot connect to database at db:5432" >&2; exit 1'
          resources:
            requests: { cpu: 10m, memory: 16Mi }
EOF
  echo "Broken. Investigate:  kubectl -n ${NS} get pods"
}
hint_3() {
  echo "The container starts, dies, and restarts - so by the time you look, the"
  echo "CURRENT container has just begun and has nothing to say."
  echo "Which flag shows you the logs of the container that already died?"
}
solution_3() {
  cat <<EOF
CAUSE
  The container's command writes an error to stderr and exits 1. Kubernetes
  restarts it, with exponential backoff, forever.

DIAGNOSIS
  kubectl -n ${NS} get pods
  -> STATUS CrashLoopBackOff, RESTARTS climbing

  kubectl -n ${NS} logs -l app=crashing-app --previous
  -> "FATAL: cannot connect to database at db:5432"
     --previous is the key. Without it you see the current (just-started)
     container, which has not failed yet.

  kubectl -n ${NS} describe pod -l app=crashing-app | grep -A6 'Last State'
  -> Last State: Terminated, Reason: Error, Exit Code: 1

READ THE EXIT CODE
  1        application error - read the logs
  137      SIGKILL - almost always OOMKilled; check limits and 'Last State'
  143      SIGTERM - shut down on request
  0 + loop restartPolicy: Always on a job-like container that legitimately exits

FIX
  In reality: fix the app or its config. Here, make it stay up:
  kubectl -n ${NS} patch deploy crashing-app --type=json -p \\
    '[{"op":"replace","path":"/spec/template/spec/containers/0/command",
       "value":["/bin/sh","-c","echo started; sleep infinity"]}]'
EOF
}
fix_3() {
  $K patch deploy crashing-app --type=json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/command","value":["/bin/sh","-c","echo started; sleep infinity"]}]' >/dev/null 2>&1
  echo "Fixed."
}

# --- 4: Service with no endpoints -------------------------------------------
break_4() {
  ensure_ns
  $K delete deploy tshoot-app --ignore-not-found >/dev/null 2>&1
  $K delete svc broken-svc --ignore-not-found >/dev/null 2>&1
  $K create deployment tshoot-app --image=nginx:stable-alpine --replicas=2 >/dev/null
  $K rollout status deploy/tshoot-app --timeout=120s >/dev/null 2>&1
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata: { name: broken-svc, namespace: ${NS} }
spec:
  selector:
    app: tshoot-application     # the pods are labelled 'tshoot-app'
  ports:
    - port: 80
      targetPort: 80
EOF
  echo "Broken. The pods are healthy but the Service is unreachable."
  echo "Investigate:  kubectl -n ${NS} get svc,endpoints"
}
hint_4() {
  echo "Every pod is Running and Ready, yet nothing can reach the Service."
  echo "A Service is a selector plus a VIP. What does it actually resolve to?"
  echo "  kubectl -n ${NS} get endpoints broken-svc"
}
solution_4() {
  cat <<EOF
CAUSE
  The Service selector is app=tshoot-application; the pods are labelled
  app=tshoot-app. Zero pods match, so the endpoints list is empty and the
  Service VIP forwards to nothing.

DIAGNOSIS
  kubectl -n ${NS} get endpoints broken-svc
  -> ENDPOINTS: <none>          <-- the whole diagnosis, in one line

  Then compare the two sides:
  kubectl -n ${NS} get svc broken-svc -o jsonpath='{.spec.selector}'
  kubectl -n ${NS} get pods --show-labels

FIX
  kubectl -n ${NS} patch svc broken-svc -p '{"spec":{"selector":{"app":"tshoot-app"}}}'
  kubectl -n ${NS} get endpoints broken-svc     # pod IPs appear

THE RULE
  Empty endpoints  -> selector mismatch, or no pod is READY (a failing
                      readiness probe removes a pod from endpoints).
  Populated but still unreachable -> wrong targetPort, a NetworkPolicy, or
                      the app not listening on the port it claims.
  This one check splits the problem in half every time.
EOF
}
fix_4() { $K patch svc broken-svc -p '{"spec":{"selector":{"app":"tshoot-app"}}}' >/dev/null 2>&1; echo "Fixed."; }

# --- 5: Missing ConfigMap key -----------------------------------------------
break_5() {
  ensure_ns
  $K delete deploy config-app --ignore-not-found >/dev/null 2>&1
  $K delete configmap app-settings --ignore-not-found >/dev/null 2>&1
  $K create configmap app-settings --from-literal=log.level=debug >/dev/null
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: config-app, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: config-app } }
  template:
    metadata: { labels: { app: config-app } }
    spec:
      containers:
        - name: app
          image: busybox:1.36
          command: ["sleep", "infinity"]
          env:
            - name: DATABASE_URL
              valueFrom:
                configMapKeyRef:
                  name: app-settings
                  key: database.url     # this key does not exist
          resources:
            requests: { cpu: 10m, memory: 16Mi }
EOF
  echo "Broken. Investigate:  kubectl -n ${NS} get pods"
}
hint_5() {
  echo "The pod is stuck in CreateContainerConfigError - it never reached the"
  echo "point of running an image. Something the pod spec REFERENCES is missing."
  echo "  kubectl -n ${NS} describe pod -l app=config-app | tail -10"
}
solution_5() {
  cat <<EOF
CAUSE
  The pod asks for key 'database.url' from ConfigMap 'app-settings', which only
  contains 'log.level'. The kubelet cannot build the container's environment,
  so the container is never created.

DIAGNOSIS
  kubectl -n ${NS} get pods
  -> STATUS: CreateContainerConfigError

  kubectl -n ${NS} describe pod -l app=config-app | tail -10
  -> Events: Error: couldn't find key database.url in ConfigMap ${NS}/app-settings
     The error names the exact missing key. Read it literally.

  kubectl -n ${NS} get configmap app-settings -o yaml

FIX (either side works)
  Add the key:
    kubectl -n ${NS} patch configmap app-settings \\
      --type merge -p '{"data":{"database.url":"postgres://db:5432/app"}}'
    kubectl -n ${NS} rollout restart deploy/config-app

  Or make the reference optional, so a missing key is not fatal:
    add  optional: true  under configMapKeyRef

SAME SHAPE, OTHER CAUSES
  A missing Secret, a missing ConfigMap entirely, or an unmountable volume all
  produce CreateContainerConfigError or CreateContainerError.
EOF
}
fix_5() {
  $K patch configmap app-settings --type merge -p '{"data":{"database.url":"postgres://db:5432/app"}}' >/dev/null 2>&1
  $K rollout restart deploy/config-app >/dev/null 2>&1
  echo "Fixed."
}

# --- 6: Node NotReady -------------------------------------------------------
break_6() {
  cat <<'EOF'
This scenario stops the kubelet on a worker, which needs SSH. From your host:

    ./lab run worker1 'sudo systemctl stop kubelet'

Then watch the node go NotReady (it takes ~40s for the lease to expire):

    kubectl get nodes -w
EOF
}
hint_6() {
  echo "kubectl can tell you a node is NotReady, but not why - the component that"
  echo "reports node health is the very thing that stopped talking."
  echo "You have to go to the node itself:"
  echo "  ./lab run worker1 'sudo systemctl status kubelet'"
  echo "  ./lab run worker1 'sudo journalctl -u kubelet -n 50 --no-pager'"
}
solution_6() {
  cat <<'EOF'
CAUSE
  The kubelet is the node's agent. It renews a Lease object every few seconds;
  when those stop, the control plane marks the node NotReady after ~40s. Pods on
  that node are then evicted after the toleration timeout (5 minutes by default).

DIAGNOSIS
  kubectl get nodes
  -> k8s-worker1  NotReady

  kubectl describe node k8s-worker1 | grep -A8 Conditions
  -> Ready: Unknown, "Kubelet stopped posting node status."

  Then get onto the node - the answer is never in the API for this class of fault:
  ./lab run worker1 'sudo systemctl status kubelet'
  ./lab run worker1 'sudo journalctl -u kubelet -n 100 --no-pager'

FIX
  ./lab run worker1 'sudo systemctl start kubelet'
  kubectl get nodes -w        # Ready again within ~30s

REAL CAUSES THAT LOOK IDENTICAL
  - swap got re-enabled (kubelet refuses to start)
  - containerd died, so the kubelet cannot create anything
  - the node's disk filled up
  - clock skew broke TLS to the API server
  - expired kubelet certificates
  Each one is visible in `journalctl -u kubelet`. That is always the next step.
EOF
}
fix_6() {
  echo "Run from your host:"
  echo "    ./lab run worker1 'sudo systemctl start kubelet'"
}

# --- 7: DNS failure ---------------------------------------------------------
break_7() {
  kubectl -n kube-system scale deploy coredns --replicas=0 >/dev/null
  echo "Broken. CoreDNS scaled to 0."
  echo "Investigate:  kubectl run t --rm -i --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default"
}
hint_7() {
  echo "Pods still run, Services still have endpoints, but nothing can find"
  echo "anything by name. Which cluster component answers DNS queries?"
  echo "  kubectl -n kube-system get pods -l k8s-app=kube-dns"
}
solution_7() {
  cat <<'EOF'
CAUSE
  CoreDNS is scaled to zero replicas, so nothing answers cluster DNS.

DIAGNOSIS
  Confirm the symptom:
  kubectl run t --rm -i --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default
  -> "server can't find kubernetes.default" / connection timed out

  Follow the chain from the client outwards:
  1. kubectl run t --rm -i --restart=Never --image=busybox:1.36 -- cat /etc/resolv.conf
     -> nameserver 10.96.0.10 (the kube-dns Service ClusterIP)
  2. kubectl -n kube-system get svc kube-dns          # the Service exists
  3. kubectl -n kube-system get endpoints kube-dns    # <none>  <-- the answer
  4. kubectl -n kube-system get pods -l k8s-app=kube-dns   # no pods at all

FIX
  kubectl -n kube-system scale deploy coredns --replicas=2
  kubectl -n kube-system rollout status deploy/coredns

WHEN IT IS NOT THIS SIMPLE
  If CoreDNS pods exist but DNS still fails, check in this order:
  - kubectl -n kube-system logs -l k8s-app=kube-dns     (loop detected? upstream unreachable?)
  - is the CNI healthy? no pod networking means no DNS
  - kubectl -n kube-system get cm coredns -o yaml       (broken Corefile)
  - NetworkPolicy blocking egress to kube-system
EOF
}
fix_7() {
  kubectl -n kube-system scale deploy coredns --replicas=2 >/dev/null
  kubectl -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null 2>&1
  echo "Fixed."
}

# --- 8: Unexpected taint ----------------------------------------------------
break_8() {
  ensure_ns
  local node
  node="$(kubectl get nodes -o name -l '!node-role.kubernetes.io/control-plane' | head -1 | cut -d/ -f2)"
  [ -n "$node" ] || node="$(kubectl get nodes -o name | head -1 | cut -d/ -f2)"
  $K delete deploy taint-victim --ignore-not-found >/dev/null 2>&1
  $K create deployment taint-victim --image=nginx:stable-alpine --replicas=3 >/dev/null
  $K rollout status deploy/taint-victim --timeout=120s >/dev/null 2>&1
  kubectl taint nodes "$node" lab.example.com/maintenance=true:NoExecute --overwrite >/dev/null
  echo "Broken. Tainted node '${node}' with NoExecute."
  echo "Investigate:  kubectl -n ${NS} get pods -o wide"
}
hint_8() {
  echo "Pods that were happily running have been evicted, and new ones will not"
  echo "schedule onto that node. Nothing about the POD changed - so what changed?"
  echo "  kubectl describe node <name> | grep -i taint"
}
solution_8() {
  cat <<EOF
CAUSE
  The node carries a taint lab.example.com/maintenance=true:NoExecute. Taints
  repel pods that do not tolerate them:
    NoSchedule       - no NEW pods land here
    PreferNoSchedule - avoid if possible
    NoExecute        - no new pods AND evict the ones already running

DIAGNOSIS
  kubectl -n ${NS} get pods -o wide
  -> pods gone from that node; possibly Pending if nowhere else fits

  kubectl describe node <name> | grep -i -A3 taint
  -> Taints: lab.example.com/maintenance=true:NoExecute

  kubectl -n ${NS} describe pod <pending-pod> | tail -10
  -> Events: "1 node(s) had untolerated taint {lab.example.com/maintenance: true}"

FIX (choose based on intent)
  Remove the taint - note the trailing minus:
    kubectl taint nodes <name> lab.example.com/maintenance=true:NoExecute-

  Or tolerate it, if the pod genuinely should run during maintenance:
    tolerations:
      - key: lab.example.com/maintenance
        operator: Equal
        value: "true"
        effect: NoExecute

TAINTS YOU WILL MEET IN THE WILD
  node-role.kubernetes.io/control-plane:NoSchedule   (why pods avoid the CP)
  node.kubernetes.io/not-ready:NoExecute             (added automatically)
  node.kubernetes.io/disk-pressure:NoSchedule        (kubelet, on low disk)
  node.kubernetes.io/memory-pressure:NoSchedule
  node.kubernetes.io/unschedulable:NoSchedule        (what 'kubectl cordon' adds)
EOF
}
fix_8() {
  local n
  for n in $(kubectl get nodes -o name | cut -d/ -f2); do
    kubectl taint nodes "$n" lab.example.com/maintenance=true:NoExecute- >/dev/null 2>&1
  done
  echo "Fixed."
}

fix_all() {
  banner "Repairing every scenario"
  for i in 1 2 3 4 5 7 8; do
    printf '  scenario %d: ' "$i"
    "fix_${i}"
  done
  echo
  echo "  Scenario 6, if you ran it:  ./lab run worker1 'sudo systemctl start kubelet'"
  echo
  echo "  Remove the practice namespace with:  kubectl delete ns ${NS}"
}

# ---------------------------------------------------------------------------
ACTION="${1:-list}"
N="${2:-}"

case "$ACTION" in
  list) cmd_list ;;
  break|hint|solution|fix)
    # Scenario 6 is SSH-driven and only prints instructions, so it needs nothing.
    case "$ACTION" in
      break|fix) [ "$N" = "6" ] || need_cluster ;;
    esac
    if [ "$ACTION" = "fix" ] && [ "$N" = "all" ]; then fix_all; exit 0; fi
    case "$N" in
      1|2|3|4|5|6|7|8) ;;
      *) echo "Usage: $0 ${ACTION} <1-8>   (or: $0 fix all)"; exit 1 ;;
    esac
    banner "Scenario ${N} - ${ACTION}"
    "${ACTION}_${N}"
    echo
    ;;
  *) cmd_list; exit 1 ;;
esac
