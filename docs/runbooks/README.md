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
4. Restore: run a `restic restore latest --host <instance-name> --path <the exact PV hostPath>
   --target /` job, mounting the same `hostdata` and `repo` host paths `platform/backup/`'s own jobs
   use (see `platform/backup/backup-cronjob.yaml` for the volume definitions to copy). The PV's real
   path comes from `kubectl get pv <name> -o jsonpath='{.spec.local.path}'` (see
   `platform/backup/README.md`'s discovery-mechanism section for why `local.path`, not
   `hostPath.path`).
5. Verify **through the original application pod**, not a separate one, that the specific value
   destroyed in step 3 is back — not merely that a file of the same name exists.

Executed exactly this way against a temporary canary PVC on the `detest` scratch cluster
(2026-08-16): a value written as `canary-value-<timestamp>-<random>`, backed up, deleted, confirmed
gone via `kubectl exec ... cat` (file-not-found), restored, and re-read via the same running pod --
the exact same value came back. Full transcript in the commit history for the `platform/backup/`
milestone.

**What would make this a real `tests/dr/` entry, not just a runbook:** a script that automates steps
1-5 against a throwaway PVC as part of CI, asserting the exact value round-trips, replacing the
manual verification above with an executed one. Not yet built — tracked as future work alongside the
T-A..T-F CI profile matrix.
