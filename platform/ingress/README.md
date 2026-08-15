# platform/ingress/

**Tier 2.** Depends on `platform/crds/` (Gateway API) and `platform/cert-manager/` (the wildcard
`Certificate` this Gateway's `websecure` listener references).

Traefik, installed as a plain Flux `HelmRelease` — not k3s's own bundled Traefik, and not k3s's
built-in Helm controller. k3s is installed with `--disable=traefik` specifically so there is exactly
one reconciler for platform infrastructure (Flux), not two running in parallel.

Provides:

- One shared `Gateway` with two listeners: `web` (plain HTTP, used only for ACME HTTP-01 challenges
  when that capability is enabled) and `websecure` (HTTPS, terminating the platform wildcard
  certificate).
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
wildcard DNS/hosts entry, never a hand-maintained per-application list and never a hardcoded
ClusterIP. See `docs/decisions/` for the specific defect this replaces.
