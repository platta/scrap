# capabilities/offsite-backup/

**FULLY SUPPORTED. Current implementation status: IMPLEMENTED, LIVE-TESTED** (proves artifact
placement, not host-loss recovery itself — see `docs/release-readiness.md`). Depends on
`platform/backup/` only — this directory configures a *destination*, it does not implement a
second backup mechanism, and it applies **no new Kubernetes resource of its own** — see "Enabling
this capability" below. (This directory genuinely contains no manifest of its own, by design — see
that section — which is exactly why its status is stated explicitly here rather than inferred from
what files exist.)

Points the platform-owned restic engine at an off-site, S3-compatible endpoint. **Any**
S3-compatible provider — this is a generic contract, not an AWS-specific one; the two credential
env vars restic's S3 backend reads (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`) are the AWS SDK's
standard names, reused by every S3-compatible provider's own client libraries, not a SCRAP or
AWS-specific mechanism. Object-lock/versioning is recommended where the provider offers it, as
protection against ransomware and against a buggy prune run.

## What this claim is, precisely — and what it is not

**This capability's claim: SCRAP can place the recovery artifacts the frozen contract requires
(the restic repository — application data, database dumps, identity enrollment data) into storage
whose failure domain is independent of the SCRAP host, through restic's own supported remote-backend
mechanism.** Proven live: backup data is genuinely written through the S3 protocol (not merely a
configured URL), the resulting repository is independently enumerable and readable using the
intended recovery credentials, and losing access to the remote destination fails the backup job
visibly rather than silently falling back to local storage — see `tests/profiles/t-a-offsite-backup.sh`.

**This capability's claim is NOT "SCRAP has proven host-loss recovery."** Placing artifacts
off-host is necessary for R3 (host loss) but is not itself the proof — that requires a blank
machine, only the artifacts the recovery model says survive, and a full recovery, which is
`tests/profiles/README.md`'s T-E (host-loss rehearsal), **not yet implemented**. Until T-E runs,
treat this capability as "the artifacts are demonstrably off-host," not "R3 is proven."
`docs/core/recovery-model.md`'s own table reflects this distinction.

## Enabling this capability — no Kustomization file needed

Every other optional capability is enabled by copying a Flux `Kustomization` file into
`clusters/<name>/capabilities/` (`capabilities/README.md`). This one is different: `platform/backup/`'s
three CronJobs (backup, prune, check) already read `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
unconditionally (`optional: true` — inert when the keys are absent, which is the local/minimum
destination's default state). Enabling off-site backup is exactly two edits, both already covered
by the existing `platform/backup/` and `clusters/<name>/secrets/` mechanism:

1. **`clusters/<name>/instance-config.yaml`**: set `BACKUP_DESTINATION` to your provider's restic
   S3 URL — `s3:https://<endpoint>/<bucket>[/<path>]` (or `s3:http://...` for a non-TLS endpoint,
   e.g. a self-hosted MinIO on your own LAN). The bucket must already exist; restic's S3 backend
   does not create one for you.
2. **`clusters/<name>/secrets/restic-credentials.sops.yaml`**: add `AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY` alongside the existing `RESTIC_PASSWORD` — see that directory's own
   README for the exact `sops` invocation.

No capability-owned Secret, no capability-owned Kustomization: the credential lives in the same
core-owned secret `RESTIC_PASSWORD` already does, because the resource that needs it
(`platform/backup/`'s CronJobs) is core-owned too — there is no `capabilities/`-owned resource here
for a capability-owned secret to attach to. This keeps `platform/` depending on nothing new
(`capabilities/README.md`'s one rule: core may never depend on an optional capability) while still
making the destination and credential genuinely optional and instance-scoped.

## Confirming your first off-site backup landed

Unlike every other credential-bearing capability, there is no `kubectl get jobs`/`Ready` condition
to check here — `platform/backup/`'s CronJobs run on their own schedule and this capability only
changes where they write. To confirm a snapshot has actually reached your destination, query the
repository directly with the same credentials `restic-credentials.sops.yaml` holds:

```sh
RESTIC_PASSWORD=<value> AWS_ACCESS_KEY_ID=<value> AWS_SECRET_ACCESS_KEY=<value> \
    restic -r <BACKUP_DESTINATION> snapshots --host <INSTANCE_NAME>
```

Run from any host with the `restic` binary and network access to the destination (values from
`clusters/<name>/secrets/restic-credentials.sops.yaml` and `instance-config.yaml`). An empty list
before the first scheduled `backup-cronjob.yaml` run is expected, not a failure — re-check after one
has run, or trigger one manually
(`kubectl create job -n scrap-backup --from=cronjob/scrap-backup manual-check`).

## Credential isolation

Read `platform/backup/README.md`'s credential-isolation section before standing up a second
(test/scratch) SCRAP instance against the same provider. A backup credential must be scoped so it
cannot modify another installation's backups even by accidental misconfiguration — this was a real
incident during SCRAP's own design work, not a hypothetical (`docs/decisions/0010-backup-credential-isolation.md`).
The `--host ${INSTANCE_NAME}` mechanism ADR-0010 relies on is unconditional in every `platform/backup/`
manifest and is completely unaffected by which destination `BACKUP_DESTINATION` names — proven live,
not merely asserted, by `tests/profiles/t-a-offsite-backup.sh`.

## New assumptions this introduces

An S3-compatible endpoint, a scoped credential, an already-existing bucket, and internet access at
backup time (or LAN-only reachability, for a self-hosted S3-compatible target — nothing here
requires internet specifically, only network reachability to wherever `BACKUP_DESTINATION` points).
