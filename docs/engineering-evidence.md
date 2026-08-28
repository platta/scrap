# How SCRAP knows its claims are true

*For a reader who wants to understand the evidence model before trusting a specific claim — not
required reading before your first install. If you just want to get SCRAP running, start at
[Getting started](getting-started.md) instead.*

SCRAP makes a lot of specific claims: "this survives a disk failure," "this application pattern
works," "this recovery procedure actually restores your data." Plenty of software makes claims like
that in prose and never checks them again. This page explains the machinery SCRAP uses instead, so
that when you read "proven by T-A" or "unlocks R1" elsewhere in these docs, you know exactly what
work that sentence is standing on — and so you can tell the difference between something SCRAP has
actually verified and something it has only designed.

For the current, up-to-the-commit answer to "what's proven right now, for *this* repository state,"
see **[`docs/release-readiness.md`](release-readiness.md)** — the live snapshot. This page explains
the *model* behind that snapshot and does not try to duplicate its table.

## The core distinction: structural checks vs. live acceptance profiles

SCRAP's evidence comes in two different flavors, and they answer different questions.

**Structural assertions** (`tests/assertions/`, run on every pull request, no cluster involved)
answer: *"does this repository's static content obey its own architectural rules?"* — no floating
image tags, no capability secretly depended on by `platform/`, every `${VAR}` resolves, applications
never declare their own TLS certificate. These run in seconds and catch a whole class of defect
before anything is ever deployed. Each one is itself tested against a fixture deliberately built to
violate the rule, so the check is known to actually fire, not just exist.

**Live acceptance profiles** (`tests/profiles/`, `tests/dr/`) answer a harder question: *"does this
actually work, on a real cluster, doing the real thing?"* These bootstrap an ephemeral cluster from
zero, enable real capabilities, make real HTTP requests, write and destroy real data, and restore
it — then tear the cluster down. A structural check can prove a `PrometheusRule` object exists; only
a live profile can prove Prometheus actually evaluated it and fired an alert. Both are necessary;
neither substitutes for the other.

## The acceptance-profile names: T-A through T-F

Each letter names a **trigger tier** — when it runs and roughly how much of the platform it
exercises — not a specific hard-coded test. The authoritative, current definition of each one lives
in [`tests/profiles/README.md`](../tests/profiles/README.md); this is the plain-language map:

| Profile | Runs | In plain language |
|---|---|---|
| **T-A — Minimal** | every push/PR | Boot the platform from nothing, with no optional capability enabled, and prove the four always-on application patterns (P1, P4, P5, P6) actually work — including genuinely destroying and restoring P5's data, not just checking objects exist. |
| **T-B — Standard** | every PR | A separate from-zero cluster with identity (SSO) and Grafana turned on: prove real logins work, prove an unauthenticated request is actually rejected, prove identity's account-recovery flow can't be abused. |
| **T-A-public-tls** | every push/PR | Prove the publicly-trusted-certificate path genuinely swaps the certificate issuer and reaches a real network exchange with Let's Encrypt, without needing a real domain to do it. |
| **T-A-offsite-backup** | every push/PR | Prove backup data can genuinely be written to, and read back from, a real S3-compatible destination outside the cluster — including a visible, bounded failure when the credentials are wrong. |
| **T-C — Connected** | nightly (not yet implemented) | The "everything turned on" profile: public DNS-01 issuance against a real zone, plus heartbeat, running together over time. |
| **T-D — arm64** | nightly (not yet implemented) | T-A's exact checks, on arm64 hardware instead of x86-64. |
| **T-E — Host-loss rehearsal** | pre-release (not yet implemented) | Take a genuinely blank machine, hand it nothing but the artifacts the recovery model says survive, and prove it becomes a working platform again. This is the big one — see R3 below. |
| **T-F — Upgrade** | pre-release (not yet implemented) | Install the previous release, upgrade to the current one, prove data survives and rollback works. Can't exist until a first release exists to upgrade *from*. |

"Not yet implemented" here means exactly that: no such test runs today, and no claim in this
repository should imply otherwise. See `docs/release-readiness.md` for which of these are currently
green.

