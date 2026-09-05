# docs/reviews/

Point-in-time review artifacts: structured assessments of the repository/release state as of a
specific commit, produced for a specific decision (adoption readiness, gate reviews, audits).

Unlike `docs/release-readiness.md` (live, continuously updated) or `docs/decisions/` (durable
architectural decisions), documents here are **snapshots**: each names the exact commits it
evaluated and is not updated as the repository moves on. If a review's findings conflict with the
current repository state, the current state — and the live documents above — win; the review
stays as the honest record of what was found at its own point in time.

| Review | Evaluated at | Purpose |
|---|---|---|
| [2026-09 external-adoption readiness](2026-09-external-adoption-readiness.md) | `v0.1.0-rc.1` (tag `b5eeb298`) as product baseline; docs/scripts at `develop` `6deeb01` | Can a technically competent outsider discover, install, operate, recover, and report problems with SCRAP from the published repository and release alone? |
