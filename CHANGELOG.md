# Changelog

Notable changes to SCRAP, one entry per release/candidate. Loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), adapted for a GitOps platform repository:
entries track capability existence and proof status, not just code diffs. See
[`docs/decisions/0015-versioning-and-release-process.md`](docs/decisions/0015-versioning-and-release-process.md)
for the versioning scheme and release procedure, and [`docs/releases/`](docs/releases/) for the
full release-notes artifact accompanying each entry below. `docs/release-readiness.md` remains the
live, authoritative evidence snapshot this file summarizes at each candidate/release point.

## [Unreleased]

No new release/candidate entry has been assembled here yet. Changes may have landed since the
`v0.1.0-rc.2` content below was assembled; see this repository's commit history for what they
were and whether they warrant a new entry.

## [v0.1.0-rc.2] — hotfix: UPS installer deadlock, sudo env-propagation

**DRAFT — not yet merged into `main`, adjudicated, or tagged.** This entry describes PR #34
(`port-sudo-E-fix-to-main`), currently open; see
[`docs/releases/v0.1.0-rc.2.md`](https://github.com/platta/scrap/blob/main/docs/releases/v0.1.0-rc.2.md)
(also a draft) for the full write-up, including why this warrants a new tag rather than landing
silently on `main`. Per `docs/decisions/0015-versioning-and-release-process.md`, the tag itself —
and the exact commit SHA it points at — is created only after independent adjudication; nothing
here is final until that happens.

Carries forward everything in `v0.1.0-rc.1` below unchanged — no capability's PROVEN NOW /
INTENDED FOR v1 BUT NOT YET PROVEN / DEFERRED status moved. This is a defect-fix candidate, not a
new capability candidate.

### Fixed

- **UPS capability, host installer (`bootstrap/host/install-nut.sh`, `docs/decisions/0013`):** the
  `nut` package install could deadlock before `ups.conf` exists — its own postinst starts
  `nut-driver-enumerator.service`, which loops calling `systemctl restart nut-server`; that fails
  instantly with no UPS configured yet, until systemd's restart-rate-limit trips, at which point
  the enumerator's in-flight restart call and `nut-server.service`'s own ordering-queued start
  deadlock each other. Root-caused live via a dedicated diagnostic CI run (not inferred from
  symptoms alone); fixed with a temporary, trap-guarded `policy-rc.d` scoped to just that install
  step. Reproduced 2/2 times before the fix, passed on every run after — this is a real,
  likely host-independent defect in the installer's own ordering (install the package, _then_
  write its config), not merely a CI-environment quirk, even though CI is where it surfaced.
- **Same file:** no longer overwrites or deletes a `policy-rc.d` the host already had — previously
  clobbered and removed unconditionally, silently changing the operator's own package-service
  policy for the duration of this script's run (and permanently, if interrupted — see below).
- **Same file:** an interrupted run (Ctrl-C, or any failure between writing the temporary
  `policy-rc.d` and removing it) could no longer leave it behind — the removal/restore is now
  under an `EXIT` trap.
- **Documentation:** the installer command shown in `v0.1.0-rc.1`'s own release notes,
  `docs/getting-started.md`, `bootstrap/README.md`, and the Topology B generator's own generated
  operator README all used `sudo VAR=value sh bootstrap/install.sh` or `sudo -E sh
  bootstrap/install.sh` — both depend on a sudoers `SETENV` policy that silently drops the
  variable (no error, no warning the operator would see as a problem) when absent. Standardized
  everywhere on `sudo env VAR=value sh bootstrap/install.sh`, which doesn't depend on that policy
  at all. This is a real, if narrow, correctness fix for any operator following these docs on a
  hardened-sudoers host — not specific to CI.

### Internal (CI/test-harness only — no effect on an installed SCRAP instance)

- Every acceptance-profile test script and `bootstrap/install.sh` invocation under `sudo` relied
  on `sudo -E` to carry `SCRAP_ESCROW_CONFIRMED` (and, for Topology B, several other variables)
  across the privilege boundary. GitHub's `ubuntu-latest` runner label began migrating to Ubuntu
  26.04 on 2026-10-28, whose sudo policy silently ignores `-E` (warns, then proceeds without it),
  which broke the nightly DR (disaster-recovery) workflow and would have broken every acceptance
  profile the next time each one happened to land on the new image. Fixed the same way as the
  documentation above: pass needed variables directly to `env` instead of relying on `sudo -E`.
  Also fixed the same `KUBECONFIG`-via-`sudo -E` pattern in all ten workflows' on-failure
  diagnostics steps, which were silently producing useless "connection refused" output under the
  same mechanism.

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
