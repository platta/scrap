# capabilities/

**FULLY SUPPORTED, architecturally** — every capability listed here is *intended* to be designed,
configured, documented, tested, and maintained by this project, and a failure in an *implemented*
one is a SCRAP bug, exactly like a failure in `platform/`. That classification is about intent, not
a claim that every row below already has manifests behind it — see the Status column: several are
implemented and live-tested today; others are currently README-only design documents with no
manifests to enable at all. `docs/release-readiness.md` is the authoritative current snapshot; this
table is kept in sync with it. None of these capabilities are required. Several implemented ones
are on by default in the documented `standard` profile (`clusters/example/capabilities/`); all are
off by default in the `minimal` profile.

**Enabling a capability is copying its Flux `Kustomization` file(s) into
`clusters/<name>/capabilities/`. Disabling it is deleting them.** One file for a capability with no
credential of its own; two for one that has a credential (the credential itself lives under
`clusters/<name>/secrets/`, never here — see `capabilities/identity/README.md`'s "Enabling this
capability" section for the concrete pair). No flags, no templating language, no SCRAP-specific
configuration format — see `docs/core/configuration-model.md`. Two recorded exceptions:
`ups/`'s host half (the NUT daemon holding shutdown authority) is enabled by an operator-run
`bootstrap/host/` script, not a Kustomization — decided in
`docs/decisions/0013-ups-shutdown-authority.md`, which also makes explicit that no capability
workload ever runs privileged or holds host power authority; and `public-ingress/`, which is
operator-edge configuration end to end — enabled by performing its documented router/DNS
procedure, disabled by removing the forwards, deliberately shipping no manifest at all — decided
in `docs/decisions/0014-public-ingress-edge-authority.md`, which also outlaws inert placeholder
manifests generally.

## The one rule that applies to every directory here

> A capability may depend on `platform/` (tier ≤2). It may **never** be depended on by `platform/`.

This is the direct fix for a real defect in the reference implementation: a monitoring Kustomization
that `dependsOn` an identity application, so deleting the identity application broke the entire
observability stack. CI checks this on every pull request (`tests/assertions/`).

## Capabilities

| Directory | Provides | Default in `standard` profile | Status |
|---|---|---|---|
| [`grafana/`](grafana/) | Dashboards over the core Prometheus | on | **Implemented, live-tested** |
| [`identity/`](identity/) | Centralized SSO — Authentik: native OIDC + gateway forward-auth | off | **Implemented, live-tested** |
| [`public-tls/`](public-tls/) | Publicly-trusted certificates via ACME/DNS-01 — the same wildcard shape as the private CA | off | **Implemented, live-tested** (real-domain certificate issuance is operator-verified, not CI — see the directory's own README) |
| [`offsite-backup/`](offsite-backup/) | S3-compatible off-site backup destination — places recovery artifacts off-host, one of R3's two required ingredients | off | **Implemented, live-tested** (proves artifact placement, not host-loss recovery itself — see `docs/release-readiness.md`) |
| [`logs/`](logs/) | Centralized pod logs (Loki + Alloy), correlated with metrics | on | **Implemented, live-tested** |
| [`alert-delivery/`](alert-delivery/) | A real Alertmanager receiver (webhook — ntfy, or anything Alertmanager itself supports) | on | **Implemented, live-tested** |
| [`public-ingress/`](public-ingress/) | Reachable from the public internet | off | **Implemented, live-tested** (ships no manifest by design — `docs/decisions/0014-public-ingress-edge-authority.md`; live public reachability of a real install is operator-verified, not CI — see the directory's own README) |
| [`heartbeat/`](heartbeat/) | External dead-man's-switch — the only way to know the cluster itself is down | off | **Implemented, live-tested** |
| [`dyndns/`](dyndns/) | Keeps a DNS record pointed at a changing IP | off | **Implemented, live-tested** |
| [`ups/`](ups/) | Graceful shutdown on power loss (NUT) | off | **Implemented, live-tested** (the host half — the actual shutdown authority — is an operator-run script, not a Kustomization; see that directory's own README) |

`ups/`, above, is a different case from every other implemented capability: it ships two halves
with two different enabling mechanisms (see the "Two recorded exceptions" paragraph above). The
in-cluster half is the normal Kustomization-copy; the host half — the actual shutdown authority —
is `bootstrap/host/install-nut.sh`, run directly, never a file copied into `clusters/<name>/`.
`public-ingress/`, above, is a different case again: it's fully implemented, but its own
`README.md` documents an operator-run procedure end to end, never a file to copy in at all — see
that directory's own README, and `docs/decisions/0014-public-ingress-edge-authority.md`, for why.
See `docs/supported/` for the consolidated version of this same information, organized for a
reader deciding what to enable rather than for a contributor.
