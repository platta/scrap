# platform/crds/

**Tier 1.** No dependencies. Everything downstream may depend on this; this depends on nothing.

CRDs vendored here, pinned to an exact upstream release:

- **Gateway API** (`standard` channel) — `Gateway`, `GatewayClass`, `HTTPRoute`, `TCPRoute`,
  `UDPRoute`, `BackendTLSPolicy`, `ReferenceGrant`. Vendored explicitly because k3s's
  `--disable=traefik` flag (used in `bootstrap/host/`) also removes k3s's bundled copy of these
  CRDs — a real gap the reference implementation hit and fixed the same way.
- **cert-manager CRDs** — installed via the cert-manager chart's own `crds.enabled: true`, not
  vendored separately, so they stay in lockstep with the chart version pinned in
  `platform/cert-manager/`.
- **Prometheus Operator CRDs** (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Alertmanager`,
  `Prometheus`) — installed via the kube-prometheus-stack chart's own CRD management, for the same
  reason.

## Why CRDs are isolated in their own tier

This is a direct, structural fix for a real defect: cert-manager's Helm chart can create a
`ServiceMonitor` object as part of its own install — but `ServiceMonitor` is a Prometheus Operator
CRD. If the CRD-owning component is installed *after* cert-manager, cert-manager's own first
install can never succeed on a truly empty cluster. Putting every CRD SCRAP needs in one
dependency-free tier, ahead of everything that might reference them, makes that class of ordering
bug structurally unrepresentable rather than something to catch during a from-zero rebuild.

`tests/assertions/` includes a Flux `Kustomization` dependency-graph check for exactly this pattern.
