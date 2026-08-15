# platform/cert-manager/

**Tier 2.** Depends on `platform/crds/` only.

Installs **cert-manager itself** — Helm chart, pinned version, `enableGatewayAPI: true` in its
`ControllerConfiguration` so it can solve ACME challenges via Gateway API `HTTPRoute` when the ACME
capability is later enabled (`capabilities/public-tls/`). Nothing else lives in this directory.

## Why the private CA is NOT defined here, in a separate Kustomization instead

The private CA issuer chain (`platform/cert-manager-config/`) is a **separate** Flux Kustomization,
`dependsOn` this one with `wait: true`. This is a real, empirically-confirmed ordering bug, not a
style preference: a Flux `Kustomization` dry-runs and applies all of its resources together. A
`ClusterIssuer` object in the *same* Kustomization as the `HelmRelease` that installs its CRD fails
that dry-run, because creating a `HelmRelease` object only *queues* the chart install for
helm-controller to process asynchronously — it does not mean the CRD exists yet at apply time.
Reproduced directly on a from-zero cluster while validating this milestone: `ClusterIssuer/scrap-ca
dry-run failed: no matches for kind "ClusterIssuer" in version "cert-manager.io/v1"`, with the CRD
count confirmed to be genuinely zero at that moment, not a status-reporting lag. See
`platform/cert-manager-config/README.md`.

## Contract this hands to `platform/cert-manager-config/`

Once this Kustomization reports Ready, cert-manager's CRDs are guaranteed to exist — `wait: true`
on a `HelmRelease` dependency means Flux waits for the chart itself to be Ready, not merely for the
`HelmRelease` object to be created.

## Versions

Pinned exactly, no ranges — see `helmrelease.yaml`.
