# P5 -- stateful application with a declared consistency method

`docs/patterns/README.md#p5`. A `PersistentVolumeClaim` opted into `platform/backup/` via
`components/backup/` (discovery), plus two annotations naming a consistency command and the pod to
run it in (correctness). The application never declares a destination, a credential, or a schedule
-- see `platform/backup/README.md`.

## What it proves

That an application becomes backed-up, integrity-checked, and restorable by declaring a label and
an annotation -- no CronJob of its own, no restic credential in its namespace, ever. And that
`components/backup/`'s Kustomize component genuinely patches a PVC it did not write, rather than
that being an unverified claim.

## Verify (the only kind of restore verification this project trusts -- a specific value, not a
row count or "a file exists")

```
kubectl exec -n scrap-examples deploy/p5-redis -- redis-cli SET canary <a value you just chose>
kubectl create job -n scrap-backup manual-p5-test --from=cronjob/scrap-backup
# ... after it completes, destroy the key, then restore via the procedure in
# docs/runbooks/README.md's "Single-application destructive restore" section ...
kubectl exec -n scrap-examples deploy/p5-redis -- redis-cli GET canary
```

Expect the exact value back through the original running pod.
