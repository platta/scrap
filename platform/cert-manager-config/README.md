# platform/cert-manager-config/

**Tier 2.** Depends on `platform/cert-manager/` (the `ClusterIssuer`/`Certificate` CRDs it needs
must already be installed — see `kustomization.yaml` in this directory for the real ordering bug
that makes this a separate Flux `Kustomization` rather than living inside `platform/cert-manager/`
itself).

Provides SCRAP's entire TLS **issuer**: the private CA, entirely self-contained — no domain, no
public DNS, no internet required at runtime. This is the CORE, minimum-path implementation of
"certificate lifecycle management," not "Let's Encrypt certificates."

Three chained objects (`private-ca.yaml`):

1. `scrap-selfsigned` — a bootstrap self-signed `ClusterIssuer`.
2. A `Certificate` for the CA's own root — the actual CA key pair, `scrap-ca-key-pair`.
3. `scrap-ca` — the resulting `ClusterIssuer` that signs everything else. **This is the stable
   name** every other manifest in the repository may reference as an `issuerRef`. Swapping the
   private CA for `capabilities/public-tls/`'s ACME issuer means changing what `scrap-ca` points
   to, not renaming references across the codebase.

## The contract this hands to applications

> An application declares an `HTTPRoute`. **It declares nothing about TLS at all** — no
> `Certificate`, no issuer reference, no hostname registered anywhere in `platform/`.

`platform/ingress/` owns the one wildcard `Certificate` that actually references `scrap-ca` — see
that directory's README. CI proves the application half of this contract statically: no
`Certificate` resource and no `ClusterIssuer` reference may exist anywhere under `apps/`
(`tests/assertions/check_no_cert_in_apps.py`).

The meaningful difference between the private-CA path and the ACME path is **trust distribution**,
not certificate lifecycle — see `docs/decisions/0006-tls-wildcard-and-issuer-independence.md`.

## Workload trust vs. client trust

Client devices (browsers, phones) must be told to trust the private CA root — an operator step,
documented at `docs/core/`. Separately, any **workload** that makes TLS connections *to* a SCRAP
endpoint (for example, an application's own OIDC backend calls to the identity issuer) needs that
trust too, from inside its own container. `components/ca-trust/` is the shipped, optional Kustomize
component that injects it — one line in an app's `kustomization.yaml`, no platform change.
