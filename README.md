# SCRAP

**S**elf-hosted **C**omposable **R**ecoverable **A**pplication **P**latform

> *The hardware can be scrap. The architecture isn't.*

## What is SCRAP?

SCRAP is an opinionated, single-node Kubernetes platform for self-hosting your own applications on
a spare Linux box. Build the platform once. Deploy applications into it using well-defined
integration patterns. If the hardware dies, rebuild the platform and restore your applications from
tested backups.

It's not a new abstraction layer over Kubernetes — it's a curated, tested composition of real,
maintained, upstream tools (k3s, Flux, cert-manager, Gateway API/Traefik, restic, Prometheus) wired
together with one opinion: **applications consume platform capabilities through ordinary Kubernetes
contracts, never the other way around.** If SCRAP disappeared tomorrow, you'd still hold an
understandable, standards-based Kubernetes platform, not a pile of magic you can't operate without
it.

## Who it's for

A homelabber or self-hoster with one spare machine (old desktop, cheap VPS, an actual scrap box)
who wants to run their own applications with a real recovery story, without hand-rolling
Kubernetes, GitOps, TLS, and backup wiring from scratch every time.

**Probably not for you if** you need multiple nodes, high availability, or multi-tenant isolation —
SCRAP is deliberately single-node by design, not there yet (see
[`docs/out-of-scope/`](docs/out-of-scope/)). If you just want to run a couple of Docker containers
with no interest in Kubernetes at all, this is more platform than you need.

## What you get

- A working Kubernetes platform from one command, on hardware you already own.
- TLS and routing for free — your applications never declare a certificate or an issuer.
- One backup engine for the whole platform, with tested restore, not just "we take backups."
- A full set of optional, composable capabilities you turn on only if you want them: single
  sign-on, off-site backup, publicly-trusted certificates, centralized logs, alert delivery, an
  external heartbeat, dynamic DNS, public internet reachability, and UPS-triggered graceful
  shutdown — see [Choosing your capabilities](docs/choosing-capabilities.md).
- A documented path for adding your own applications that never requires touching the platform
  itself — see [Adding an application](docs/adding-an-application.md).

**Current status:** pre-release, release candidate `v0.1.0-rc.1`. The core platform and every
capability listed above are implemented and live-tested end to end, including a real,
destructive-restore disaster-recovery rehearsal. What's **not yet proven**: host-loss recovery
(rebuilding onto a completely blank machine) and arm64 as a tested architecture. Nothing here
claims otherwise — see [`docs/release-readiness.md`](docs/release-readiness.md) for the exact,
current, evidence-backed boundary, and [`CHANGELOG.md`](CHANGELOG.md) /
[`docs/releases/`](docs/releases/) for this release candidate's own content.

## Start here

**→ [Getting started](docs/getting-started.md)** — clone the repo, make your minimum configuration
choices, install, and verify it worked. No architecture reading required first.

## Minimum requirements

One Linux host: 2 cores, 4 GB RAM, 32 GB SSD, a stable way for clients to reach it, a correct
clock, and internet access once, at install time. x86-64 is continuously tested; arm64 is accepted
but not yet verified to the same standard. Nothing else is required — no public IP, domain, cloud
account, S3, identity provider, or second machine. Richer configurations (public TLS, off-site
backup, identity, and everything else in [What you get](#what-you-get)) are fully supported and
tested, but every one of them is optional and composable, never a hidden prerequisite of the core.
See [Getting started](docs/getting-started.md#1-check-your-host) for the full detail.

## What happens after install

A successful minimum install gives you a real Kubernetes cluster with certificates, routing,
storage, backup, and metrics/alerting all reconciling — verified by a live HTTPS request that
reaches a real pod, not just by objects reporting they exist. See
[Getting started, step 5](docs/getting-started.md#5-confirm-it-worked) for exactly what to check.

## Where to go next

- **Add your first application** — [Adding an application](docs/adding-an-application.md).
- **Turn on optional capabilities** — [Choosing your capabilities](docs/choosing-capabilities.md).
- **Understand what's running underneath, and why** — [Understanding SCRAP](docs/understanding-scrap.md),
  a 10–15 minute layer-by-layer walkthrough.
- **See how SCRAP knows any of its claims are true** —
  [How SCRAP knows its claims are true](docs/engineering-evidence.md).
- **The full documentation index, organized by CORE / SUPPORTED / EXTENSION / OUT OF SCOPE** —
  [`docs/README.md`](docs/README.md).

## Repository structure

```
bootstrap/       # host prep, preflight checks, k3s install — outside the cluster
platform/        # core capabilities: CRDs, cert-manager, ingress, storage, observability, backup
capabilities/    # optional, fully-supported capabilities — enabled by presence, not config
apps/            # example applications (examples/) and a small optional catalog (catalog/)
clusters/        # instance-specific values and capability selection — the ONLY place they live
components/      # small reusable Kustomize components apps opt into (backup, forward-auth, ...)
docs/            # organized by CORE / FULLY SUPPORTED / EXTENSION / OUT OF SCOPE, plus decisions
tests/           # structural CI assertions, DR rehearsals, acceptance profiles
```

Full rationale for this layout: [`docs/core/repository-structure.md`](docs/core/repository-structure.md).
Two invariants hold everywhere in this repository — delete every application and the platform
still works (**T1**), and adding a normal application never requires touching `platform/` or
`capabilities/` (**T2**) — both enforced by CI on every pull request, not merely documented. See
[`tests/assertions/README.md`](tests/assertions/README.md) for how those checks work and how to
run them locally.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
