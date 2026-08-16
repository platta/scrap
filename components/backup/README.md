# components/backup/

A Kustomize component that labels an application's `PersistentVolumeClaim`(s)
`backup.scrap.io/enabled: "true"` -- the discovery label `platform/backup/`'s backup job looks for
on every scheduled run. See `platform/backup/README.md` for the full mechanism (a single
platform-owned CronJob, no controller, no per-app job).

## Using it

```yaml
# apps/myapp/kustomization.yaml
resources:
  - pvc.yaml
  - deployment.yaml
components:
  - ../../components/backup
```

That's it for the plain file-copy case (P5's "nothing" consistency method) -- the app declares
storage the normal way, includes this component, and the platform's backup job finds and backs up
the PVC on its own schedule. No CronJob, no restic invocation, and no credential ever appear in the
application's own manifests.

If an app has more than one PVC and only some should be backed up, don't use this component --
label the specific PVCs directly instead (`backup.scrap.io/enabled: "true"` under
`metadata.labels`). The component is a convenience for the common case, not the only path.

## Declaring a consistency method

For anything beyond plain file copy -- a database that needs a logical dump, or a quiesce step
before the data is safe to read -- add two annotations to the PVC (by hand; this component only
adds the label):

```yaml
metadata:
  annotations:
    backup.scrap.io/consistency-command: "pg_dump -U app appdb > /data/.backup/dump.sql"
    backup.scrap.io/consistency-pod-selector: "app=myapp"
```

Before backing up that PVC, the backup job runs the command inside a pod matching the selector (via
`kubectl exec`) -- write the dump into the PVC itself, since that's what gets backed up next. If the
selector matches no running pod, the job logs a warning and backs up the PVC as-is rather than
failing the whole run. Both annotations are read fresh on every run; there's nothing to reconcile
and nothing to keep in sync.

## What this component does NOT do

- It does not create a CronJob, a ServiceAccount, or anything that runs on its own. All of that is
  `platform/backup/`, shared across every application.
- It does not configure the backup *destination*, credentials, schedule, or retention -- those are
  instance-wide (`clusters/<name>/instance-config.yaml`, `clusters/<name>/secrets/`), never
  per-application.
- It does not restore anything. Restore is a platform-provided procedure (`docs/runbooks/`).