## The recovery classes: R0 through R5

Where T-A..T-F describe *what gets tested and when*, R0–R5 describe *what kind of loss you're
protected against*. They're defined in full in
[`docs/core/recovery-model.md`](core/recovery-model.md); in short:

| Class | What's lost | What has to have survived |
|---|---|---|
| **R0** | A running process crashes | Nothing extra — Kubernetes just restarts it |
| **R1** | One application's data goes bad | Your backup repository and its password |
| **R2** | The disk your backups live on dies too | A second disk or medium for the backup destination |
| **R3** | The whole machine is gone | Git *and* your backups, both stored off that machine |
| **R4** | The whole physical site is gone | Everything R3 needs, genuinely off-site |
| **R5** | An external account or credential is lost | Escrowed keys, or a second destination/migration path |

The reason this matters for reading SCRAP's docs: **"the ingredient is implemented and tested" is
not the same claim as "the whole recovery class is proven."** SCRAP's off-site backup capability is
implemented and live-tested (`tests/profiles/t-a-offsite-backup.sh`) — that proves recovery
artifacts can genuinely leave the host. It does **not**, by itself, prove R3: that a blank machine
plus only those artifacts is actually enough to rebuild a working platform. That's a separate,
harder claim, and it's exactly what T-E exists to check. Until T-E runs, R3 and R4 stay marked
unproven — see `docs/core/recovery-model.md`'s own "R3/R4 specifically" section for why treating
those as the same claim would be dishonest.

## Why negative controls matter

A test that never fails when it should is worse than no test — it's false confidence with a green
checkmark attached. So wherever practical, SCRAP's important acceptance checks are **negative
controlled**: the invariant is deliberately violated first, the check is confirmed to actually turn
red, and only then is the violation reverted and the check confirmed green again. A few concrete
examples already in this repository: identity's anti-recovery-abuse check was proven to catch a real
account-takeover shape by temporarily wiring up the exact recovery flow it forbids, watching the
check fail, then removing it again; the offsite-backup check deliberately supplies a wrong
credential and confirms the resulting failure is visible and bounded, not silently swallowed. A
passing test that was never shown capable of failing is treated as unproven, not proven.

## Why exact-SHA release gates exist

A release candidate is a specific commit, not a branch name or a moving target. Between "the last
time someone looked at this" and "the commit actually being tagged," the repository can change —
docs can drift out of sync with code, a dependency can be bumped, a test can be quietly weakened.
SCRAP's release process gates on the **exact commit SHA** that will actually be tagged: an
independent reviewer inspects that precise commit, not a description of it, and any further change
— even a documentation-only one — produces a new candidate commit that needs its own gate. This is
why you'll sometimes see release notes reference a specific hash rather than just a version number:
the hash *is* the claim being evaluated.

## How the pieces fit together

- **[Architecture Decision Records](decisions/)** (`docs/decisions/`) record *why* SCRAP is shaped
  the way it is — including alternatives that were tried and rejected. They're the frozen
  architecture; acceptance profiles prove the implementation actually matches it.
- **[`docs/release-readiness.md`](release-readiness.md)** is the current, living snapshot of what's
  proven, what's designed-but-unproven, and what's deliberately deferred. It changes as milestones
  close gaps; this page and the ADRs don't need to change alongside it.
- **CI** (`.github/workflows/`) is what actually runs the structural assertions and live acceptance
  profiles referenced above, on every push, pull request, or nightly schedule, and is the mechanism
  that keeps `release-readiness.md` honest rather than aspirational.
- **Operator-run evidence** — a small, explicitly-labeled set of checks (for example, issuing a real
  certificate against a real public domain) genuinely can't run in CI because they need something
  CI doesn't have, like a real domain. These are documented as permanent, by-design evidence
  boundaries — see `capabilities/public-tls/verify-live.sh`'s own header for a concrete example —
  not as gaps waiting to close.

Together, these four things are what let this repository say "proven" instead of "we believe," and
say so precisely — one capability, one recovery class, one commit at a time.
