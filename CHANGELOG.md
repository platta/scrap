# Changelog

Notable changes to SCRAP, one entry per release/candidate. Loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), adapted for a GitOps platform repository:
entries track capability existence and proof status, not just code diffs. See
[`docs/decisions/0015-versioning-and-release-process.md`](docs/decisions/0015-versioning-and-release-process.md)
for the versioning scheme and release procedure, and [`docs/releases/`](docs/releases/) for the
full release-notes artifact accompanying each entry below. `docs/release-readiness.md` remains the
live, authoritative evidence snapshot this file summarizes at each candidate/release point.

## [Unreleased]

Nothing has landed since the `v0.1.0-rc.1` candidate content below was assembled.

## [v0.1.0-rc.1] — first release candidate

This is the release-notes content for the `v0.1.0-rc.1` tag. Per
`docs/decisions/0015-versioning-and-release-process.md`, the tag is created only after independent
exact-candidate adjudication of a specific `main` commit SHA — see
`docs/decisions/0011-release-candidate-policy.md` for what a release candidate may still leave
unproven. Full notes, including the evidence boundary a first external tester should read before
relying on this candidate:
[`docs/releases/v0.1.0-rc.1.md`](https://github.com/platta/scrap/blob/v0.1.0-rc.1/docs/releases/v0.1.0-rc.1.md).

### Added

- Core platform: CRDs, cert-manager + private CA, Gateway API ingress, local-path storage,
  observability core, backup engine — installable from zero via `bootstrap/install.sh`
- The six application integration patterns (P1–P6), including a genuinely destructive P5 restore
- Identity (Authentik), declaratively configured via Blueprints — P2 native OIDC, P3 forward-auth,
  an adversarially-checked recovery-flow-abuse invariant
- Public TLS via ACME/DNS-01, issuer-independent from the platform's private CA
- Grafana, and Logs (Loki + Alloy)
- Off-site (S3-compatible) backup (artifact placement — see Known gaps)
- Alert delivery and external heartbeat
- Dynamic DNS
- Public ingress (operator-edge, no manifest by design — `docs/decisions/0014`)
- UPS / graceful shutdown on power loss (`docs/decisions/0013`)
- Topology B onboarding generator (`bootstrap/generate-topology-b.sh`, `docs/decisions/0009`)
- R1 (application-data loss) disaster recovery, proven nightly against a real multi-tier
  application (Authentik + PostgreSQL)
- This release-engineering machinery itself: versioning convention, this changelog, release notes,
  and the tag-triggered release workflow (PLAT-87)

### Known gaps (none block `rc.1`; most block final v1 — see `docs/releases/v0.1.0-rc.1.md`)

- R3 (host-loss recovery) and R4 (site-loss recovery) — the host-loss rehearsal (T-E) is not yet
  implemented; off-site backup proves artifact placement, not the recovery recipe
- arm64 is an accepted target architecture, not yet CI-verified (T-D)
- T-C's remaining nightly-integration value, and T-F (upgrade testing, which needs a prior release
  to upgrade from) are qualification infrastructure, not product-surface gaps
- Several capabilities' real-world edges (real domain issuance, real public reachability, real UPS
  hardware behavior, real third-party provider acceptance) remain permanent, by-design operator-run
  evidence boundaries, never CI-executed

### CI evidence note

The push-to-main suite for the accepted baseline (`b66af2b0`) completed 9/10 green on first
attempt; `T-A-offsite-backup` failed once during MinIO startup, then passed end to end on an
identical rerun against the same commit — a transient MinIO readiness race, not a product
regression. See `docs/releases/v0.1.0-rc.1.md` for the confirmed run history.
