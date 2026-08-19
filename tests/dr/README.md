# tests/dr/

Disaster-recovery rehearsals — the executable counterpart to [`docs/runbooks/`](../../docs/runbooks/)
and [`docs/core/recovery-model.md`](../../docs/core/recovery-model.md). A recovery claim in this
project's documentation is not treated as a guarantee until a test here actually exercises it.

| Rehearsal | Proves | Status |
|---|---|---|
| [`authentik-postgres-restore.sh`](authentik-postgres-restore.sh) | R1 (application-data loss), using `capabilities/identity/`'s own multi-tier Authentik + PostgreSQL: a canary object created and its primary key retained through authentik's own API; the real platform backup, with the `pg_dump` consistency command's execution confirmed from its own log line; the application state deleted AND the underlying PostgreSQL storage genuinely destroyed (both proven absent mechanically, not inferred); the complete DB-connected tier (Postgres itself and every Deployment in the `authentik` namespace) quiesced and confirmed stopped *before* any restore is attempted; restoration through SCRAP's real `restic restore` mechanism; reconstruction via the documented, supported `psql -v ON_ERROR_STOP=1` reload, hard-checked for errors, plus a direct client query (not through the app); the application tier restarted; and functional recovery proven through authentik's own API with **the exact same primary key**, not merely an object sharing the old name | **Implemented** — [`authentik-postgres-restore.sh`](authentik-postgres-restore.sh), run nightly by [`.github/workflows/dr-authentik-postgres-restore.yml`](../../.github/workflows/dr-authentik-postgres-restore.yml) (also available via `workflow_dispatch`) |
| Host-loss rehearsal (R3) — **T-E** in [`tests/profiles/`](../profiles/) | A blank machine, rebuilt using only the artifacts the recovery model says survive, on generic virtualization | Not yet implemented — deliberately deferred; also the natural home for proving escrow-key-alone decryption (`bootstrap/install.sh`'s dual age recipients), which this R1 rehearsal does not attempt |

**Why Authentik/PostgreSQL over `apps/examples/p5-stateful-backup/`'s Redis** (already covered by
`tests/profiles/t-a-minimal.sh`): identity is the only shipped workload with more than one tier
talking to its own database. P5 is single-tier and structurally cannot exercise quiescence
ordering, a real logical-dump consistency method, or a stable-identifier claim beyond a raw key
name — see `docs/core/recovery-model.md` and the DR-acceptance audit that selected this target.

`tests/assertions/check_dr_quiesce_ordering.py` is a permanent, cheap structural guard against the
ordering bug this rehearsal's quiesce step exists to prevent: it fails CI if the script is ever
restructured so the tier is scaled to zero *after* the restore runs -- without needing to re-run a
live corruption cycle on every commit to prove it.

**The ordering lesson was verified as a live negative control, not just asserted.** A temporary,
clearly-labelled commit skipped the application-tier scale-to-zero, leaving `authentik-server` and
`authentik-worker` running while Postgres was wiped and reloaded -- reproducing the exact historical
bug live. The DR acceptance oracle turned red: the worker's own log showed it had already
reconnected to the freshly-reinitialized database and was processing tasks against it *before* the
dump reload ran, and the reload itself failed with `ERROR: schema "template" already exists` (`psql
-v ON_ERROR_STOP=1`, exit 3) -- a genuine, named diagnosis of corrupt recovery. Critically, the
direct client query the reload step also runs (`SELECT 1`) still succeeded even in this broken run,
demonstrating concretely why "the database answers a query" alone would not have been sufficient
proof -- only the hard-checked reload caught it. The commit was reverted immediately afterward; see
git history around this file's own introduction for the exact run.
