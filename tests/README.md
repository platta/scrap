# tests/

| Directory | What it holds | Status |
|---|---|---|
| [`assertions/`](assertions/) | Fast, static, structural CI checks — enforce T1/T2 and the application contract on every pull request. No cluster required. | **Implemented** — this milestone |
| [`fixtures/`](fixtures/) | Deliberately-broken repository trees proving each assertion actually catches what it claims to | **Implemented** — this milestone |
| [`profiles/`](profiles/) | Dynamic, cluster-backed acceptance profiles (T-A minimal through T-F upgrade) | **T-A implemented**; **T-B partially** (identity + P2/P3 + adversarial check); T-C–T-F not yet |
| [`dr/`](dr/) | Disaster-recovery rehearsals, including the host-loss (R3) blank-machine test | Not yet implemented |

See [`docs/core/recovery-model.md`](../docs/core/recovery-model.md) for exactly which recovery
claim each future dynamic profile is meant to prove, and
[`docs/decisions/`](../docs/decisions/) for why static structural checks came first — see the
repository root `README.md`'s build-order rationale.
