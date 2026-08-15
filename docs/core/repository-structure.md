# Repository structure

**CORE.**

```
bootstrap/       tier 0 — outside the cluster: preflight, k3s install, age seed, flux bootstrap
platform/        tier 1-2 — CRDs, cert-manager(+config), ingress, storage, observability, backup
capabilities/    tier 3 — optional, fully supported: grafana, logs, identity, public-tls, ...
apps/            tier 4 — example applications and a small optional catalog
clusters/        instance values and capability selection — the ONLY place they live
components/      small reusable Kustomize components apps opt into
docs/            organized by CORE / SUPPORTED / EXTENSION / OUT OF SCOPE, plus decisions/patterns
tests/           structural CI assertions, DR rehearsals, acceptance profiles
```

This layout describes **what SCRAP provides**, not where an operator's own installation must live.
Running SCRAP does not require forking this repository — see `docs/decisions/0009-repository-topology.md`
for the fully-supported alternative: a separate operator repository containing only `clusters/`,
`apps/`, and `secrets/`, pinned to a released version of everything else here.

## The tier model

```
tier 0  bootstrap        outside the cluster entirely
tier 1  platform/crds    Gateway API, cert-manager, Prometheus Operator CRDs — no dependencies
tier 2  platform/*       cert-manager, cert-manager-config (separate Kustomization, see below),
                        Traefik+Gateway, storage, observability, backup
tier 3  capabilities/*   grafana, logs, identity, public-tls, public-ingress, offsite-backup, ...
tier 4  apps/*           examples and real workloads
```

Each tier may depend on any lower tier. **No tier may depend on a higher one.** This single rule,
CI-enforced (`tests/assertions/`), is what makes T1 (delete every application, the platform
survives) and the identity-capability-must-not-be-a-platform-dependency rule structurally true
rather than merely documented.

**Why `cert-manager-config` is a separate directory and Flux `Kustomization` from `cert-manager`,
found empirically, not designed in advance:** a Flux `Kustomization` dry-runs and applies all of
its resources together. A `HelmRelease` that installs a CRD, and a raw manifest of that CRD's kind,
cannot safely share one Kustomization — creating the `HelmRelease` object only queues the chart
install for a separate controller to process asynchronously; it does not mean the CRD exists yet at
apply time. Confirmed directly while validating this repository's own `platform/` manifests against
a from-zero cluster: the private CA's `ClusterIssuer` failed its dry-run with "no matches for kind
ClusterIssuer," at a moment independently confirmed to have zero cert-manager CRDs installed. Every
tier-2 component that mixes a Helm-installed CRD with a raw manifest of that kind needs the same
split, `dependsOn` + `wait: true` on the Helm-installing Kustomization.

## Two hard rules

1. **`platform/` may not reference `capabilities/` or `apps/`.** Checked statically on every pull
   request.
2. **Instance-specific literals — an IP address, a real domain, an email address — appear only
   under `clusters/`.** Everywhere else, a value is a `${VAR}` resolved by Flux's
   `postBuild.substituteFrom` from an instance's `instance-config.yaml`. Checked statically on
   every pull request.

## Why this specific shape

Every one of these boundaries is a direct, structural response to a real defect observed while
designing SCRAP — not best-practice cargo-culting. See `docs/decisions/` for the specific incidents
each rule closes off.
