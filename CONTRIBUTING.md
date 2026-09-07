# Contributing

Thank you for your interest — but please read this first.

## This repository is not accepting contributions

`k8s-kubeadm-lab` is a personal learning project, published so others can use it
freely under the [Apache License 2.0](LICENSE). It is **not** a collaborative
project, and it is maintained in spare time with no support commitment.

Accordingly:

- **Issues are disabled.**
- **Pull requests are closed automatically.** An automated workflow closes PRs
  opened by anyone other than the repository owner. This is not personal — it is
  how the project's scope is kept manageable.

## What to do instead

### You want to change something

**Fork it.** That is what the licence is for. Apache-2.0 explicitly grants you
the right to use, modify and redistribute this work, including commercially,
provided you keep the licence and notices and state your changes. You do not
need permission and you do not need to ask.

```bash
gh repo fork sameeralam3127/k8s-kubeadm-lab --clone
```

Your fork is yours. Take it in whatever direction is useful to you.

### You found a security problem

See [SECURITY.md](SECURITY.md). Report it privately through
[GitHub's private vulnerability reporting](https://github.com/sameeralam3127/k8s-kubeadm-lab/security/advisories/new),
not in public.

### You found a factual error in the documentation

Kubernetes moves fast and parts of this will go stale. Corrections are welcome
by private report through the same security-advisory link above, or you can
simply fix it in your fork — which is faster for you and equally valid.

### You want help getting the lab working

This repository does not provide support. Start with:

- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — symptom to cause to fix
- `./lab diagnostics` — collects everything relevant into one bundle
- [Kubernetes documentation](https://kubernetes.io/docs/) and the
  [Kubernetes Slack](https://slack.k8s.io/) for questions about Kubernetes itself

---

## If you fork it

A few things worth knowing:

**Check your work.** Everything is linted in CI:

```bash
make lint      # bash -n plus shellcheck across every script
```

**Never commit these.** `.gitignore` blocks them; keep it that way:
`lab.env`, `kubeconfig`, `backups/`, `diagnostics/`, `*.db`, `*.key`, `*.pem`.
An etcd snapshot contains every Secret in your cluster in recoverable form.

**Keep the licence headers.** Every script carries an SPDX identifier. Apache-2.0
requires that you retain the notices and state significant changes you make.

**The style of the docs is deliberate.** Every script explains *why*, not just
*what*, because the point of the project is that a reader understands what each
step did. If you extend it, extend that.

**Adding a lab** means a directory under `labs/` with a `README.md`, a
`manifests/` folder and a `verify.sh` that sources `labs/lib/verify.sh`.

---

## Code of conduct

Interactions in any channel connected to this project are covered by the
[Code of Conduct](CODE_OF_CONDUCT.md).
