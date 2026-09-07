# Architecture

How the lab is put together, and what happens when you run each command.

![Lab topology](images/architecture.svg)

---

## 1. Physical and logical topology

Two physical machines, one VM each, both **bridged** onto your LAN so the VMs
are peers regardless of which host they sit on. The `lab` CLI runs on either
host and drives both nodes over SSH.

```mermaid
flowchart TB
    subgraph MAC["🖥️  macOS host — UTM or VirtualBox"]
        CLI1["<b>./lab</b><br/>bash CLI"]
        subgraph CP["VM: k8s-cp · 192.168.1.101"]
            API["kube-apiserver :6443"]
            ETCD[("etcd :2379<br/>all cluster state")]
            SCHED["kube-scheduler"]
            CTRL["kube-controller-manager"]
            DNS["CoreDNS"]
            KUBELET1["kubelet + containerd"]
        end
    end

    subgraph WIN["🖥️  Windows host — VirtualBox or Hyper-V"]
        CLI2["<b>lab.ps1</b><br/>PowerShell CLI"]
        subgraph WK["VM: k8s-worker1 · 192.168.1.102"]
            KUBELET2["kubelet :10250 + containerd"]
            PROXY["kube-proxy"]
            PODS["your application pods"]
        end
    end

    CLI1 -. "ssh :22" .-> CP
    CLI1 -. "ssh :22" .-> WK
    CLI2 -. "ssh :22" .-> CP
    CLI2 -. "ssh :22" .-> WK

    KUBELET2 <-- "register + watch :6443" --> API
    API <--> ETCD
    SCHED --> API
    CTRL --> API
    WK <-- "bridged LAN — pod and Service traffic" --> CP

    classDef host fill:#12263f,stroke:#2a4a70,color:#a8c7e8
    classDef vm fill:#0a1826,stroke:#326ce5,color:#cfe4f7
    classDef store fill:#3d2f0d,stroke:#f0c46e,color:#f5dcae
    class MAC,WIN host
    class CP,WK vm
    class ETCD store
```

> **Bridged networking is the one hard requirement.** With NAT, each VM sits
> behind its host on a private `10.0.2.x` network and the two can never reach
> each other — every other failure in this lab traces back to that one.

---

## 2. What `./lab up` actually does

Each stage is also its own command, so you can run them one at a time.

```mermaid
sequenceDiagram
    autonumber
    participant You
    participant CLI as ./lab
    participant CP as k8s-cp
    participant WK as k8s-worker1

    You->>CLI: ./lab up
    CLI->>CLI: read lab.env

    rect rgb(18, 38, 63)
    Note over CLI,WK: preflight — read-only, changes nothing
    CLI->>CP: 01-preflight.sh (cpu, ram, disk, swap, ports, clock, peers)
    CLI->>WK: 01-preflight.sh
    WK-->>CLI: PASS / FAIL per check
    end

    rect rgb(18, 38, 63)
    Note over CLI,WK: prep — runs on every node
    CLI->>CP: 02 swap off · sysctl · modules · firewall
    CLI->>CP: 03 containerd + SystemdCgroup=true
    CLI->>CP: 04 kubeadm, kubelet, kubectl (pinned, held)
    CLI->>WK: 02, 03, 04 (identical)
    end

    rect rgb(10, 40, 30)
    Note over CLI,CP: control plane
    CLI->>CP: 10-init-control-plane.sh
    CP->>CP: kubeadm init --config
    CP-->>CLI: join command + admin.conf
    CLI->>CP: 11-install-cni.sh (Calico / Flannel / Cilium)
    Note right of CP: node stays NotReady<br/>until the CNI is up
    CLI->>CP: 13-install-addons.sh
    end

    rect rgb(10, 40, 30)
    Note over CLI,WK: join
    CLI->>CP: kubeadm token create --print-join-command
    CP-->>CLI: fresh 24h token
    CLI->>WK: 12-join-worker.sh JOIN_CMD=...
    WK->>CP: kubeadm join :6443
    CP-->>WK: certs + kubelet config
    end

    CLI->>CP: 20-verify-cluster.sh
    CP->>CP: deploy → schedule → DNS → Service → HTTP 200
    CP-->>You: cluster healthy
```

---

## 3. Where a pod's traffic goes

Understanding this one picture removes most Service confusion.

```mermaid
flowchart LR
    USER(["you<br/>curl node:30080"])
    subgraph NODE["any node in the cluster"]
        NP["kube-proxy<br/>NodePort 30080"]
        IPT{"iptables / IPVS<br/>rules"}
    end
    SVC["Service<br/>ClusterIP 10.96.x.x"]
    EP["Endpoints<br/><i>ready pod IPs only</i>"]
    P1["pod A<br/>192.168.x.1"]
    P2["pod B<br/>192.168.x.2"]
    P3["pod C — <b>not Ready</b>"]

    USER --> NP --> IPT
    SVC -.->|"label selector"| EP
    IPT -->|"DNAT to a random endpoint"| EP
    EP --> P1
    EP --> P2
    P3 -. "excluded: failing readinessProbe" .-> EP

    classDef bad fill:#3d1414,stroke:#e8888a,color:#f3c3c4
    classDef good fill:#0a2818,stroke:#7fd88f,color:#b9ebc6
    class P3 bad
    class P1,P2 good
```

**Why `kubectl get endpoints` is always the first Service command:** it splits
the problem in half. Empty means the selector matches nothing *or* no pod is
`Ready`. Populated means the problem is the port, a NetworkPolicy, or the app.

---

## 4. etcd backup and restore

