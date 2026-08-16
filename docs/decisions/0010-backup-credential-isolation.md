# 0010 — Backup credential isolation is an authorization boundary, not a naming convention

**Decision:** a backup credential must be scoped so it **cannot** modify another SCRAP instance's
backups, even if someone accidentally points the wrong instance at the wrong repository. Enforced
two ways: `--host <instance identity>` on every restic invocation (not an application name), and
documentation that a test/scratch instance gets its **own** credential scoped to its **own**
repository — never a production credential differing only by prefix or tag.

## The incident this fixes

A disposable scratch VM, booted months after it was created, still held a **production** restic
repository credential. It replayed CronJobs that had been queued while it was powered off, ran
`restic forget --prune` against the production repository, and because retention was grouped only
by `paths` with no host isolation, treated scratch and production activity as **one timeline**.
Production snapshots were evicted by a scratch instance's retention policy. Full account in
`~/scrap/restic-remediation.md` (private — production incident notes, not part of this repository);
the remediation (new prefix, new password, new credential, old repository kept read-only as an
archive) is the pattern this decision generalizes.

## Why a naming convention isn't enough

The production setup *did* use a naming convention — a `--tag` distinguishing scratch snapshots from
production ones. Tags are metadata on a snapshot that already exists; they don't restrict what a
`--prune` invocation is *authorized to delete*. A shared credential with a shared repository can
always evict anything in that repository, tag or no tag, the moment someone runs `forget` without
also filtering by that tag. The tag was documentation of intent. It was never enforcement.

## The fix, applied structurally

1. **`--host` on every backup and every `forget`**, sourced from `${INSTANCE_NAME}` in
   `clusters/<name>/instance-config.yaml` — an instance identity, deliberately never an application
   name (an application name says *what*, not *whose*). restic's `forget` groups by `host,paths` by
   default, so a `forget` invocation scoped to one host cannot select, and therefore cannot evict, a
   different host's snapshots even in a repository that ends up shared by accident.
2. **Credential scope, documented as a requirement for anyone standing up a second instance**: a
   test or scratch SCRAP instance gets its own `RESTIC_PASSWORD` protecting its own repository path
   — never the production credential with a different `--tag`. Where the destination provider
   supports per-prefix or per-bucket policies, use them; where it doesn't, use a separate bucket.
   `platform/backup/README.md` states this plainly, and `clusters/<name>/secrets/` is structurally
   per-instance already (§ `docs/decisions/0009-repository-topology.md` — secrets are
   instance-specific regardless of topology).

Point 1 is enforced by every manifest in `platform/backup/`. Point 2 is a documentation and
operator-discipline requirement — there is no technical mechanism that can force two independently
created restic repositories to never share a credential, and this decision does not pretend
otherwise.

## Why this doesn't become a new abstraction

`--host` is restic's own native flag; grouping by `host,paths` is restic's own default. Nothing here
is a SCRAP invention — it's a naming and configuration discipline layered on a mechanism that already
exists, consistent with `0008-abstract-decisions-not-technologies.md`.
