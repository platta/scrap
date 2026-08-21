# Understanding SCRAP

*A ten-to-fifteen-minute walkthrough of what SCRAP actually is, layer by layer.*

This document exists because SCRAP is not trying to hide Kubernetes from you, and a good way to
prove that is to just tell you, plainly, what's underneath. By the end of this you should be able
to point at any part of a running SCRAP install and know which real, independent piece of software
is doing the work, why it was chosen, and where to go read its own documentation.

**The one sentence to keep in mind throughout:** SCRAP abstracts *decisions*, not *technologies*.
Every layer below is a decision about which mature tool solves a specific problem, wired to the
next layer by a plain Kubernetes contract — never a SCRAP-invented format standing in the way.

## The core idea, restated once

Build the platform once. Deploy arbitrary applications into it using well-defined integration
patterns. If the hardware dies, rebuild the platform and restore the applications from durable,
tested backups. Everything below is in service of that idea, and every choice is judged against
one question: *does this make the platform more durable and more legible, or just more familiar?*

---

## Layer 1 — the Linux host

**What it does:** boots, provides a kernel with cgroup v2 and the usual container-runtime
prerequisites, and holds one disk with enough room for container images and your data.

**Why SCRAP chose "a normal Linux host":** because that's the least you can ask a self-hoster to
provide. SCRAP does not require a second machine, a hypervisor, or a specific distribution — just a
supported kernel and a stable way for clients to reach it. It also does **not** assume it owns the
whole machine: SCRAP claims specific ports, a specific storage path, and a specific pod/service
network range, and nothing else. Other things can run on the same box.

**Contract to the next layer:** a machine k3s can install onto — cgroup v2, enough disk, and (once,
at install time) internet access to pull the k3s binary and container images.

**What's actually happening:** nothing SCRAP-specific yet. This is just Debian, or Ubuntu, or
whatever supported distribution you picked, doing what it always does.

**Go deeper:** your distribution's own documentation. There is nothing SCRAP-specific to learn
here on purpose.

---

## Layer 2 — k3s / Kubernetes

**What it does:** turns that one host into a place where declarative workload specs get
reconciled into running containers, with a real API, real RBAC, real networking, and a real
scheduler — even though there's only one node to schedule onto.

**Why SCRAP chose Kubernetes, and k3s specifically:** the honest alternative for a single box is
something like Podman Quadlet — far less overhead, no control plane, no etcd. SCRAP doesn't use it
because the *product* isn't "run some containers," it's "applications compose platform capabilities
through well-defined contracts" — and those contracts are Kubernetes objects: a `PersistentVolumeClaim`,
an `HTTPRoute`, a `PodMonitor`. Each is backed by a controller doing label-based discovery, which is
what makes "add an application" mean "add some files," never "edit platform code." k3s is a single
static binary, batteries-removable (SCRAP disables its bundled Traefik and uses its own), with a
tiny footprint appropriate for one machine.

**Contract to the next layer:** a working Kubernetes API server that Flux can authenticate against
and reconcile into.

**What's actually happening:** a real kubelet, a real container runtime (containerd), a real
embedded etcd holding cluster state at `/var/lib/rancher/k3s`. `kubectl get pods -A` on a SCRAP
install shows you exactly what's running — no SCRAP-specific inspection tool required, ever.

