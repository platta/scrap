# tests/

| Directory | What it holds | Status |
|---|---|---|
| [`assertions/`](assertions/) | Fast, static, structural CI checks — enforce T1/T2 and the application contract on every pull request. No cluster required. | **Implemented** — this milestone |
| [`fixtures/`](fixtures/) | Deliberately-broken repository trees proving each assertion actually catches what it claims to | **Implemented** — this milestone |
| [`profiles/`](profiles/) | Dynamic, cluster-backed acceptance profiles (T-A minimal through T-F upgrade) | **T-A implemented**; **T-B implemented** for identity + P2/P3 + Grafana + the recovery-flow-abuse adversarial check (logs was also part of the originally-scoped T-B definition and remains open only because that capability doesn't exist yet, not a T-B gap); **T-A-public-tls implemented**; **T-A-offsite-backup implemented** (proves artifact placement, not R3 — see `docs/release-readiness.md`); T-C, T-D, T-E, T-F not yet |
| [`dr/`](dr/) | Disaster-recovery rehearsals | **R1 implemented** — a genuinely destructive restore of identity's own multi-tier Authentik + PostgreSQL, nightly (see `dr/README.md`); the host-loss (R3) blank-machine test (T-E) not yet, and must not be inferred from off-site backup alone |

See [`docs/core/recovery-model.md`](../docs/core/recovery-model.md) for exactly which recovery
claim each future dynamic profile is meant to prove, [`docs/release-readiness.md`](../docs/release-readiness.md)
for the current proven/unproven/deferred boundary, and
[`docs/decisions/`](../docs/decisions/) for why static structural checks came first — see the
repository root `README.md`'s build-order rationale.
