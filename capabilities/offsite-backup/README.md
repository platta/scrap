# capabilities/offsite-backup/

**FULLY SUPPORTED.** Depends on `platform/backup/` only — this directory configures a
*destination*, it does not implement a second backup mechanism.

Points the platform-owned restic engine at an off-site, S3-compatible endpoint. **Any**
S3-compatible provider — this is a generic contract, not an AWS-specific one. Object-lock/versioning
is recommended where the provider offers it, as protection against ransomware and against a buggy
prune run.

## Credential isolation

Read `platform/backup/README.md`'s credential-isolation section before standing up a second
(test/scratch) SCRAP instance against the same provider. A backup credential must be scoped so it
cannot modify another installation's backups even by accidental misconfiguration — this was a real
incident during SCRAP's own design work, not a hypothetical.

## What enabling this actually buys

This is the capability that turns disk-loss recovery into **host-loss recovery** — see
`docs/core/recovery-model.md` for the exact, tested claim per configuration.

## New assumptions this introduces

An S3-compatible endpoint, a scoped credential, and internet access at backup time.