**Go deeper:** [k3s docs](https://docs.k3s.io/), then the upstream
[Kubernetes documentation](https://kubernetes.io/docs/home/) for anything k3s itself doesn't cover.

---

## Layer 3 — Flux / GitOps

**What it does:** watches a Git repository and continuously reconciles the cluster's actual state
to match what's declared there. If something drifts — a resource edited by hand, a pod deleted —
Flux puts it back.

**Why SCRAP chose Flux:** two concrete reasons, not a coin flip. First, Flux decrypts SOPS secrets
natively at reconcile time, per `Kustomization` — no separate script materializing plaintext to
disk. Second, and more important for a *recovery-first* platform: with a reconciler, `flux
bootstrap` **is** the recovery procedure, and it's executable and testable, not a runbook someone
has to follow correctly by hand under pressure. The alternative to a reconciler — "run an ordered
install script" — was tried in the environment SCRAP's design is derived from, and it's exactly what
produces an untested, partially-wrong recovery document nobody trusts.

**Contract to the next layer:** a set of `Kustomization` objects, each pointing at a directory in
this repository, applied in dependency order (`platform/` before `capabilities/` before `apps/` —
see [`core/repository-structure.md`](core/repository-structure.md)), each able to decrypt the
SOPS-encrypted secrets it needs.

**What's actually happening:** four small controllers (`source-controller`,
`kustomize-controller`, `helm-controller`, `notification-controller`), each doing one job, each
inspectable with `flux get kustomizations` or a plain `kubectl get`. Nothing about how they work is
SCRAP-specific.

**Go deeper:** [Flux docs](https://fluxcd.io/flux/), specifically the `Kustomization` and
`GitRepository` API references — those are the two objects you'll read most often.

---

## Layer 4 — SOPS / age secrets

**What it does:** lets real credentials — database passwords, API tokens, TLS keys — live
**encrypted** inside this same Git repository, decrypted only at reconcile time, by a key that
never has to be checked in.

**Why SCRAP chose SOPS + age:** because a Kubernetes-native alternative that keeps its decryption
key only *inside* the cluster (Sealed Secrets is the common example) is actively hostile to
recovery — if the cluster is what you lost, you can't read your own secrets to rebuild it. age is
small, modern, and the private key can live wherever you choose: a password manager, a printed
copy, a USB drive kept off-site. SOPS encrypts just the sensitive fields, so a `git diff` on a
secret still shows you *what changed*, just not the values.

**Contract to the next layer:** every stateful capability that needs a credential reads it from a
Kubernetes `Secret` that Flux materialized by decrypting a checked-in `.sops.yaml` file — no
different, from the application's point of view, than any other Kubernetes Secret.

**What's actually happening:** two age keypairs are generated at bootstrap (an operational one and
an offline escrow copy — losing one doesn't lose the repository), and their **public** keys are the
only thing recorded in `.sops.yaml`. The private keys never touch Git.

**Go deeper:** [SOPS](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age)
— both are plain command-line tools you can run by hand outside Kubernetes entirely, which is
exactly the point.

---

## Layer 5 — persistent storage

**What it does:** gives an application a `PersistentVolumeClaim` that survives pod restarts and
reschedules.

**Why SCRAP chose the smallest possible answer:** k3s's bundled `local-path` provisioner, taken
as-is. No Longhorn, no NFS, no distributed storage, on purpose — a single-node platform doesn't
need replication to survive a pod crash, and building one in would add real operational weight for
a guarantee SCRAP gets a better way: **tested backup and restore**, not replicated disks. This is a
deliberate, defended non-decision, not an oversight — see
[`decisions/`](decisions/) for the reasoning.

**Contract to the next layer:** a `PersistentVolumeClaim` an application can mount, and — this
matters — that the backup layer can also mount directly, so backup never has to reach around
Kubernetes into a provisioner's private on-disk path (a real, previously-hit class of bug).

**What's actually happening:** a directory on the node's local disk, bind-mounted into whichever
pod claims it. `local-path` pins that pod to this node — fine, there's only one.

**Go deeper:** [local-path-provisioner](https://github.com/rancher/local-path-provisioner), and
the Kubernetes [`StorageClass`/`PersistentVolume` concepts](https://kubernetes.io/docs/concepts/storage/)
generally if this is your first time meeting them.

---

## Layer 6 — networking, routing, and TLS

**What it does:** gets traffic from a hostname to the right application, over HTTPS, with a
certificate that's actually valid.

**Why SCRAP chose Gateway API on Traefik, and a private CA by default:** Gateway API is the
Kubernetes-standard successor to Ingress — implementation-portable routing, not a proxy-specific
format. Traefik implements it well and is the one thing k3s's own bundled install *doesn't* get
used for — SCRAP installs k3s with Traefik disabled and runs its own Flux-managed copy, so there's
exactly one reconciler for platform infrastructure, not two working against each other.

TLS is the part worth being precise about, because it's easy to conflate two different questions.
**Certificate lifecycle management** — issuing and renewing a certificate — is core and mandatory.
*Which issuer* signs that certificate is a separate, optional choice. The minimum path uses a
private certificate authority SCRAP generates for you at bootstrap: no domain, no public DNS, no
internet required at runtime. cert-manager issues **exactly one wildcard certificate** —
`*.yourdomain` — and every application's `HTTPRoute` rides on it without declaring a single
certificate-related object of its own. If you later want certificates every browser and phone
already trusts, enabling `capabilities/public-tls/` swaps the *issuer* cert-manager uses — Let's
Encrypt via ACME DNS-01, which can also issue wildcards — and **no application manifest changes at
all**. The only real difference between the two paths is who has to be told to trust the
certificate: manually, for the private CA; automatically, for the public one.

**Contract to the next layer:** an `HTTPRoute` object and nothing else. Applications never
reference a `Certificate` or a `ClusterIssuer` — checked by CI, not just asserted.

**What's actually happening:** cert-manager watching `Certificate` objects and talking to whichever
`ClusterIssuer` they reference; Traefik watching `Gateway` and `HTTPRoute` objects and programming
its own internal router accordingly. Two independent controllers, each debuggable with their own
`kubectl logs` and their own upstream docs.

**Go deeper:** [Gateway API](https://gateway-api.sigs.k8s.io/), [Traefik](https://doc.traefik.io/traefik/),
[cert-manager](https://cert-manager.io/docs/).

---

## Layer 7 — backup and recovery

**What it does:** takes application data out of the cluster, encrypted, on a schedule, with
retention and pruning — and, just as importantly, can put it back, which is the part that's
actually been tested.

**Why SCRAP chose restic, and one platform-owned engine rather than per-application scripts:**
restic is mature, encrypts client-side before anything leaves the machine, deduplicates, and speaks
to any S3-compatible endpoint (or a local path, or a LAN target) without caring which provider that
is. It's owned once, platform-wide — a real, previously-observed failure mode is multiple
independent backup jobs each running their own prune against a shared repository and evicting each
other's snapshots. An application opts in by labeling its `PersistentVolumeClaim` and, if it needs
one, declaring a consistency method (a database dump command, a quiesce step) — it never writes its
own `CronJob`.

**Contract to the next layer:** nothing flows *upward* from here, but everything else's recovery
story is honest because of this layer — see
[`core/recovery-model.md`](core/recovery-model.md) for exactly which failure class each backup
destination choice (local disk, LAN target, off-site S3) actually buys you. SCRAP never claims
"we have backups" as if that were a complete answer.

**What's actually happening:** **one** platform-owned `CronJob` for the whole installation — not
one per application. It lists every `PersistentVolumeClaim` labeled for backup, mounts each
directly, and runs `restic backup` against it, plus exactly one scheduled prune and one scheduled
integrity check. An early design considered generating a `CronJob` per application from a shared
Kustomize component instead; a single discovery job turned out to be the more consistent way to
guarantee "exactly one prune, ever, against a shared repository" — see
[`decisions/0003-backup-job-generation.md`](decisions/0003-backup-job-generation.md).

**Go deeper:** [restic](https://restic.readthedocs.io/) — genuinely worth reading even if you never
touch SCRAP's wiring around it, since you may end up running `restic restore` by hand during a real
recovery.

---

## Layer 8 — observability

**What it does:** collects metrics, evaluates alert rules, and gives you a place to see whether
anything — including the backup layer above — is actually working.

**Why this is core, and why that's a deliberate argument, not a default:** the deciding case is
specific: **backup without alerting is not a safety system.** A platform that quietly stops backing
something up and never tells you has reproduced the exact failure it exists to prevent. So
Prometheus, Alertmanager, kube-state-metrics, and node-exporter are core — along with the
`PodMonitor`/`PrometheusRule` contract applications opt into. Grafana and centralized log shipping
(Loki + Alloy) are *not* core — genuinely valuable, not load-bearing for the recovery story, so they
don't inflate the minimum. Grafana is implemented and live-tested today; Loki + Alloy is designed
but not yet built — see `docs/release-readiness.md` for the current status of every optional
capability.

**Contract to the next layer:** a pod labeled `observability.scrap.io/scrape: "true"` with a port
named `metrics` gets scraped by the one cluster-wide `PodMonitor` — no application ever ships its
own. A `PrometheusRule` anywhere is auto-discovered.

**What's actually happening:** the Prometheus Operator reconciling its own CRDs, Prometheus itself
scraping and evaluating rules, Alertmanager routing anything that fires. Alertmanager ships with
**no receiver configured by default**, and bootstrap says so out loud rather than letting that go
unnoticed — configuring a real one (email, ntfy, a webhook) is a documented, first-class step, not
an afterthought.

**Go deeper:** [Prometheus](https://prometheus.io/docs/introduction/overview/),
[Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/), the
[Prometheus Operator](https://prometheus-operator.dev/).

---

## Layer 9 — identity (optional)

**What it does, when you turn it on:** gives your applications one place to authenticate against —
native OIDC for apps that support it, a gateway-level check for the ones that don't — instead of
every application managing its own separate login.

**Why this is optional, and why Authentik specifically when you want it:** identity roughly
doubles a typical install's memory footprint and is real operational surface, so it stays outside
the core (T1 — delete every application and every optional capability, and SCRAP still works).
When you do want it, SCRAP picked Authentik over a lighter alternative for a concrete, tested
reason, not a feature-list comparison: a lighter identity provider evaluated during SCRAP's design
turned out to force a real, structural choice between letting users reset their own password and
keeping the user list in Git — you can't have both with a file-backed user store. Authentik's
database-backed user store doesn't have that conflict, and its cost is exactly what buys you out of
it. See [`decisions/0002-identity-implementation.md`](decisions/0002-identity-implementation.md)
for the full evidence.

**Contract to the next layer:** an OIDC issuer URL and a per-application client secret for
applications that support OIDC directly; a shared forward-auth endpoint, wired in with one
`HTTPRoute` filter, for the ones that don't. Every Provider, Application, and policy Authentik needs
is declared as an Authentik **Blueprint**, stored in Git — never created only by clicking through an
admin UI, which would silently break the "configuration is recreated" half of SCRAP's recovery
model.

**What's actually happening:** an ordinary OIDC provider and a PostgreSQL database holding the
parts of identity that are genuinely *data* — accounts, passwords, enrolled passkeys — backed up
the same way any other stateful application's database is.

**Go deeper:** [Authentik docs](https://docs.goauthentik.io/), and the
[OpenID Connect spec](https://openid.net/specs/openid-connect-core-1_0.html) itself if you want to
understand what's actually happening in the redirects.

---

## Layer 10 — your applications

**What it does:** this is the point of all of the above. An application is a normal set of
Kubernetes manifests under `apps/`, consuming whichever of the contracts above it needs, declaring
nothing about *how* those contracts are implemented.

**Why applications look almost boringly ordinary:** because that's the actual product. Six
patterns cover essentially everything (see [`patterns/`](patterns/)): an internal HTTP app; an
HTTP app with native OIDC; an HTTP app behind gateway forward-auth; raw TCP/UDP exposure; a stateful
app with a declared backup method; a reverse proxy to something outside the cluster entirely. Adding
one means adding files under `apps/`, plus exactly one Flux `Kustomization` enabling it — nothing
under `platform/` or `capabilities/` should ever need to change, and CI checks that on every pull
request against this repository.

**Where this leaves you:** with a real Kubernetes cluster, built from documented, versioned,
upstream components, that you can inspect, extend, and — if you ever stop needing SCRAP's opinions —
keep operating with nothing but `kubectl`, `flux`, and each tool's own documentation. That's the
test this whole document exists to pass.
