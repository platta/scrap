# 0001 — Project name and license

**Decision:** the project is named **SCRAP** — Self-hosted Composable Recoverable Application
Platform. Tagline: *"The hardware can be scrap. The architecture isn't."* Licensed under
**Apache License 2.0**.

## Why this name

Each word is load-bearing, not decorative:

- **Self-hosted** — runs on hardware you own, not a managed service.
- **Composable** — applications consume platform capabilities through defined contracts; the
  platform doesn't dictate which applications you run.
- **Recoverable** — the organizing constraint of the entire design. Recovery guarantees are stated
  per configuration and tested, not asserted (`docs/core/recovery-model.md`).
- **Application Platform** — the product is the platform, not any specific application. Delete
  every application and a complete platform remains (T1, `docs/core/repository-structure.md`).

The tagline states the actual value proposition plainly: cheap, disposable, even genuinely "scrap"
hardware is an acceptable substrate, because durability lives in the architecture — the Git
repository, the encrypted secrets, the tested backups — not in any particular machine surviving.

## Why Apache-2.0

A permissive, patent-clause-bearing license appropriate for infrastructure software other people
will run in production and potentially build on. No copyleft obligation that would complicate
someone forking a piece of it into their own homelab setup, which is an explicitly welcomed outcome
given SCRAP's transparency principle (`0008-abstract-decisions-not-technologies.md`) — nothing here
is meant to be locked in.
