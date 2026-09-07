# Security Policy

## Scope: this is a teaching lab, not production software

`k8s-kubeadm-lab` builds a **disposable Kubernetes cluster on virtual machines
you own, on your own private network**, for learning and exam practice. Its
threat model assumes a trusted home or office LAN and VMs you can destroy and
rebuild at will.

**It is not hardened, and it is not intended to be.** Several deliberate choices
prioritise learning over defence. They are listed below so you can make an
informed decision, and so nobody copies them into a real cluster by accident.

---

## Deliberate weaknesses, and why they exist

| Choice | Where | Why it is here | Why it is unsafe elsewhere |
|---|---|---|---|
| `admin.conf` copied to your user and fetched to your host | `10-init-control-plane.sh`, `./lab kubeconfig` | You need `kubectl` to work immediately | `admin.conf` is **`cluster-admin`** — an unrestricted credential with no expiry short of its certificate. Real clusters issue scoped, short-lived credentials per person |
| `--kubelet-insecure-tls` on metrics-server | `13-install-addons.sh` | kubeadm issues self-signed kubelet serving certs; metrics-server rejects them | Disables verification of the kubelet's identity. Production fixes the certs (`serverTLSBootstrap`), not the client |
| `StrictHostKeyChecking=accept-new` | `lab`, `windows/lab.ps1` | You would otherwise confirm a fingerprint on every fresh VM | Trusts the host key seen on first contact. A machine-in-the-middle present at that moment is trusted permanently |
| `curl … \| bash` to install Helm | `13-install-addons.sh` | It is the upstream project's own documented installer | Executes remote code with no signature check. Prefer a package manager or a checksum-verified release in production |
| `ASSUME_YES=1` bypasses every confirmation | throughout | Needed for `./lab up` and CI to run unattended | Removes the last guard before destructive operations such as `reset` and `restore` |
| Cluster peers allowed unrestricted access to each other | `02-prep-node.sh` | Pod and Service traffic uses no fixed port range | Correct for a cluster, but it means compromising one node gives full network reach to the others |
| Secrets stored unencrypted in etcd | default kubeadm behaviour | It is what kubeadm does out of the box | Anyone who can read the etcd data directory, **or a snapshot of it**, can read every Secret. Production enables [encryption at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) |
| No audit logging, no Pod Security admission, no image signing | everywhere | Out of scope for a two-node teaching lab | All three are baseline requirements for a real cluster |

The lab defaults to **enabling** the node firewall and opening only the ports
Kubernetes needs (`FIREWALL_MODE=open-ports`). `FIREWALL_MODE=disable` exists
because some setups need it, but it is not the default.

---

## Things that will leak if you are careless

### etcd snapshots contain every Secret in your cluster

A snapshot is a complete copy of the datastore. Because kubeadm does not encrypt
Secrets at rest, anyone holding a snapshot can recover them in plaintext:

```bash
etcdctl get /registry/secrets/default/my-secret | strings
```

`30-etcd-backup.sh` writes snapshots `0600` inside a `0700` directory for this
reason. **Treat a snapshot exactly as you would treat the passwords inside it.**
Never attach one to an issue, never commit one, never put one in cloud storage
you have not encrypted.

### Files that must never be committed

`.gitignore` blocks all of these, and you should not weaken it:

| Path | Contains |
|---|---|
| `lab.env` | your node IPs, usernames, SSH key paths |
| `kubeconfig`, `*.kubeconfig` | **cluster-admin credentials** |
| `backups/`, `*.db` | etcd snapshots — every Secret in the cluster |
| `diagnostics/`, `diagnostics-*.tar.gz` | kubelet journals, pod specs, cluster events, node configuration |
| `*.key`, `*.pem`, `*.crt`, `id_rsa*` | private keys and certificates |

Before you push, always:

```bash
git status --short          # nothing unexpected?
git check-ignore -v lab.env kubeconfig backups diagnostics
```

### Diagnostic bundles are not safe to share as-is

`./lab diagnostics` collects kubelet journals, every pod manifest, cluster events
and node configuration. It does not deliberately collect Secret *values*, but pod
specs can embed configuration you would rather not publish. **Open the tarball
and read it before sending it anywhere.**

---

## Reporting a vulnerability

If you find a security problem in **this repository's scripts** — for example a
command injection in the CLI, a path traversal, a permissions mistake, or
credentials being written somewhere world-readable — please report it privately.

**Do not open a public issue.** Public issues are disabled on this repository.

- Use GitHub's [private vulnerability reporting](https://github.com/sameeralam3127/k8s-kubeadm-lab/security/advisories/new)
  (Security tab → Report a vulnerability)

Please include the script and line, what an attacker could achieve, and the
steps to reproduce. This is a personal project maintained in spare time:
expect an acknowledgement within about 7 days and a fix when time allows.

### Out of scope

- The deliberate weaknesses listed above — they are documented, not defects
- Vulnerabilities in Kubernetes, containerd, etcd, Calico, Helm or any other
  upstream project. Report those to the projects themselves; Kubernetes uses
  <https://kubernetes.io/docs/reference/issues-security/security/>
- Anything requiring an attacker to already have root on your nodes or write
  access to your `lab.env`
- Findings from an automated scanner with no demonstrated impact

---

## If you want to make the lab more like production

These are good exercises once the labs are finished:

1. **Encrypt Secrets at rest** — add an `EncryptionConfiguration` to the API
   server, then re-run Lab 05 and confirm the Secret is no longer readable in
   the snapshot.
2. **Replace `admin.conf` usage** with a per-user client certificate and a
   scoped `ClusterRole` — Lab 04 already builds the certificate half.
3. **Turn on Pod Security admission** at `restricted` and watch which lab
   manifests stop working, and why.
4. **Enable audit logging** and read what a `kubectl delete namespace` actually
   looks like from the API server's side.
5. **Rotate the certificates before they expire**, rather than after
   (`kubeadm certs check-expiration`).

## Supported versions

Only the `main` branch is supported. The Kubernetes, CNI and add-on versions
this lab installs are pinned in `lab.env.example` and updated periodically;
older pins are not backported.
