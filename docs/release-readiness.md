# Release readiness — the RC1 claim boundary

**What this document is for:** so that anyone inspecting this repository before a release
candidate is packaged can tell, at a glance and from primary evidence, what is **PROVEN NOW**,
what is **INTENDED FOR v1 BUT NOT YET PROVEN**, and what is **DEFERRED / OPTIONAL / POST-v1** —
without having to reconstruct that boundary from commit history or memory. See
`docs/decisions/0011-release-candidate-policy.md` for the policy that makes "intended but not yet
proven" a legitimate state for a release candidate to ship in, provided it's stated here, not
implied elsewhere as settled — and `docs/decisions/0012-rc-implementation-envelope.md` for the
boundary of that allowance: it covers behavior that is *implemented but unproven*, never behavior
that is still *unimplemented*. Rows below that are existence gaps (no manifests/code, not merely
no proof) therefore block `rc.1` itself, and are marked so.

This is a status snapshot, not a frozen document — update it as milestones close gaps. It records
*evidence level*, never a promise about when something will be finished.

## PROVEN NOW

Each of these is backed by a live, automated, CI-gated acceptance profile — not by prose alone.

| Claim | Evidence |
|---|---|
| Core platform (CRDs, cert-manager + private CA, ingress, storage, observability core, backup engine) installs from zero and reconciles | `tests/profiles/t-a-minimal.sh`, every push/PR |
| T1 (delete `apps/`, platform remains useful) and T2 (adding an app touches only `apps/` + one enabling file) | `tests/assertions/`, every PR |
| P1, P4, P5, P6 application patterns work, including a genuinely destructive restore of P5 | `tests/profiles/t-a-minimal.sh` |
| R1 (application-data loss) recovery, including for a real multi-tier stateful application (Authentik + PostgreSQL) | `tests/dr/authentik-postgres-restore.sh`, nightly |
| Identity (Authentik) is declaratively configured via Blueprints, not API-only | `capabilities/identity/`, `tests/profiles/t-b-standard.sh` |
| P2 native OIDC and P3 forward-auth, both positive and adversarial | `tests/profiles/t-b-standard.sh` |
| CA-trust wiring for private-CA backend calls | `tests/profiles/t-b-standard.sh` |
| Grafana as an optional capability: real Prometheus query through it, real OIDC login, group→role mapping, anonymous-access adversarially rejected | `tests/profiles/t-b-standard.sh` |
| Logs (Loki + Alloy) as an optional capability: a real workload's stdout marker shipped, stored, and retrieved through Grafana's own configured Loki data source, with a passing negative control | `tests/profiles/t-b-standard.sh` |
| Identity's recovery-flow-abuse invariant: no unauthenticated path to a password-set form, checked structurally and behaviorally, with a passing negative control | `tests/profiles/t-b-standard.sh` |
| Public TLS issuer-independence, and a real ACME network round-trip (Order stage) reached, failing visibly on bad DNS-01 credentials | `tests/profiles/t-a-public-tls.sh` |
| Off-site (S3-compatible) backup: **artifact placement only** — a real remote write (independently confirmed via the destination's own listing), an independent read via a separate client using the intended recovery credentials, ADR-0010 host-isolation unaffected by destination, and a genuine, bounded, visible failure on bad credentials | `tests/profiles/t-a-offsite-backup.sh` |
| Alert delivery: a real `AlertmanagerConfig` webhook receiver genuinely delivers a real, live-fired alert to an ephemeral HTTP receiver, with a passing negative control (zero deliveries before the alert fires) — see `capabilities/alert-delivery/README.md` for the honest limit (a real third-party provider's own API acceptance is operator-verified, not CI) | `tests/profiles/t-a-alert-heartbeat.sh` |
| Heartbeat: a real, conditional dead-man's-switch push — reaches an ephemeral HTTP receiver while Alertmanager is healthy, and a live negative control (Alertmanager scaled to zero) proves the push is genuinely withheld, not merely documented — see `capabilities/heartbeat/README.md` for the honest limit (a real provider's own missed-ping alarm/notification is operator-verified, not CI) | `tests/profiles/t-a-alert-heartbeat.sh` |
| Bootstrap reliability fixes found through repeated live execution (timeouts, HOME/sudo poisoning, dependency ordering, SOPS CWD discovery, cleanup scoping) | commit history, `bootstrap/install.sh` |

## INTENDED FOR v1 BUT NOT YET PROVEN

Each row names the exact claim a release candidate **must not make** until the cited work lands.

| Claim not yet provable | What's missing | Blocks final v1? |
|---|---|---|
| **R3 — host-loss recovery**: a blank machine, given only the artifacts the recovery model says survive, can be rebuilt into a working platform | T-E (host-loss rehearsal) — not yet implemented. Off-site backup proves one *ingredient* (artifacts reach independent storage); it does not prove the recipe works. See `docs/core/recovery-model.md`'s own "R3/R4 specifically" section. | Yes — mandatory before final v1, not before `rc.1` (`docs/decisions/0011`) |
| **R4 — site-loss recovery** | Depends on R3 being proven first | Yes |
| **arm64 is a tested platform target at the same evidence level as x86-64** | T-D (arm64 minimal, nightly) — not yet implemented. The *minimum requirement description* names arm64 as an accepted architecture (and `bootstrap/preflight/check-arch.sh` genuinely permits it), but no CI run has ever exercised it. | Yes |
| **Dyndns, UPS, public-ingress are implemented, working capabilities** | README-only, no manifests, in every case | Yes — **and blocks `rc.1`**: an existence gap, not a proof gap (`docs/decisions/0012`) |
| **Topology B (separate operator repository) has been exercised end to end** | The generator and its own bootstrap/reconcile test (`docs/decisions/0009-repository-topology.md`, "Required for v1") do not exist yet. Topology A (monorepo) is what's actually tested. | Yes — **and blocks `rc.1`** (existence gap, `docs/decisions/0012`; commit-SHA pinning means nothing about it structurally requires a release to exist first) |
| **T-C (Connected profile, nightly)** | Not yet implemented. Heartbeat and alert delivery now both exist and are proven at the level `tests/profiles/t-a-alert-heartbeat.sh` establishes (see PROVEN NOW, above) — T-C's remaining, unimplemented value is the *nightly* integration with real DNS-01 issuance alongside them, not the heartbeat/alert-delivery components themselves | No — qualification infrastructure, not product surface; may be built during the RC cycle (`docs/decisions/0012`) |
| **T-F (upgrade testing)** | Cannot exist before a first release exists to upgrade *from* — `rc.1` is the precondition for T-F, not something T-F blocks (`docs/decisions/0011`) | Yes, once a prior release exists |
| **Real public certificate issuance against a real domain** | `tests/profiles/t-a-public-tls.sh` proves issuer-independence and a genuine ACME network interaction (reaching the `Order` stage); reaching the DNS-01 solver and an actual signed certificate require a real public domain and are deliberately left to `capabilities/public-tls/verify-live.sh`, operator-run, not CI-executed. This is a permanent evidence-boundary, not a temporary gap — see that script's own header. | No — by design, not a gap to close |
| **Self-service identity recovery / passkey support** | The shipped configuration specifically proves it exposes **no** unauthenticated recovery path at all (`tests/profiles/t-b-standard.sh`'s `identity-adversarial-recovery` check) — self-service recovery is not configured, by design. Passkey/WebAuthn support was explored, untested, only in a private, non-SCRAP reference deployment; SCRAP's own Blueprint neither provisions nor tests it. Any documentation implying otherwise is wrong and should be corrected on sight. | No — this is a design choice (operator-mediated recovery), not a missing feature; but claiming otherwise is a documentation defect regardless |

## DEFERRED / OPTIONAL / POST-v1

| Item | Why |
|---|---|
| `scrap-patterns` companion repository | Explicitly not a v1 requirement (design record) |
| Talos as a host OS target | Documented extension/breadcrumb for a future version |
| Renovate / automated version-bump PRs | Tracked as "can be decided later," not a v1 requirement |
| A platform web UI | Explicitly out of scope (`docs/out-of-scope/README.md`) |
| Multi-node, HA, multi-cluster/fleet, distributed storage, multi-tenancy | Explicitly out of scope (`docs/out-of-scope/README.md`) |
| Dedicated R5 (account/credential loss) acceptance testing | No frozen test profile is tied to R5 specifically; the structural mitigation (dual age recipients) is already proven. Left here deliberately rather than assigned a target — resolving this further would be inventing a decision the frozen architecture doesn't make. |

## Deliberately unresolved ambiguities

Recorded here rather than silently decided one way or the other:

- **Whether T-E must complete before `rc.1` or only before final v1** is settled by
  `docs/decisions/0011-release-candidate-policy.md` in favor of the latter — but that ADR itself
  notes this is a policy choice filling a gap the frozen architecture left open, not a reading
  forced by the frozen text. If that policy is ever revisited, it should be revisited as a policy
  decision, not reinterpreted quietly.
- **Whether the Topology B generator is release-candidate-blocking or final-v1-blocking** — was
  flagged here as unresolved (`docs/decisions/0009-repository-topology.md` says "Required for v1"
  without an explicit RC/final split, and an earlier revision of this document placed it at
  final-v1 without an ADR licensing that placement). **Resolved 2026-08-22 by
  `docs/decisions/0012-rc-implementation-envelope.md`: release-candidate-blocking**, on the same
  footing as the other unimplemented intended-v1 surfaces — a candidate may defer proof, never
  existence.
