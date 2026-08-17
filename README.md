# SCRAP

**S**elf-hosted **C**omposable **R**ecoverable **A**pplication **P**latform

> *The hardware can be scrap. The architecture isn't.*

SCRAP is an opinionated, durable, rebuildable single-node Kubernetes platform for self-hosting
whatever applications you want. Build the platform once. Deploy arbitrary applications into it
using well-defined integration patterns. If the hardware dies, rebuild the platform and restore
the applications from durable, tested backups.

**Status: pre-release implementation.** The architecture is frozen (see
[`docs/decisions/`](docs/decisions/)); the platform core, backup engine, observability core, and
the identity capability are implemented and live-validated on a real cluster, including P1–P6 of
the application contract. It is installable end to end via `bootstrap/install.sh` against a fresh
host. What's still missing before a v1 release candidate: several `capabilities/` (Grafana, logs,
public TLS, off-site backup, heartbeat), the Topology B onboarding generator, and dynamic
cluster-backed CI (`tests/profiles/`, `tests/dr/`) — everything tested so far has been validated
manually against a real scratch cluster, not yet by an automated acceptance suite. See
[Roadmap](#roadmap) below.

## What SCRAP actually is

SCRAP is not a new abstraction layer over Kubernetes. It is a curated, tested composition of real,
maintained, upstream tools — k3s, Flux, Kustomize, SOPS/age, cert-manager, Gateway API/Traefik,
restic, Prometheus — wired together with one opinion: **applications should consume platform
capabilities through ordinary Kubernetes contracts, never the other way around.**

Read **[Understanding SCRAP](docs/understanding-scrap.md)** for the full conceptual walkthrough —
about 10–15 minutes, layer by layer, from bare Linux host to running application.

**The core commitment:** SCRAP abstracts *decisions*, not *technologies*. If SCRAP disappeared
tomorrow, you would still hold an understandable, standards-based Kubernetes platform made of
maintained upstream components — not a pile of magic you can't operate without it.

## Two invariants that hold everywhere in this repository

- **T1** — delete every application under `apps/`, and a complete, useful platform remains.
- **T2** — adding a normal application requires adding files under `apps/` only, plus exactly one
  Flux `Kustomization` under `clusters/<name>/` that enables it. Nothing under `platform/` or
  `capabilities/` may need to change.

Both are enforced by CI on every pull request, not merely documented. See
[Architectural invariants CI enforces](#architectural-invariants-ci-enforces).

## What SCRAP requires, and what it doesn't

**Minimum:** one Linux host (x86-64 or arm64), 2 cores, 4 GB RAM, 32 GB SSD, a stable way for
clients to reach it, a correct clock, and internet access **once, at install time**, to pull
images. Nothing else.

**Explicitly not required for the minimum platform:** a public IP, public DNS, a registered
domain, Let's Encrypt or any ACME provider, a cloud account, S3/object storage, hosted Git, an
identity provider, SMTP, a password manager, multiple machines, or virtualization.

Richer configurations — publicly-trusted TLS, off-site backup, centralized identity, public
ingress — are fully supported, first-class, and tested, but every one of them is optional and
composable, never a hidden prerequisite of the core.

See [`docs/core/`](docs/core/), [`docs/supported/`](docs/supported/),
[`docs/extensions/`](docs/extensions/), and [`docs/out-of-scope/`](docs/out-of-scope/) for the
exact, load-bearing boundary between those categories.

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

## Architectural invariants CI enforces

Every pull request runs [`tests/assertions/`](tests/assertions/) — small, single-purpose,
readable scripts, each proven against a deliberately-violating fixture so the check is known to
actually catch what it claims to catch:

- `platform/` and `capabilities/` never reference `apps/`; `platform/` never references
  `capabilities/` (the one-directional dependency rule, §8.1 of the architecture)
- a pull request that touches `apps/` may not also touch `platform/` or `capabilities/` (T2,
  executed as a diff check, not just asserted)
- no `Certificate` resource and no `ClusterIssuer` reference exists anywhere under `apps/`
  (applications never know which TLS issuer is in use — see the TLS decision record)
- every container image is pinned — no floating tags
- every `LoadBalancer` Service or `hostPort` claims a port already declared in the reserved-ports
  allowlist
- every `${VAR}` referenced anywhere resolves to a documented instance-config key, and no
  instance-specific literal (an IP address, in particular) appears outside `clusters/`
- every Flux `Kustomization` dependency graph is acyclic, and no `Certificate` names an
  `issuerRef` that isn't guaranteed to exist yet by the dependency graph

See [`tests/assertions/README.md`](tests/assertions/README.md) for how to run them locally and
add a new one.

## Roadmap

1. ~~Repository skeleton + structural CI~~ — **done**
2. ~~Bootstrap: preflight checks, pinned k3s install, `install.sh`~~ — **done**
3. ~~Platform core: Gateway API CRDs, cert-manager + private CA + wildcard `Certificate`, Traefik/Gateway, local-path storage, observability core, backup engine~~ — **done**
4. ~~Example applications (`apps/examples/`) proving the six application patterns~~ — **P1/P4/P5/P6 done; P2/P3 depend on item 5's identity capability**
5. Capabilities: Authentik (declarative via Blueprints), Grafana + Loki, ACME/DNS-01, off-site backup, alert delivery, external heartbeat
6. Topology B onboarding: a generator producing a minimal, ordinary Flux/Kustomize/SOPS operator repository pinned to a released SCRAP version, host-agnostic (no GitHub requirement), plus an automated test proving a generated repo bootstraps/reconciles a clean install (`docs/decisions/0009-repository-topology.md`)
7. Dynamic CI profiles (T-A through T-F) and a real destructive-restore test
8. `scrap-patterns` — a deferred, separate companion repository of real-application integration examples

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
