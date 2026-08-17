# apps/examples/

Contract/acceptance probes, not showcase applications. Each subdirectory is the smallest possible
demonstration of one row of the application contract (`docs/core/application-contract.md`) —
purpose-built so the pattern is legible without also reading a real application's unrelated
complexity. Their job is to prove that materially different application shapes (stateless HTTP,
raw TCP, stateful with backup, a workload that isn't even a pod) consume the same platform
capabilities without any of them requiring a platform-specific change.

P1/P4/P5/P6 are enabled unconditionally, by one Flux Kustomization
(`clusters/example/apps-examples.yaml`) pointing at this whole directory — sharing the
`scrap-examples` namespace, one deliberate bundled acceptance-probe set rather than four
independent applications added incrementally.

| Pattern | Directory | What it proves |
|---|---|---|
| P1 — internal HTTP | `p1-internal-http/` | TLS and routing require zero declaration from the app |
| P4 — raw TCP/UDP | `p4-raw-tcp/` | A non-HTTP protocol reaches a pod via the reserved-ports allowlist |
| P5 — stateful + backup | `p5-stateful-backup/` | `components/backup/` genuinely patches a PVC; a declared consistency command runs before the copy |
| P6 — external LAN backend | `p6-external-proxy/` | The same TLS/routing story holds for a backend that isn't a Kubernetes workload at all |
| P2 — native OIDC | `p2-native-oidc/` | An OIDC relying party's own backend calls succeed through `components/ca-trust/`; the Provider/Application exist purely from a Blueprint |
| P3 — gateway forward-auth | `p3-forward-auth/` | An unmodified P1-shape app is gated entirely by a `Middleware`; the app itself never learns who authenticated |

## P2 and P3 are enabled differently, on purpose

Both hard-depend on `capabilities/identity/` — P3 additionally on `components/forward-auth/`.
Bundling them into the always-on `apps/examples/kustomization.yaml` would break the `minimal`
profile: it has no identity capability for them to authenticate against at all. They live in
`apps/examples/identity/`'s own aggregator instead, enabled by copying
`apps/examples/identity/cluster-kustomization.yaml` into `clusters/<name>/capabilities/` — the
*third*, optional file alongside identity's own two enabling files. See
`capabilities/identity/README.md`'s "Enabling this capability" section for why this one template
lives under `apps/`, not bundled with the other two under `capabilities/identity/`.

## What "normal" means

An application is addable under this directory alone if it: runs from multi-arch, pinned images;
is reached by hostname over HTTP(S) or a declared TCP/UDP port; keeps state in PVCs or keeps none;
can be made backup-consistent by file copy or a declared command; exposes Prometheus metrics on an
HTTP endpoint or doesn't; and authenticates itself, via OIDC, or via gateway forward-auth. Anything
outside that isn't wrong — it just isn't covered by T2, and should say so.
