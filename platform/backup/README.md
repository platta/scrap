# platform/backup/

**Tier 2.** No dependency on `platform/crds/` -- everything here (`CronJob`, `ServiceAccount`,
`ClusterRole`, `Namespace`, `Secret`) is a built-in Kubernetes API type, not a CRD. The dependency
with `clusters/<name>/secrets/` runs the other way: `platform-secrets`'s Flux Kustomization
dependsOn `platform-backup`, because the Secret it applies needs this directory's `scrap-backup`
Namespace to exist first. The CronJobs' `secretKeyRef` doesn't need the Secret to exist at apply
time either way -- only when a pod actually starts, which is always later. See
`clusters/example/platform-secrets.yaml` for the real ordering bug this caught.

The platform-owned restic backup engine: credentials, schedule policy, retention, **exactly one**
backup job, **exactly one** prune job, and **exactly one** integrity-check job, for the entire
installation. This is a direct structural fix for a real defect: eight independent, per-application
CronJobs each running their own `restic forget --prune` against a shared repository, colliding on
schedule and each capable of evicting another's snapshots.

## The application contract

An application does not write its own backup CronJob and never sees a restic credential. It:

1. Labels its PVC `backup.scrap.io/enabled: "true"` -- directly, or via `components/backup/`.
2. Optionally declares a consistency method via two annotations on that PVC (see
   `components/backup/README.md`) -- a database logical dump command, a quiesce command, or nothing
   (plain file copy is the honest default for stateless-enough data).

## Discovery mechanism (D3: a CronJob running a script, not a controller)

Once daily, `scrap-backup`'s job:

1. Lists every PVC, cluster-wide, labelled `backup.scrap.io/enabled: "true"` (`kubectl get pvc -A
   -l ...`) -- no hand-maintained list, matching the same label-driven convention as the metrics
   contract in `platform/observability-config/`.
2. For each one, reads its bound `PersistentVolume`'s **real, provisioner-written path** -- not a
   reconstructed naming convention. Checked against a live PV, not assumed from the API schema:
   k3s's built-in `local-path-provisioner` (what SCRAP's core storage contract uses -- see
   `docs/decisions/`, storage is a CORE contract with a zero-build implementation) writes
   `spec.local.path`, not `spec.hostPath.path` -- both are valid `PersistentVolume` fields, but only
   one is what this provisioner actually populates. The script tries `local.path` first, falls back
   to `hostPath.path` for any other provisioner that does use it, and skips with a warning if
   neither is under the expected root -- a CSI-backed `StorageClass` (an EXTENSION) needs its own
   backup approach.
3. Runs any declared consistency command in the app's own pod first (`kubectl exec`).
4. Runs `restic backup` against the resolved path, tagged `namespace=<ns>`, `pvc=<name>`, and
   `--host ${INSTANCE_NAME}`.

The discovery+backup script is in `scripts-configmap.yaml`, not inlined in the CronJob, so it reads
like a normal shell script. The pod combines two upstream images -- `restic/restic` (vendors a
static `restic` binary into a shared `emptyDir` via an init container) and `alpine/k8s` (`kubectl` +
`sh` -- `kubectl`'s own `-o jsonpath` covers everything this script needs, so `jq`, also bundled in
that image, goes unused) -- rather than SCRAP building and publishing its own image.

## Destination

The backup **destination** is configurable via `${BACKUP_DESTINATION}` and does not change this
contract:

- **Minimum**: a local path or second disk (`local:/var/lib/scrap-backup`, the shipped default) --
  buys recovery from application-data loss and disk loss, not host loss. `backup-cronjob.yaml`,
  `prune-cronjob.yaml`, and `check-cronjob.yaml` all mount `/var/lib/scrap-backup` on the host to
  serve this default; if you relocate the local destination, update those mounts to match.
- **Fully supported**: a LAN target (a second machine, a NAS) or an off-site S3-compatible endpoint
  (`capabilities/offsite-backup/`, implemented and live-tested -- see that directory's own README)
  -- places the backup artifacts off the single host, one of the two ingredients host-loss (R3) and
  site-loss (R4) recovery need. Placing the artifact is not the same claim as proving the recovery:
  R3/R4 themselves are proven only by a host-loss rehearsal (T-E), not yet implemented -- see
  `docs/core/recovery-model.md`'s own "R3/R4 specifically" section and `docs/release-readiness.md`.

See `docs/core/recovery-model.md` for exactly which failure class each destination choice actually
buys -- SCRAP states this as a tested, progressive guarantee, never a blanket "we have backups."

## Prune and check -- exactly one of each

`prune-cronjob.yaml` runs `restic forget --host ${INSTANCE_NAME} --keep-daily/-weekly/-monthly
--prune` weekly. `check-cronjob.yaml` runs `restic check --read-data-subset=5%` monthly. Both are
genuinely singular: there is no per-application variant of either, and no application manifest ever
references them.

## Every job here is bounded, not just scheduled

**REAL BUG, found live via `capabilities/offsite-backup/`'s own negative control**: with a
genuinely wrong credential against a real S3 endpoint, restic's own retry/backoff behavior doesn't
fail fast -- a pod sat `Running` for minutes with no sign of terminating on its own, and nothing
here previously bounded that. `backoffLimit` alone doesn't help; it bounds pod *restarts* after a
container exits, not how long one attempt is allowed to keep running. `concurrencyPolicy: Forbid`
on all three CronJobs means an unbounded hang here also silently blocks every future scheduled run
from ever starting -- a stuck backup becomes "no backups at all," which is worse than a fast,
visible failure. Every CronJob here sets `activeDeadlineSeconds: ${BACKUP_JOB_DEADLINE_SECONDS}` --
an **instance-configurable** value (`clusters/<name>/instance-config.yaml`, default 600 = 10
minutes), not a value hardcoded into this platform-owned manifest. That distinction matters: a
fixed platform-code value would have meant a real install whose off-site backups (or a prune/check
against a genuinely large repository) legitimately need longer than this reference instance's own
tiny example workloads (confirmed live: a real backup here completes in single-digit seconds) could
only raise the ceiling by editing `platform/` directly -- exactly the instance-configuration
violation `docs/core/configuration-model.md` exists to prevent. Raise
`BACKUP_JOB_DEADLINE_SECONDS` in your own instance config instead; short enough by default that a
genuinely stuck attempt still resolves to a visible `Job` failure (`DeadlineExceeded`) instead of
running forever.

## Credential isolation

A backup credential must be scoped so it **cannot** modify another installation's backups, even by
accident. Two things enforce this together:

- **Every snapshot and every `forget` invocation carries `--host ${INSTANCE_NAME}`** -- an instance
  identity, never an application name, set once in `clusters/<name>/instance-config.yaml`. restic's
  default `forget` grouping is `host,paths`, so even a repository accidentally shared between two
  instances can't have one instance's prune touch another's snapshots.
- **The credential itself should be instance-scoped**, not shared-with-a-different-prefix. Where the
  destination provider supports per-prefix or per-bucket credentials, use them; where it doesn't, use
  a separate bucket/path per instance. This directory's `secretKeyRef` always points at
  `clusters/<name>/secrets/restic-credentials.sops.yaml` -- there is deliberately no mechanism here
  for pointing two instances' Kustomizations at the same credential.

See `docs/decisions/0010-backup-credential-isolation.md` for the incident that made this a
first-class requirement, not a convention.
