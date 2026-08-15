# docs/core/

**CORE.** Documentation for what every SCRAP install has, no exceptions. If you're deciding what
to enable, start at [`../supported/`](../supported/) instead — this section is the load-bearing
reference.

- [`repository-structure.md`](repository-structure.md) — why the repository is laid out the way it
  is, and the two hard rules CI enforces
- [`application-contract.md`](application-contract.md) — exactly what an application can consume
  and what adding one is allowed to require
- [`configuration-model.md`](configuration-model.md) — where instance values live and how a
  capability is enabled
- [`bootstrap-lifecycle.md`](bootstrap-lifecycle.md) — the sequence from blank host to reconciling
  cluster
- [`recovery-model.md`](recovery-model.md) — what survives which failure, and what SCRAP actually
  tests versus merely claims

See also [Understanding SCRAP](../understanding-scrap.md) for the narrative version of all of this.
