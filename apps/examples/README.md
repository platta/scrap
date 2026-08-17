# apps/examples/

Contract/acceptance probes, not showcase applications. Each subdirectory is the smallest possible
demonstration of one row of the application contract (`docs/core/application-contract.md`) —
purpose-built so the pattern is legible without also reading a real application's unrelated
complexity. Their job is to prove that materially different application shapes (stateless HTTP,
raw TCP, stateful with backup, a workload that isn't even a pod) consume the same platform
capabilities without any of them requiring a platform-specific change.

Enabled by one Flux Kustomization, `clusters/example/apps-examples.yaml`, pointing at this whole
directory — all four live examples are one deliberate, bundled acceptance-probe set, sharing the
`scrap-examples` namespace, rather than four independent applications added incrementally.

| Pattern | Directory | What it proves |
|---|---|---|
| P1 — internal HTTP | `p1-internal-http/` | TLS and routing require zero declaration from the app |
| P4 — raw TCP/UDP | `p4-raw-tcp/` | A non-HTTP protocol reaches a pod via the reserved-ports allowlist |
| P5 — stateful + backup | `p5-stateful-backup/` | `components/backup/` genuinely patches a PVC; a declared consistency command runs before the copy |
| P6 — external LAN backend | `p6-external-proxy/` | The same TLS/routing story holds for a backend that isn't a Kubernetes workload at all |

## P2 and P3 are deliberately not here yet

P2 (native OIDC) and P3 (gateway forward-auth) both require `capabilities/identity/` (Authentik);
P3 additionally requires `components/forward-auth/`. Neither exists yet — both are currently
READMEs describing a contract, not an implementation. Building them is not something this
milestone can absorb: `tests/assertions/check_app_addition_boundary.py` enforces that a change
touching `apps/` must not also touch `capabilities/`, which is exactly what standing up identity
from within this directory would require. Declarative Authentik (via Blueprints, not the
API-mutation shortcut production once took) is real implementation work, scoped and tracked
separately — see the architecture's §15.4 obligations.

When that milestone lands, P2 and P3 join this table the same way P1/P4/P5/P6 did: as the smallest
possible proof the contract holds, not as showcase integrations.

## What "normal" means

An application is addable under this directory alone if it: runs from multi-arch, pinned images;
is reached by hostname over HTTP(S) or a declared TCP/UDP port; keeps state in PVCs or keeps none;
can be made backup-consistent by file copy or a declared command; exposes Prometheus metrics on an
HTTP endpoint or doesn't; and authenticates itself, via OIDC, or via gateway forward-auth. Anything
outside that isn't wrong — it just isn't covered by T2, and should say so.
