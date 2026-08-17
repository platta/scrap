# platform/ingress/

**Tier 2.** Depends on `platform/crds/` (Gateway API) and `platform/cert-manager/` (the `scrap-ca`
`ClusterIssuer` this directory's own wildcard `Certificate` references).

Traefik, installed as a plain Flux `HelmRelease` — not k3s's own bundled Traefik, and not k3s's
built-in Helm controller. k3s is installed with `--disable=traefik` specifically so there is exactly
one reconciler for platform infrastructure (Flux), not two running in parallel.

Provides:

- One shared `Gateway` (`scrap-gateway`) with two listeners: `web` (plain HTTP, used only for ACME
  HTTP-01 challenges when that capability is enabled) and `websecure` (HTTPS, terminating the
  platform wildcard certificate).
- **The one wildcard `Certificate`** (`wildcard-certificate.yaml`) — owned here, not in
  `platform/cert-manager/`, because its Secret must live in this directory's own `traefik`
  namespace, the same one the `Gateway` resolving it lives in. It references the `scrap-ca`
  `ClusterIssuer` that `platform/cert-manager/` owns — the reason this Kustomization `dependsOn`
  that one.
- The Gateway API `kubernetesGateway` provider as primary routing mechanism.
- Traefik's own CRD provider stays enabled for exactly one reason: Gateway API has no standard
  authorization/middleware primitive, so gateway-level forward-auth (`components/forward-auth/`,
  consumed only when `capabilities/identity/` is enabled) needs a Traefik `Middleware` attached via
  `HTTPRoute` `ExtensionRef`. This is the one place SCRAP's routing layer is not fully
  implementation-portable — documented honestly in `docs/extensions/`, not hidden.

## The application contract

An application declares an `HTTPRoute` attached to this Gateway by name, or (for raw TCP/UDP) a
`Service` of type `LoadBalancer` whose port is declared in the reserved-ports allowlist
(`platform/ingress/reserved-ports.yaml`, once implemented) — checked by `tests/assertions/` on
every pull request. This is the direct, structural fix for a real incident: an ingress controller's
default `LoadBalancer` Service silently claiming a host's real production ports via k3s's
ServiceLB. SCRAP makes that class of mistake CI-detectable rather than a live incident.

## In-cluster hostname resolution

Application hostnames resolve inside the cluster the same way they resolve outside it — one
wildcard rewrite (`coredns-wildcard.yaml`, a `coredns-custom` `ConfigMap` in `kube-system` — k3s's
own documented, supported CoreDNS extension point, auto-imported with no CoreDNS deployment edit
or restart needed), never a hand-maintained per-application list and never a hardcoded ClusterIP:
`*.${BASE_DOMAIN}` rewrites to the Traefik `Service`'s own stable DNS name, resolved by the same
`k8s` CoreDNS plugin every other in-cluster `Service` lookup already uses. See `docs/decisions/`
for the specific defect (a hand-maintained `coredns-custom` list, hardcoded to one `ClusterIP`)
this replaces. Found needing this live: no application pattern before P2 (native OIDC,
`apps/examples/p2-native-oidc/`) ever made an in-cluster DNS query for a platform hostname — every
prior check in this repository's history queried from outside the cluster via `curl --resolve`,
which never exercises CoreDNS at all.
