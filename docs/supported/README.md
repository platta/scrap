# docs/supported/

**FULLY SUPPORTED.** For deciding what to enable. This mirrors `capabilities/README.md` but is
written for a reader choosing a configuration, not a contributor navigating the repository — see
that file for the directory-by-directory technical detail.

Every capability listed here is designed, configured, documented, tested, and maintained by this
project. Enabling it is not required, but a failure in it is a SCRAP bug, exactly like a failure in
`platform/`.

| Capability | What you get | What it costs you | Docs |
|---|---|---|---|
| Grafana | Dashboards over the core Prometheus | ~250–400 MB RAM | `capabilities/grafana/` |
| Logs | Centralized, searchable pod logs | ~300 MB RAM | `capabilities/logs/` |
| Alert delivery | Alerts that actually reach you | a reachable SMTP/ntfy/webhook receiver | `capabilities/README.md` |
| Public TLS | Certificates every browser already trusts, no CA to install | a domain + DNS zone + provider API | `capabilities/public-tls/` |
| Public ingress | Reachable from the internet | public IP or tunnel, larger threat model | `capabilities/public-ingress/` |
| Off-site backup | Recovery artifacts placed off-host, independent of this machine's own failure domain — one of R3's two required ingredients (see `capabilities/offsite-backup/README.md`'s own evidence-boundary note; R3 itself is proven by T-E, not yet implemented) | an S3-compatible endpoint + credential | `capabilities/offsite-backup/` |
| External heartbeat | Told when the *cluster itself* is down | a free third-party account | `capabilities/heartbeat/` |
| Identity (Authentik) | SSO, self-service password/MFA recovery, passkeys | ~1 GB RAM, a Postgres to back up | [`hardware-tiers.md`](hardware-tiers.md), `capabilities/identity/` |
| UPS integration | Graceful shutdown on power loss | a UPS with a data connection | `capabilities/ups/` |

None of these are enabled by default in the checked-in `minimal` profile
(`clusters/example/`). See `docs/core/configuration-model.md` for how enabling one actually works.
