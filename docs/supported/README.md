# docs/supported/

**FULLY SUPPORTED, architecturally.** For deciding what to enable. This mirrors
`capabilities/README.md` but is written for a reader choosing a configuration, not a contributor
navigating the repository — see that file for the directory-by-directory technical detail,
including which of these are implemented today versus designed-but-not-yet-built. Every capability
listed here is *intended* to be designed, configured, documented, tested, and maintained by this
project; enabling an implemented one is not required, but a failure in it is a SCRAP bug, exactly
like a failure in `platform/`. See the Status column below and `docs/release-readiness.md` for the
current, authoritative proven/unproven/deferred boundary.

| Capability | What you get | What it costs you | Status | Docs |
|---|---|---|---|---|
| Grafana | Dashboards over the core Prometheus | ~250–400 MB RAM | **Implemented, live-tested** | `capabilities/grafana/` |
| Identity (Authentik) | SSO via native OIDC and gateway forward-auth; **operator-mediated** account recovery only — SCRAP's shipped configuration specifically proves it exposes no unauthenticated self-service recovery path, and does not configure or test passkey/WebAuthn login | ~1 GB RAM, a Postgres to back up | **Implemented, live-tested** | [`hardware-tiers.md`](hardware-tiers.md), `capabilities/identity/` |
| Public TLS | Certificates every browser already trusts, no CA to install | a domain + DNS zone + provider API | **Implemented, live-tested** (issuer-independence and the ACME network interaction are CI-proven; issuance against a real public domain is operator-verified, not CI) | `capabilities/public-tls/` |
| Off-site backup | Recovery artifacts placed off-host, independent of this machine's own failure domain — one of R3's two required ingredients | an S3-compatible endpoint + credential | **Implemented, live-tested** (proves artifact placement; R3 itself — a blank host actually rebuilding from those artifacts — is proven only by T-E, not yet implemented; see `capabilities/offsite-backup/README.md`) | `capabilities/offsite-backup/` |
| Logs | Centralized, searchable pod logs | ~200–700 MB RAM | **Implemented, live-tested** | `capabilities/logs/` |
| Alert delivery | Alerts that actually reach you | a reachable webhook receiver (ntfy, or anything Alertmanager itself supports) | **Implemented, live-tested** (a real webhook delivery to an ephemeral receiver is CI-proven; a real third-party provider's own API acceptance is operator-verified, not CI) | `capabilities/alert-delivery/` |
| Public ingress | Reachable from the internet | public IP or tunnel, larger threat model | **Designed, not yet implemented** — README only, no manifests | `capabilities/public-ingress/` |
| External heartbeat | Told when the *cluster itself* is down | a free third-party account | **Implemented, live-tested** (the conditional push mechanism, both healthy and withheld, is CI-proven against an ephemeral receiver; a real provider's own missed-ping alarm/notification is operator-verified, not CI) | `capabilities/heartbeat/` |
| Dynamic DNS | Keeps a DNS record pointed at a changing IP | a dynamic-DNS-capable domain/provider | **Designed, not yet implemented** — README only, no manifests | `capabilities/dyndns/` |
| UPS integration | Graceful shutdown on power loss | a UPS with a data connection | **Designed, not yet implemented** — README only, no manifests | `capabilities/ups/` |

None of these are enabled by default in the checked-in `minimal` profile
(`clusters/example/`). See `docs/core/configuration-model.md` for how enabling one actually works.
