# docs/runbooks/

Operational and disaster-recovery procedures. Sparse today — grows alongside `tests/dr/` and
`bootstrap/`, since a runbook that hasn't been executed by an automated test is a claim, not a
guarantee (`docs/core/recovery-model.md`).

**Nothing here should describe a procedure as tested until a CI profile in `tests/dr/` or
`tests/profiles/` actually executes it.** This is a deliberate discipline: the reference
implementation this project's design was derived from once shipped a recovery runbook that said,
in its own text, "do not treat this as tested" for months, while the README pointed to it as *the*
disaster-recovery procedure. That gap is not being repeated here.

Planned first entries, once the corresponding implementation milestone lands:

- Fresh-host bootstrap (mirrors `docs/core/bootstrap-lifecycle.md`, executed for real)
- Single-application destructive restore — see below
- Host-loss rehearsal (R3) — blank machine, only the artifacts the recovery model says survive

## Single-application destructive restore

**Status: manually executed once, end to end, on a real scratch cluster. Not yet a `tests/dr/`
profile run by CI on every change — per this file's own discipline above, that distinction matters
and isn't being glossed over.** What follows is the exact procedure that produced a genuine result:
data destroyed, then recovered, verified by a specific value rather than "a file exists" (the
`§23.10.21` lesson `docs/core/recovery-model.md` already encodes as a requirement).

1. Label the application's PVC (directly, or via `components/backup/`):
   `backup.scrap.io/enabled: "true"`.
2. Trigger a backup run out of band (normally this happens on `platform-backup`'s own schedule):
   `kubectl create job -n scrap-backup <name> --from=cronjob/scrap-backup`. Confirm success:
   `kubectl logs -n scrap-backup job/<name>` shows `snapshot <id> saved` for the labelled PVC.
3. Destroy the data for real — not a simulated failure. Exec into the application's pod and remove
   the file/directory that matters.
4. **Scale the application to zero replicas and confirm the old pod has actually terminated before
   restoring.** Found the hard way on a real stateful app (P5's Redis example, `apps/examples/`):
   restoring into a PVC while its owning pod is still running -- even mid-`kubectl rollout restart`,
   already receiving `SIGTERM` -- lets that pod's own shutdown behavior (many databases,
   Redis included, write a final on-disk snapshot when they exit) silently re-overwrite the just-
   restored file before the new pod ever reads it. Restore looked like it succeeded (correct byte
   count, correct timestamp, confirmed with `ls` immediately after) and the data was still gone one
   `rollout restart` later. Never restore into a PVC whose pod is still attached to it.
5. Restore: run a `restic restore latest --host <instance-name> --path <the exact PV hostPath>
   --target /` job, mounting the same `hostdata` and `repo` host paths `platform/backup/`'s own jobs
   use (see `platform/backup/backup-cronjob.yaml` for the volume definitions to copy). The PV's real
   path comes from `kubectl get pv <name> -o jsonpath='{.spec.local.path}'` (see
   `platform/backup/README.md`'s discovery-mechanism section for why `local.path`, not
   `hostPath.path`).
6. Scale back to one replica, and verify **through the original application pod**, not a separate
   one, that the specific value destroyed in step 3 is back — not merely that a file of the same
   name exists.

**For a multi-tier application (a database plus one or more app-server processes connected to
it), step 4's "scale to zero" means the *entire* tier that talks to the database, not just the
database engine itself.** Found the hard way restoring `capabilities/identity/`'s Postgres: with
authentik's server and worker left running while Postgres was wiped and reloaded from a logical
dump, the still-live worker's own startup/migration logic raced the manual reload and left Django's
migration bookkeeping inconsistent with the actual schema (`relation "..." already exists`,
worker `CrashLoopBackOff` afterward) -- not data loss, but a broken app that then needed the whole
sequence redone with server *and* worker also scaled to zero throughout. The corrected order for
any database-backed application: scale every component that connects to the database to zero
first, restore/reload the database alone, confirm it's healthy on its own (a direct client query,
not through the app), *then* scale the application tier back up.

Executed exactly this way three times, against three different applications on the `detest`
scratch cluster:

- **2026-08-16, a bare canary file on a throwaway PVC:** a value written as
  `canary-value-<timestamp>-<random>`, backed up, deleted, confirmed gone via `kubectl exec ...
  cat` (file-not-found), restored, and re-read via the same running pod -- the exact same value
  came back. Full transcript in the commit history for the `platform/backup/` milestone.
- **2026-08-17, `apps/examples/p5-stateful-backup/`'s Redis:** a value written as
  `canary-p5-<timestamp>-<random>` via `redis-cli SET`, backed up (with the consistency command
  `redis-cli SAVE` running first, per that PVC's annotations), the on-disk RDB file deleted and the
  pod cycled to confirm `GET` returned nothing -- genuinely gone, not cached. Step 4 above is what
  this run discovered: the first restore attempt, done without scaling to zero first, silently
  failed exactly as described. Redone with the pod scaled to zero first, the restore held, and
  `redis-cli GET` through the restarted pod returned the exact canary value.
- **2026-08-17, `capabilities/identity/`'s Postgres:** a group named `canary-identity-final-
  <timestamp>-<random>` created via authentik's own API, backed up (consistency command: `pg_dump`
  as the application's own database user, into a sibling directory on the same PVC -- see
  `capabilities/identity/README.md` for why not `pg_dumpall` as the `postgres` superuser), deleted
  via the API and confirmed gone (`count: 0`), the whole Postgres data directory wiped, restored via
  restic, then rebuilt by piping the dump back through `psql` -- with the paragraph above's lesson
  discovered and corrected mid-run. Verified the exact group, same primary key, back through
  authentik's own API after restarting server and worker.

**What would make this a real `tests/dr/` entry, not just a runbook:** a script that automates steps
1-5 against a throwaway PVC as part of CI, asserting the exact value round-trips, replacing the
manual verification above with an executed one. Not yet built — tracked as future work alongside the
T-A..T-F CI profile matrix.
