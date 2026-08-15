# platform/cert-manager/

**Tier 2.** Depends on `platform/crds/` only.

Provides SCRAP's entire TLS contract: **certificate lifecycle management**, not "Let's Encrypt
certificates." This directory contains:

1. **cert-manager itself** (Helm chart, pinned version, `enableGatewayAPI: true` in its
   `ControllerConfiguration` so it can solve ACME challenges via Gateway API `HTTPRoute` when the
   ACME capability is later enabled — see `capabilities/public-tls/`).
2. **The private CA** — a self-signed root `ClusterIssuer` (`scrap-selfsigned`), a long-lived
   `Certificate` for that root (the actual CA key pair), and the resulting `ClusterIssuer`
   (`scrap-ca`) that signs from it. This is the CORE, minimum-path issuer. No domain, no DNS, no
   internet. `scrap-ca` is a stable name every other manifest may reference — swapping it for
   `capabilities/public-tls/`'s ACME issuer means changing what `scrap-ca` points to, not renaming
   references across the repository.

**The one wildcard `Certificate`** itself — `*.<base-domain>` + `<base-domain>` — is defined in
`platform/ingress/`, not here, because its Secret must live in the same namespace as the Traefik
`Gateway` that consumes it (`traefik`). This directory only owns the *issuer*; `platform/ingress/`
owns the certificate that references it, and its Flux `Kustomization` `dependsOn` this one — CI's
`check_kustomization_dag` proves that dependency is actually declared, not merely convenient. This
is the **only** certificate SCRAP ever issues for HTTP(S) applications.

## The contract this hands to every application

> An application declares an `HTTPRoute`. **It declares nothing about TLS at all** — no
> `Certificate`, no issuer reference, no hostname registered anywhere in `platform/`.

Swapping the private CA for a publicly-trusted issuer (`capabilities/public-tls/`, ACME via DNS-01)
is a one-line change to the `ClusterIssuer` this directory's wildcard `Certificate` references.
**No application manifest changes.** CI proves this statically: no `Certificate` resource and no
`ClusterIssuer` reference may exist anywhere under `apps/` (`tests/assertions/`).

The meaningful difference between the private-CA path and the ACME path is **trust distribution**,
not certificate lifecycle — see `docs/decisions/0006-tls-wildcard-and-issuer-independence.md`.

## Workload trust vs. client trust

Client devices (browsers, phones) must be told to trust the private CA root — that's an operator
step, documented at `docs/core/`. Separately, any **workload** that makes TLS connections *to a
SCRAP endpoint* (for example, an application's own OIDC backend calls to the identity issuer) needs
that trust too, from inside its own container. `components/ca-trust/` is the shipped, optional
Kustomize component that injects it — one line in an app's `kustomization.yaml`, no platform change.
See `docs/decisions/` for the full contract.

## Versions

Pinned exactly, no ranges. See the `HelmRelease` in this directory (once implementation reaches
this milestone) for the current version.
