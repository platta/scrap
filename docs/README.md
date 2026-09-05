# SCRAP documentation

**New here?** You don't need anything on this page to install SCRAP or add your first
application. Start with [Getting started](getting-started.md), then
[Choosing your capabilities](choosing-capabilities.md) and
[Adding an application](adding-an-application.md). Come back here when you want the deeper
technical picture — architecture, the full capability contract, and how SCRAP's claims are
verified.

This page itself is organized by **status**, not just by topic, so it is difficult to mistake
*possible* for *supported*. Every capability page opens with one of these four labels:

- **CORE** — [`core/`](core/). Mandatory. Present in every SCRAP install. Removing it isn't a
  configuration choice.
- **FULLY SUPPORTED** — [`supported/`](supported/). Optional, but designed, configured,
  documented, tested, and maintained by this project. A failure here is a SCRAP bug.
- **EXTENSION POINT** — [`extensions/`](extensions/). A deliberate boundary where an advanced user
  can substitute or add something. The *contract* is documented; the *implementation* is not
  tested or promised.
- **OUT OF SCOPE** — [`out-of-scope/`](out-of-scope/). Explicitly not this project's
  responsibility — but never hostile to. Each page states the boundary and where to look next.

Start with **[Understanding SCRAP](understanding-scrap.md)** — a 10–15 minute conceptual
walkthrough of every layer, why SCRAP chose what it chose, and where to go to learn the real
technology underneath. Read it before anything else here.

## The capability matrix

What you get, what it costs, and which recovery guarantee it unlocks. Full detail:
[`core/recovery-model.md`](core/recovery-model.md) for recovery classes, and
[`release-readiness.md`](release-readiness.md) for the current, authoritative
proven/unproven/deferred snapshot behind the "Implemented?" column below.

| Capability | Status | Implemented? | New assumptions it introduces | Unlocks |
|---|---|---|---|---|
| Kubernetes, Flux, secrets, storage, routing, TLS, backup engine, observability core | **CORE** | Yes, live-tested | Internet once, at install | R0 (workload) · R1 (app data) · R2 (disk loss) |
| Grafana | SUPPORTED | Yes, live-tested | none beyond core | — (operational only) |
| Public TLS (ACME/DNS-01) | SUPPORTED | Yes, live-tested (real-domain issuance is operator-verified, not CI) | domain + DNS zone + provider API + internet | client/workload trust, no CA to install |
| Off-site backup | SUPPORTED | Yes, live-tested | S3-compatible endpoint + credential + internet | Places recovery artifacts off-host — **one of R3's two required ingredients, not R3 itself.** R3 (host loss) is proven only by a host-loss rehearsal (T-E), not yet implemented |
| External Git hosting | SUPPORTED | Yes, via `bootstrap/install.sh`'s `REPO_URL` (no dedicated capability file) | account + internet | Moves the source of truth off-host — the *other* of R3's two required ingredients, same caveat as above |
| Identity (Authentik) | SUPPORTED, OPTIONAL | Yes, live-tested | ~1 GB RAM, a Postgres to back up | SSO via native OIDC and forward-auth. **Operator-mediated account recovery only** — the shipped configuration specifically proves no unauthenticated self-service recovery path exists, and passkey/WebAuthn login is neither configured nor tested |
| Logs (Loki + Alloy) | SUPPORTED | Yes, live-tested | ~200–700 MB RAM | — (operational only; not part of the recovery model) |
| Alert delivery (webhook — ntfy, or anything Alertmanager supports) | SUPPORTED | Yes, live-tested (real delivery to an ephemeral receiver is CI-proven; a real third-party provider's own API acceptance is operator-verified, not CI) | a reachable webhook receiver | makes existing alerts actionable |
| Public ingress | SUPPORTED | Yes, live-tested (ships no manifest by design, `docs/decisions/0014` — an operator-run runbook + verification script; verify-live.sh's own certificate-identity oracle is CI-proven both green and red; live public reachability of a real install is operator-verified, not CI) | public IP + router control, larger threat model | public reachability |
| External heartbeat | SUPPORTED | Yes, live-tested (the conditional push mechanism is CI-proven; a real provider's own missed-ping alarm/notification is operator-verified, not CI) | internet + free account | tells you the *cluster* is down |
| Dynamic DNS | SUPPORTED | Yes, live-tested (a real RFC2136 update against an ephemeral nameserver, both positive and a wrong-credential negative control, is CI-proven) | a dynamic-DNS-capable domain/provider + internet | keeps a changing public IP's DNS record current |
| UPS (NUT) | SUPPORTED | Yes, live-tested (host shutdown authority is an operator-run script per ADR-0013; kubelet Graceful Node Shutdown genuinely armed and verified; physical UPS hardware behavior under a real outage is operator-verified, not CI) | a UPS with a data connection | corruption protection on power loss |
| Alternative identity, storage, ingress, issuer, backup engine, K8s distro | EXTENSION | n/a — contract only | varies — see `extensions/` | varies, and untested |
| Multi-node, HA, multi-cluster, distributed storage, multi-tenancy | OUT OF SCOPE | n/a | — | not guaranteed; see `out-of-scope/` |

## Everything else

- [`decisions/`](decisions/) — architecture decision records, including rejected alternatives and
  why. The authoritative history of *why* SCRAP is shaped the way it is.
- [`patterns/`](patterns/) — the six application integration patterns every application in this
  repository is classified by.
- [`runbooks/`](runbooks/) — operational and disaster-recovery procedures. Sparse today; grows
  alongside `tests/dr/`.
- [`reviews/`](reviews/) — point-in-time review artifacts (adoption readiness, audits), each
  pinned to the exact commits it evaluated.
- [`engineering-evidence.md`](engineering-evidence.md) — how SCRAP knows its claims are true:
  structural checks vs. live acceptance profiles, what T-A..T-F and R0–R5 mean, why negative
  controls and exact-SHA release gates exist.
