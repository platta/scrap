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
`v0.1.0-rc.3` tag (2026-11-04) was cut; see this repository's commit history for what they were
and whether they warrant a new entry.

## [v0.1.0-rc.3] — hotfix: dyndns CronJob nsupdate-crash false failure

This is the release-notes content for the `v0.1.0-rc.3` tag, created 2026-11-04 against commit
[`5f01a2ca`](https://github.com/platta/scrap/commit/5f01a2cab575066ac1947fca5b44dea20a46b7dd)
(the merge of [PR #38](https://github.com/platta/scrap/pull/38), `port-dyndns-fix-to-main`) after
independent adjudication, per
`docs/decisions/0015-versioning-and-release-process.md`. Published as a
[GitHub pre-release](https://github.com/platta/scrap/releases/tag/v0.1.0-rc.3). Full write-up:
[`docs/releases/v0.1.0-rc.3.md`](https://github.com/platta/scrap/blob/v0.1.0-rc.3/docs/releases/v0.1.0-rc.3.md).

Carries forward everything in `v0.1.0-rc.2` and `v0.1.0-rc.1` below unchanged — no capability's
PROVEN NOW / INTENDED FOR v1 BUT NOT YET PROVEN / DEFERRED status moved. This is a defect-fix
candidate, not a new capability candidate.

### Fixed

- **Dynamic DNS capability, CronJob (`capabilities/dyndns/cronjob.yaml`, `docs/decisions/` dyndns
  capability):** Alpine's `bind-tools` `nsupdate` intermittently SIGSEGVs during its own
  `isc_app_ctxshutdown()` shutdown cleanup (a self-`kill()` call unexpectedly returns `EPERM`) —
  a known class of bug in BIND's own utilities (see e.g. ArchLinux FS#30139), not specific to
  this project's own infrastructure. The crash itself is mostly cosmetic — confirmed live, it
  happens on both successful and failed runs, after the tool has already produced valid output —
  but it was fatal specifically for the `nsupdate` invocation: unlike the script's `dig` calls
  (already piped through `| tail -n1`, which masks a crashing upstream's exit code), `nsupdate`'s
  call wasn't piped, so under `set -eu` a crash there aborted the whole script immediately,
  skipping the script's own already-existing independent confirmation query — even on runs where
  the real RFC2136 update had already been accepted by the nameserver before the crash. A real
  operator's `scrap-dyndns` CronJob could therefore report a failed Job for an update that had, in
  fact, genuinely succeeded. Fixed by capturing `nsupdate`'s exit status explicitly instead of
  letting `set -e` act on it, matching this script's own already-documented design intent
  ("nsupdate is not reliably non-zero on every failure mode ... this job re-queries the nameserver
  itself rather than trusting nsupdate's own exit code alone") — the bug was that a crash skipped
  reaching that re-query entirely, not that the design was wrong. Root-caused live with a
  dedicated diagnostic CI run (not inferred from symptoms alone) and verified behaviorally with a
  standalone positive/negative-control simulation of the exact crash pattern before landing.

### CI evidence note

Originally surfaced as an intermittent `T-A-dyndns` CI failure (4 of 5 runs failing when bundled
in the ten-workflow concurrent burst a push to `main`/a PR triggers, 1 of 1 clean when run in
isolation — a real, reproducible pattern, not a one-off). After the fix: clean on an isolated
`workflow_dispatch` run, and clean on two separate pushes/PRs that each re-triggered the full
ten-workflow burst (PR #37 against `develop`, PR #38 against `main`) — the exact conditions that
previously failed 4/5 times.

## [v0.1.0-rc.2] — hotfix: UPS installer deadlock, sudo env-propagation

This is the release-notes content for the `v0.1.0-rc.2` tag, created 2026-11-03 against commit
[`e298fc27`](https://github.com/platta/scrap/commit/e298fc2735333ab9b529a9a866a362db19ac7536)
(the merge of [PR #34](https://github.com/platta/scrap/pull/34),
`port-sudo-E-fix-to-main`) after independent adjudication, per
`docs/decisions/0015-versioning-and-release-process.md`. Published as a
[GitHub pre-release](https://github.com/platta/scrap/releases/tag/v0.1.0-rc.2). Full write-up,
including why this warranted a new tag rather than landing silently on `main`:
[`docs/releases/v0.1.0-rc.2.md`](https://github.com/platta/scrap/blob/v0.1.0-rc.2/docs/releases/v0.1.0-rc.2.md).

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
- `T-A-offsite-backup` (PLAT-269, originally `develop`-only via PR #31, 2026-09-18): ported in
  alongside the above — `tests/profiles/t-a-offsite-backup.sh` downloaded a precompiled MinIO
  binary from `dl.min.io`, which started returning something other than a valid binary. Fixed by
  building both MinIO server and client from pinned source instead. CI-only; included so this
  candidate's own check suite goes fully green, not because it affects an installed instance.

### CI evidence note

The push-to-main suite for the exact candidate (`e298fc27`) completed 9/10 green on first
attempt; `T-A-dyndns` failed twice in a row, with a different specific assertion failing each
time (`update-applies` the first time, `rejects-wrong-credential` the second) — the signature of
a genuine race, not a deterministic bug. `tests/profiles/t-a-dyndns.sh` is byte-identical to the
version that had already passed cleanly on this same commit via the PR's own `pull_request`
checks, and a third, isolated `workflow_dispatch` run of just this workflow (outside the
ten-workflow concurrent burst every push to `main` triggers) passed cleanly on the first attempt.
Classified as contention from that simultaneous burst, not a product regression — this PR touches
nothing under `capabilities/dyndns/` or `tests/profiles/t-a-dyndns.sh`.

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
