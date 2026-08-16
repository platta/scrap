# 0003 — Backup job generation mechanism

**Decision:** backup execution is **one platform-owned `CronJob` running a discovery script**
(`platform/backup/`), not a custom controller and not an adopted third-party operator (Velero,
k8up). `components/backup/` is a thin Kustomize component an application includes only to attach the
discovery label — it generates no job of its own.

## Reasoning

A controller — something with a reconcile loop, a watch, leader election — is more machinery to
build and maintain than the problem justifies at SCRAP's scale: one node, a modest number of
stateful applications, backups running once a day. A `CronJob` running a plain shell script is
boring, requires no new long-running process, and is fully legible: `kubectl get cronjob -o yaml`
shows exactly what runs and when, no SCRAP-specific abstraction standing between the operator and
what's actually happening (see the transparency principle,
`0008-abstract-decisions-not-technologies.md`).

**Earlier drafts of this decision described a per-application generated `CronJob`** — every app
including a component and getting its own backup job. Implementation surfaced a better fit for the
same "no controller" constraint: a **single** job, run once, that lists every PVC labelled
`backup.scrap.io/enabled: "true"` cluster-wide (`kubectl get pvc -A -l ...`) and backs each one up in
turn. This is *more* consistent with the original goal, not less — it's what makes "exactly one
prune job and one check job" (the actual defect this decision exists to fix) coherent: prune and
check already had to be singular and repository-wide, and a per-app backup job sitting next to
singular prune/check jobs would have been the odd one out. `components/backup/` shrank accordingly:
it adds the label (and documents two annotations for a consistency method), nothing else. See
`platform/backup/README.md` for the full discovery mechanism.

Velero was considered and set aside: it's built around CSI volume snapshots, which k3s's built-in
`local-path` storage implementation (SCRAP's CORE, zero-build default) doesn't support, so its real
mechanism on SCRAP would end up being a node-agent restic/kopia integration anyway — materially more
machinery for the same outcome a plain `CronJob` already provides.

## Revisit condition

If the backup contract strains — for example, if consistency-method declarations become complex
enough that annotations can't express them cleanly, or discovery cost grows unacceptably with PVC
count — revisit toward a small controller. Not expected at v1 scale.
