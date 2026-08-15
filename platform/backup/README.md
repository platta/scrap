# platform/backup/

**Tier 2.** Depends on `platform/crds/` and `platform/storage/` (mounts PVCs directly — never a
node's raw storage path).

The platform-owned restic backup engine: credentials, schedule policy, retention, **exactly one**
prune job, and **exactly one** integrity-check job, for the entire installation. This is a direct
structural fix for a real defect: eight independent, per-application CronJobs each running their own
`restic forget --prune` against a shared repository, colliding on schedule and each capable of
evicting another's snapshots.

## The application contract

An application does not write its own backup CronJob. It:

1. Labels its PVC `backup.scrap.io/enabled: "true"`.
2. Optionally includes `components/backup/` and declares a consistency method — a database logical
   dump command, a quiesce command, or nothing (plain file copy is the honest default for
   stateless-enough data).

Discovery is label-based, matching the same convention as the metrics contract in
`platform/observability/`. Adding a stateful application never means editing a script or a
hand-maintained list.

## Destination

The backup **destination** is configurable and does not change this contract:

- **Minimum**: a local path or second disk — buys recovery from application-data loss and disk
  loss, not host loss.
- **Fully supported**: a LAN target (a second machine, a NAS) or an off-site S3-compatible endpoint
  (`capabilities/offsite-backup/`) — buys host-loss and site-loss recovery respectively.

See `docs/core/recovery-model.md` for exactly which failure class each destination choice actually
buys — SCRAP states this as a tested, progressive guarantee, never a blanket "we have backups."

## Credential isolation

A backup credential must be scoped so it **cannot** modify another installation's backups, even by
accident. This directory's credential handling — and the documentation for anyone standing up a
second (e.g. test/scratch) SCRAP instance — treats this as an authorization boundary, not a naming
convention. See `docs/decisions/` for the incident that made this a first-class requirement.