The restore sequence is rigid. Each step exists because skipping it corrupts
something.

```mermaid
flowchart TD
    START(["./lab restore"]) --> VERIFY{"checksum<br/>matches?"}
    VERIFY -->|no| ABORT([abort — snapshot is corrupt])
    VERIFY -->|yes| S1["<b>1.</b> etcdutl snapshot restore<br/>into a <i>new</i> data dir"]

    S1 --> S2["<b>2.</b> move static pod manifests out of<br/>/etc/kubernetes/manifests"]
    S2 --> WAIT["kubelet sees them vanish<br/>and stops etcd + apiserver"]
    WAIT --> S3["<b>3.</b> mv /var/lib/etcd → .pre-restore<br/><i>rollback point</i>"]
    S3 --> S4["<b>4.</b> edit etcd.yaml"]

    S4 --> F1["--data-dir=/var/lib/etcd-restored"]
    S4 --> F2["hostPath → path: /var/lib/etcd-restored"]
    F1 --> S5
    F2 --> S5

    S5["<b>5.</b> move manifests back<br/>restart kubelet"] --> S6{"<b>6.</b> API server<br/>returns?"}
    S6 -->|yes| DONE(["cluster restored to<br/>the snapshot's point in time"])
    S6 -->|no| ROLL(["roll back:<br/>repoint etcd.yaml, restore .pre-restore dir"])

    classDef danger fill:#3d1414,stroke:#e8888a,color:#f3c3c4
    classDef ok fill:#0a2818,stroke:#7fd88f,color:#b9ebc6
    classDef key fill:#3d2f0d,stroke:#f0c46e,color:#f5dcae
    class ABORT,ROLL danger
    class DONE ok
    class F1,F2 key
```

> **Steps 4a and 4b must both happen.** Changing only `--data-dir` and leaving
> the `hostPath` volume pointing at `/var/lib/etcd` gives you a control plane
> that starts cleanly against an empty directory — a cluster that looks restored
> and is actually empty. This is the single most common restore failure.

### What a snapshot does and does not cover

```mermaid
flowchart LR
    subgraph IN["✅ in the snapshot"]
        A["Namespaces, Deployments, Pod specs"]
        B["Secrets, ConfigMaps, ServiceAccounts"]
        C["RBAC rules, CRDs, custom resources"]
        D["Service and Ingress definitions"]
    end
    subgraph OUT["❌ not in the snapshot"]
        E["PersistentVolume <b>contents</b>"]
        F["Container images on nodes"]
        G["Anything created after it was taken"]
        H["Node OS state, kubelet config on disk"]
    end
    classDef yes fill:#0a2818,stroke:#7fd88f,color:#b9ebc6
    classDef no fill:#3d1414,stroke:#e8888a,color:#f3c3c4
    class IN,A,B,C,D yes
    class OUT,E,F,G,H no
```

Because Secrets are stored unencrypted by default, **a snapshot is a file
containing every credential in your cluster.** See [SECURITY.md](../SECURITY.md).

---

## 5. Repository structure

```mermaid
flowchart TD
    ENV["<b>lab.env</b><br/>the only file you edit"]
    ENV --> BASH["<b>./lab</b><br/>bash CLI"]
    ENV --> PS["<b>windows/lab.ps1</b><br/>PowerShell CLI"]

    BASH --> SYNC["scp scripts/ to each node<br/>over SSH"]
    PS --> SYNC

    SYNC --> N1["<b>01–04</b> preflight &amp; prep<br/><i>every node</i>"]
    SYNC --> N2["<b>10–13</b> control plane<br/><i>k8s-cp only</i>"]
    SYNC --> N3["<b>20</b> verify · <b>99</b> diagnostics"]
    SYNC --> N4["<b>30–31</b> etcd backup / restore"]
    SYNC --> N5["<b>90</b> reset"]

    LABS["<b>labs/01–07</b><br/>exercises + verify.sh"] -.->|kubectl| N2
    DOCS["<b>docs/</b><br/>manual setup, cheatsheet,<br/>troubleshooting, Windows"]

    classDef cfg fill:#3d2f0d,stroke:#f0c46e,color:#f5dcae
    classDef cli fill:#0a1826,stroke:#5aa9e6,color:#cfe4f7
    classDef danger fill:#3d1414,stroke:#e8888a,color:#f3c3c4
    class ENV cfg
    class BASH,PS cli
    class N5 danger
```

Every node script is **idempotent**: it detects what is already done, prints
`[skip]`, and moves on. That is what lets `./lab up` double as a repair tool.

---

## 6. Design decisions

| Decision | Why |
|---|---|
| **Everything over SSH; nothing runs on the nodes permanently** | The nodes stay generic Ubuntu. Rebuild one and you lose nothing but time |
| **One config file, two CLIs** | A Mac user and a Windows user drive an identical cluster from the same `lab.env` |
| **Idempotent scripts** | Re-running is always safe, so recovery and building are the same operation |
| **Versions pinned in `lab.env`** | A lab that silently drifts is a lab that stops reproducing |
| **`kubeadm init` from a config file, not flags** | Config files are what real clusters use, and what upgrades and troubleshooting make you edit |
| **Connection details read from the live etcd manifest** | After a restore the data dir has changed; hard-coded paths would break the next backup |
| **`bash -n` clean under bash 3.2** | macOS still ships bash 3.2, so no `mapfile`, no `readarray` |
| **Firewall opened, not disabled** | Teaching people to `ufw disable` is a bad habit; the correct ports are documented and applied |
| **Every script explains *why*** | The point is that you understand what each step did, not that it worked |
