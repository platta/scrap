# platform/

**CORE.** Everything here is mandatory, present in every SCRAP install, and knows nothing about
`capabilities/` or `apps/`. This is the one-directional dependency rule from the architecture:

> Core may never depend on an optional capability. Integration glue lives in the optional layer,
> which may depend on core. Dependencies flow in exactly one direction.

CI enforces this on every pull request — see [`tests/assertions/`](../tests/assertions/).

## Tiers

| Directory | Tier | Provides |
|---|---|---|
| [`crds/`](crds/) | 1 | Gateway API CRDs, cert-manager CRDs, Prometheus operator CRDs — no dependencies |
| [`cert-manager/`](cert-manager/) | 2 | Certificate lifecycle: cert-manager itself, the private CA `ClusterIssuer`, the one wildcard `Certificate` on the Gateway |
| [`ingress/`](ingress/) | 2 | Traefik as the Gateway API controller; hostname routing and raw TCP/UDP exposure |
| [`storage/`](storage/) | 2 | The `local-path` StorageClass contract — no distributed storage in core |
| [`observability/`](observability/) | 2 | Prometheus, Alertmanager, kube-state-metrics, node-exporter, and the operator CRDs that form the application metrics/alerting contract |
| [`backup/`](backup/) | 2 | The restic-based backup engine: credentials, schedule policy, retention, prune, integrity check — owned once, platform-wide |

Tier 1 has no dependencies. Tier 2 may depend only on tier 1 and other tier 2 components — never on
`capabilities/` (tier 3) or `apps/` (tier 4).

## Why this exists at all

A platform component either survives the deletion of every application (T1) or it isn't a platform
component — it's an application's dependency masquerading as infrastructure. That's the exact defect
this layout exists to make impossible: a monitoring stack that depends on an identity application, a
Certificate that lists every application's hostname, a CoreDNS block hand-maintained per app.

See `docs/decisions/` for the reasoning behind each specific choice, and
[Understanding SCRAP](../docs/understanding-scrap.md) for the layer-by-layer walkthrough.
