# Hardware tiers

**FULLY SUPPORTED.** A capability being optional doesn't mean its cost is hidden.

| Tier | RAM | What it runs | Notes |
|---|---|---|---|
| **Minimum** | 4 GB | `platform/` only — the `minimal` profile | 2 cores, 32 GB SSD, x86-64 (CI-tested); arm64 is an accepted target but not yet CI-verified — see `docs/release-readiness.md` |
| **Standard** | ~6–8 GB | + Grafana, Logs, Alert delivery (all implemented) | Comfortable headroom for a handful of small applications. Grafana adds ~250–400 MB RAM; Logs (Loki + Alloy) adds ~200–700 MB RAM — see `capabilities/logs/README.md`. Alert delivery adds no meaningful footprint of its own — one `AlertmanagerConfig` object, no new workload — see `capabilities/alert-delivery/README.md` |
| **Identity-enabled** | ≥ 8 GB | + Authentik (`capabilities/identity/`) | Authentik alone measures roughly 6–7× a lightweight alternative's footprint — see `docs/decisions/0002-identity-implementation.md` for why that cost was accepted |

These are measured, not guessed, once implementation reaches the point of publishing real numbers
— tracked in the repository root `README.md` roadmap. Until then, treat this table as directional.
