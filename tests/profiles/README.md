# tests/profiles/

Not yet implemented. Dynamic, cluster-backed acceptance profiles — deliberately never testing only
the fully-loaded configuration, since the minimum is what most users start from and what's most
likely to silently rot.

| Profile | Trigger | Asserts |
|---|---|---|
| **T-A — Minimal** | every PR | From-zero bootstrap; every `Kustomization` Ready; private CA issues a certificate; an example P1 application reachable over TLS; backup to local path; a destructive restore verified by a specific, named value through the real ingress path; a test alert reaches the observability surface |
| **T-B — Standard** | every PR | T-A plus Grafana, logs, identity; P2/P3 auth flows; an adversarial auth test — an unauthenticated request must not reach a protected app, and any account-recovery flow must require real verification |
| **T-C — Connected** | nightly | Off-site backup; ACME issuance via DNS-01 against a real test zone; heartbeat delivery |
| **T-D — arm64 minimal** | nightly | T-A, on arm64 |
| **T-E — Host-loss rehearsal (R3)** | pre-release | Blank machine + only the artifacts the recovery model says survive → platform and data restored. Runs on plain QEMU/libvirt or a generic cloud VM — **never** a private cloud, so the procedure can't quietly depend on infrastructure most users don't have |
| **T-F — Upgrade** | pre-release | Previous release → current; data intact; rollback works |

Implementation tracked in the repository root `README.md` roadmap.
