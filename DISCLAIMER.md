# Disclaimer

**Read this before running anything in this repository.**

---

## No warranty

This project is provided **"as is", without warranty of any kind**, express or
implied, including but not limited to the warranties of merchantability, fitness
for a particular purpose and non-infringement. In no event shall the author be
liable for any claim, damages or other liability arising from, out of, or in
connection with this software or its use.

This is the plain-language version of the warranty and liability clauses in the
[Apache License 2.0](LICENSE) (sections 7 and 8), which govern.

---

## These scripts are destructive by design

Several commands **permanently destroy data**, and that is their purpose:

| Command | What it destroys |
|---|---|
| `./lab reset <node>` / `reset all` | The entire Kubernetes installation on the target nodes: cluster membership, certificates, CNI state, all running workloads |
| `./lab restore` | **All cluster state created after the snapshot.** The cluster reverts to a point in time |
| `./lab dr-drill` | Deliberately deletes a namespace on your live cluster to simulate a disaster |
| `labs/07-troubleshooting/break-it.sh break …` | Injects real faults: stops kubelets, taints nodes, scales CoreDNS to zero |
| `scripts/node/90-reset-node.sh` | Flushes iptables, deletes `/var/lib/kubelet`, `/var/lib/etcd`, `/etc/kubernetes` |

Scripts also modify the operating system of every node they touch: they disable
swap, edit `/etc/fstab`, load kernel modules, change `sysctl` values, edit
`/etc/hosts`, configure the firewall, and install packages — all as **root**.

**Run this only on virtual machines you created for this purpose and can afford
to delete.** Never point it at a machine that does anything else, and never at
anything you would be upset to lose.

---

## Not for production use

This lab builds an intentionally simplified cluster:

- **A single control plane node.** No high availability. Lose it and, without a
  snapshot, you lose the cluster.
- **No encryption at rest.** Secrets are recoverable from etcd and from any
  snapshot of it.
- **Long-lived `cluster-admin` credentials**, copied to your workstation.
- **No audit logging, no admission policy, no image verification, no
  network segmentation** beyond one optional NetworkPolicy exercise.
- **`local-path` storage** pinned to a single node's disk, with no replication
  and no backup.

Do not use these scripts, these defaults, or these manifests to build anything
real. Their value is that they are simple enough to read and understand
completely — which is the opposite of what production requires.

See [SECURITY.md](SECURITY.md) for the full list of deliberate weaknesses.

---

## You are responsible for your own environment

By running this software you accept that you are responsible for:

- **Authorisation.** Only run it against machines and networks you own or are
  explicitly permitted to modify. Configuring firewalls, scanning ports and
  changing network settings on infrastructure you do not control may be illegal.
- **Your data.** Take your own backups. The etcd tooling here protects cluster
  state, not the contents of your PersistentVolumes, and not anything else on
  the machine.
- **Downloads.** At runtime the scripts fetch and install software from
  `pkgs.k8s.io`, GitHub Releases, Docker Hub and other public sources. Those are
  third-party services, subject to their own terms, availability and integrity.
  See [NOTICE](NOTICE) for the full list.
- **Cost.** If you adapt this to run on cloud infrastructure, you pay for it.

---

## No affiliation

This is an independent personal project. It is **not** affiliated with, endorsed
by, or sponsored by the Cloud Native Computing Foundation, The Linux Foundation,
Kubernetes, Canonical, Oracle, Microsoft, Apple, or any other organisation whose
software it installs or whose trademarks appear in its documentation. All
trademarks are the property of their respective owners.

References to the **CKA** (Certified Kubernetes Administrator) describe the
publicly documented exam curriculum only. This project is not affiliated with or
endorsed by the CNCF or the Linux Foundation, contains no exam content, and does
not guarantee any exam outcome.

---

## Opinions and accuracy

The explanations here reflect the author's understanding at the time of writing.
Kubernetes changes quickly: versions, flags, API groups and best practices in
this repository will drift out of date. **Always check the [official
documentation](https://kubernetes.io/docs/) before relying on anything you read
here**, and especially before applying it anywhere that matters.

Found something wrong? See [SECURITY.md](SECURITY.md) for security issues, or
[CONTRIBUTING.md](CONTRIBUTING.md) for everything else.
