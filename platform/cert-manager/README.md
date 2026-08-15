# platform/cert-manager/

**Tier 2.** Depends on `platform/crds/` only.

Provides SCRAP's entire TLS contract: **certificate lifecycle management**, not "Let's Encrypt
certificates." This directory contains:

1. **cert-manager itself** (Helm chart, pinned version, `enableGatewayAPI: true` in its
   `ControllerConfiguration` so it can solve ACME challenges via Gateway API `HTTPRoute` when the
   ACME capability is later enabled — see `capabilities/public-tls/`).
2. **The private CA** — a self-signed root `ClusterIssuer`, a long-lived `Certificate` for that
   root (the actual CA key pair), and the resulting `ClusterIssuer` that signs from it. This is the
   CORE, minimum-path issuer. No domain, no DNS, no internet.
3. **The one wildcard `Certificate`** — `*.<base-domain>` + `<base-domain>`, attached to Traefik's
   `websecure` Gateway listener (`platform/ingress/`). This is the **only** certificate SCRAP ever
   issues for HTTP(S) applications.

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
