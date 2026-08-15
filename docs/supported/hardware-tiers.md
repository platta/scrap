# Hardware tiers

**FULLY SUPPORTED.** A capability being optional doesn't mean its cost is hidden.

| Tier | RAM | What it runs | Notes |
|---|---|---|---|
| **Minimum** | 4 GB | `platform/` only — the `minimal` profile | 2 cores, 32 GB SSD, x86-64 or arm64 |
| **Standard** | ~6–8 GB | + Grafana, logs, alert delivery | Comfortable headroom for a handful of small applications |
| **Identity-enabled** | ≥ 8 GB | + Authentik (`capabilities/identity/`) | Authentik alone measures roughly 6–7× a lightweight alternative's footprint — see `docs/decisions/0002-identity-implementation.md` for why that cost was accepted |

These are measured, not guessed, once implementation reaches the point of publishing real numbers
— tracked in the repository root `README.md` roadmap. Until then, treat this table as directional.
