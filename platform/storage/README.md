# platform/storage/

**Tier 2.** No dependencies beyond `platform/crds/`.

The storage **contract** is CORE: applications get persistent storage via ordinary
`PersistentVolumeClaim` objects. The storage **implementation** is intentionally the smallest thing
that satisfies that contract: k3s's bundled `local-path` provisioner, taken as-is. SCRAP builds
nothing here.

## What this deliberately does not do

No distributed or replicated storage in core. Stateful workloads are node-pinned by design, and
their durability comes from **tested backup and restore** (`platform/backup/`), not from
replication. This is a deliberate, defended non-decision — see `docs/decisions/` — not an
oversight, and it's why there is no Longhorn, no NFS, no Ceph anywhere in `platform/`.

## Extension point

Any `StorageClass` satisfying `ReadWriteOnce` PVCs works. Swapping in a CSI driver changes the
node-pinning assumptions and unlocks a snapshot-based restore strategy SCRAP doesn't implement —
documented as an extension point in `docs/extensions/`, not built here.
