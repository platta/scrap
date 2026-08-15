# docs/out-of-scope/

**OUT OF SCOPE.** Explicitly not this project's responsibility for v1 — but "out of scope" never
means "hostile to." Each row below stays reachable; SCRAP just doesn't test it or claim it works,
and says exactly which guarantee lapses if you go there.

| Area | v1 stance | Not prevented | Guarantees that stop applying | Breadcrumb |
|---|---|---|---|---|
| **Multiple nodes** | Out of scope | Kubernetes permits joining agents; nothing blocks it | All scheduling, placement, and storage guarantees. Backup jobs assume co-location with their PVC. | Node labels and PV node-affinity are documented in `platform/storage/`; k3s's own multi-node docs cover the join mechanics |
| **HA / control-plane redundancy** | Out of scope | k3s supports embedded-etcd HA | Every RTO figure in `docs/core/recovery-model.md` | k3s's own HA documentation; SCRAP's recovery model assumes rebuild-from-Git, not quorum restore |
| **Multi-cluster / fleet management** | Out of scope | SCRAP can be deployed independently to any number of clusters | Nothing — each instance is fully guaranteed on its own | Fleet orchestration is explicitly a different layer and a different project |
| **Distributed / replicated storage** | Out of scope | `platform/storage/`'s `StorageClass` boundary is a documented extension point | Node-pinning assumptions; the tested restore path | `docs/extensions/README.md`'s storage row — Longhorn/Ceph as directions; replication is not a substitute for backup |
| **Multi-tenancy** | Out of scope | Namespaces provide some isolation already | All isolation claims — SCRAP makes none | SCRAP assumes one trusted operator; no NetworkPolicy isolation, no per-tenant RBAC, no quota model is provided |
| **Image build pipelines for user applications** | Out of scope | Nothing prevents it | — | Renovate (once implemented) handles version bumps for pinned images; building your own images is entirely your own tooling |
| **A platform web UI** | Out of scope, deliberately | Nothing prevents running one alongside SCRAP | — | A UI over GitOps state was a real, previously-observed source of configuration drift — see `docs/decisions/` |
| **General host management beyond `bootstrap/`** | Out of scope | The host may run unrelated services | SCRAP claims specific ports, one storage path, and one pod/service CIDR range — nothing else | `bootstrap/README.md` and the host-coexistence section it points to |

This list is not exhaustive. If something you need isn't here and isn't documented as CORE,
SUPPORTED, or an EXTENSION, treat it as unsupported and worth asking about, not silently assumed.
