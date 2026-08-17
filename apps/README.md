# apps/

Applications are **consumers** of platform capabilities, never dependencies of them (T1). This is
the layer where SCRAP's abstraction actually pays off: a "normal application" is added here, and
only here, plus exactly one enabling `Kustomization` under `clusters/<name>/` — nothing under
`platform/` or `capabilities/` changes. CI enforces this on every pull request
(`tests/assertions/`).

## `examples/`

Minimal, purpose-built workloads demonstrating each of the six application integration patterns
(`docs/patterns/README.md`) in isolation, so the pattern is legible without also reading a
real application's unrelated complexity:

- **P1** — internal HTTP app
- **P2** — HTTP app with native OIDC
- **P3** — HTTP app behind gateway forward-auth
- **P4** — raw TCP/UDP exposure
- **P5** — stateful app with a declared backup consistency method
- **P6** — reverse proxy to an external LAN backend (NAS, router, hypervisor — anything with no
  identity or TLS of its own)

**P1, P4, P5, P6 implemented and live-validated.** P2 and P3 are deferred: both require
`capabilities/identity/` (Authentik), and P3 also requires `components/forward-auth/` — neither is
implemented yet, and building either is a separately-scoped milestone, not something this directory
can absorb without itself violating T2 (a change touching `apps/` must not also touch
`capabilities/`). See `apps/examples/README.md`.

## `catalog/`

A small number of real, boring, well-behaved applications, included as end-to-end proof that the
patterns compose in practice — not as SCRAP's product. **Fully optional**; deleting this directory
entirely must leave a complete platform (T1), and CI checks exactly that.

For a broader set of real-application integration examples beyond what ships here, see the planned,
separate `scrap-patterns` companion repository (`docs/decisions/`) — deliberately not part of this
repository, so SCRAP's own release cadence stays decoupled from a growing example catalog.

## What "normal" means

An application is addable under this directory alone if it: runs from multi-arch, pinned images;
is reached by hostname over HTTP(S) or a declared TCP/UDP port; keeps state in PVCs or keeps none;
can be made backup-consistent by file copy or a declared command; exposes Prometheus metrics on an
HTTP endpoint or doesn't; and authenticates itself, via OIDC, or via gateway forward-auth. Anything
outside that isn't wrong — it just isn't covered by T2, and should say so.
