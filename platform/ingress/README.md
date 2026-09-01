# platform/ingress/

**Tier 2.** Depends on `platform/crds/` (Gateway API) and `platform/cert-manager/` (the
`ClusterIssuer` this directory's own wildcard `Certificate` references — `scrap-ca` by default;
see `wildcard-certificate.yaml`'s own comment for the `${TLS_ISSUER}` mechanism
`capabilities/public-tls/` uses to select a different one).

Traefik, installed as a plain Flux `HelmRelease` — not k3s's own bundled Traefik, and not k3s's
built-in Helm controller. k3s is installed with `--disable=traefik` specifically so there is exactly
one reconciler for platform infrastructure (Flux), not two running in parallel.

Provides:

- One shared `Gateway` (`scrap-gateway`) with two listeners: `web` (plain HTTP, used only for ACME
  HTTP-01 challenges when that capability is enabled) and `websecure` (HTTPS, terminating the
  platform wildcard certificate).
- **The one wildcard `Certificate`** (`wildcard-certificate.yaml`) — owned here, not in
  `platform/cert-manager/`, because its Secret must live in this directory's own `traefik`
  namespace, the same one the `Gateway` resolving it lives in. It references whichever
  `ClusterIssuer` `${TLS_ISSUER}` names (`scrap-ca` by default) — owned by `platform/cert-manager/`
  and, when enabled, `capabilities/public-tls/` — the reason this Kustomization `dependsOn`
  that one.
- The Gateway API `kubernetesGateway` provider as primary routing mechanism.
- Traefik's own CRD provider stays enabled for exactly one reason: Gateway API has no standard
  authorization/middleware primitive, so gateway-level forward-auth (`components/forward-auth/`,
  consumed only when `capabilities/identity/` is enabled) needs a Traefik `Middleware` attached via
  `HTTPRoute` `ExtensionRef`. This is the one place SCRAP's routing layer is not fully
  implementation-portable — documented honestly in `docs/extensions/`, not hidden.

## The application contract

An application declares an `HTTPRoute` attached to this Gateway by name, or (for raw TCP/UDP) a
`Service` of type `LoadBalancer` whose port is declared reserved — for a *new* P4 application, in
a `reserved-ports.yaml` colocated with the application itself, under `apps/<name>/`, **not** this
directory's own `reserved-ports.yaml` — checked by `tests/assertions/check_reserved_ports.py` on
every pull request. See `docs/decisions/0017-p4-port-reservation-ownership.md` for why: a central
platform file made a new P4 app's pull request touch both `apps/` and `platform/` at once, which
T2 forbids (this directory's own `reserved-ports.yaml` still carries one legacy entry predating
that record — see its own header comment). This is still the direct, structural fix for a real
incident: an ingress controller's default `LoadBalancer` Service silently claiming a host's real
production ports via k3s's ServiceLB. SCRAP makes that class of mistake CI-detectable rather than
a live incident.

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
