# SCRAP documentation

Documentation is organized by **status**, not just by topic, so it is difficult to mistake
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
[`core/recovery-model.md`](core/recovery-model.md).

| Capability | Status | New assumptions it introduces | Unlocks |
|---|---|---|---|
| Kubernetes, Flux, secrets, storage, routing, TLS, backup engine, observability core | **CORE** | Internet once, at install | R0 (workload) · R1 (app data) · R2 (disk loss) |
| Grafana | SUPPORTED | none beyond core | — (operational only) |
| Logs (Loki + Alloy) | SUPPORTED | none beyond core | — (operational only) |
| Alert delivery (SMTP/ntfy/webhook) | SUPPORTED | a reachable receiver | makes existing alerts actionable |
| Public TLS (ACME/DNS-01) | SUPPORTED | domain + DNS zone + provider API + internet | client/workload trust, no CA to install |
| Public ingress | SUPPORTED | public IP or tunnel, router control, larger threat model | public reachability |
| Off-site backup | SUPPORTED | S3-compatible endpoint + credential + internet | **R3 (host loss)**, contributes to R4 |
| External Git hosting | SUPPORTED | account + internet | **R3 (host loss)** of the source of truth |
| External heartbeat | SUPPORTED | internet + free account | tells you the *cluster* is down |
| Identity (Authentik) | SUPPORTED, OPTIONAL | ~1 GB RAM, a Postgres to back up | SSO, self-service recovery, passkeys |
| UPS (NUT) | SUPPORTED | a UPS with a data connection | corruption protection on power loss |
| Alternative identity, storage, ingress, issuer, backup engine, K8s distro | EXTENSION | varies — see `extensions/` | varies, and untested |
| Multi-node, HA, multi-cluster, distributed storage, multi-tenancy | OUT OF SCOPE | — | not guaranteed; see `out-of-scope/` |

## Everything else

- [`decisions/`](decisions/) — architecture decision records, including rejected alternatives and
  why. The authoritative history of *why* SCRAP is shaped the way it is.
- [`patterns/`](patterns/) — the six application integration patterns every application in this
  repository is classified by.
- [`runbooks/`](runbooks/) — operational and disaster-recovery procedures. Sparse today; grows
  alongside `tests/dr/`.
