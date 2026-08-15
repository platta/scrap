# capabilities/

**FULLY SUPPORTED.** Every capability here is designed, configured, documented, tested, and
maintained by this project — a failure here is a SCRAP bug, exactly like a failure in `platform/`.
None of them are required. Several are on by default in the documented `standard` profile
(`clusters/example/capabilities/`); all are off by default in the `minimal` profile.

**Enabling a capability is copying one Flux `Kustomization` file into
`clusters/<name>/capabilities/`. Disabling it is deleting that file.** No flags, no templating
language, no SCRAP-specific configuration format — see `docs/core/configuration-model.md`.

## The one rule that applies to every directory here

> A capability may depend on `platform/` (tier ≤2). It may **never** be depended on by `platform/`.

This is the direct fix for a real defect in the reference implementation: a monitoring Kustomization
that `dependsOn` an identity application, so deleting the identity application broke the entire
observability stack. CI checks this on every pull request (`tests/assertions/`).

## Capabilities

| Directory | Provides | Default in `standard` profile |
|---|---|---|
| [`grafana/`](grafana/) | Dashboards over the core Prometheus | on |
| [`logs/`](logs/) | Centralized pod logs (Loki + Alloy), correlated with metrics | on |
| [`identity/`](identity/) | Centralized SSO — Authentik: native OIDC + gateway forward-auth | off |
| [`public-tls/`](public-tls/) | Publicly-trusted certificates via ACME/DNS-01 — the same wildcard shape as the private CA | off |
| [`public-ingress/`](public-ingress/) | Reachable from the public internet | off |
| [`offsite-backup/`](offsite-backup/) | S3-compatible off-site backup destination — buys site-loss recovery | off |
| [`heartbeat/`](heartbeat/) | External dead-man's-switch — the only way to know the cluster itself is down | off |
| [`dyndns/`](dyndns/) | Keeps a DNS record pointed at a changing IP | off |
| [`ups/`](ups/) | Graceful shutdown on power loss (NUT) | off |

Each directory's `README.md` states exactly what enabling it adds and what new external
assumptions it introduces — see `docs/supported/` for the consolidated version of the same
information, organized for a reader deciding what to enable rather than for a contributor.
