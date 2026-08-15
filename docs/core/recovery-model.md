# Recovery model

**CORE.** "We have backups" is not a recovery guarantee. SCRAP states, per configuration, exactly
which failure class is actually tested — not one all-or-nothing claim.

## The three-way split

**Configuration is recreated** — everything under `platform/`, `capabilities/`, `apps/`, and
Authentik Blueprints (when identity is enabled): Git plus a bootstrap run reproduces it exactly.

**State is restored** — PVC contents, database dumps, identity enrollment data: restic, backed by
a tested restore procedure.

**Secrets are retrieved** — SOPS + age; decryptable without a running cluster, from an escrowed
key.

## Failure classes and what actually buys you out of each

| Class | Lost | What must survive | Unlocked by |
|---|---|---|---|
| **R0** — workload failure | a running process | nothing extra | CORE, always |
| **R1** — application-data failure | one app's data/correctness | the backup repository + its password | CORE, always |
| **R2** — disk/storage loss | the disk backups live on too | a *second* disk or media | CORE minimum, if backup destination ≠ same disk |
| **R3** — host loss | the whole machine | Git *and* backups, both off-host | `capabilities/offsite-backup/` + external Git hosting |
| **R4** — site loss | the whole physical location | all of R3's artifacts, off-site | R3's capabilities, verified off-site |
| **R5** — external account/credential loss | a provider, an account | escrowed keys; a second destination or a documented migration | depends on which credential |

**The honest limit of the minimum profile:** it provides R0–R2. It cannot claim R3 or R4, because
nothing survives off the single machine — and it says so, rather than implying a stronger guarantee
than it's tested.

## Fatal-if-lost, and only these three

- The **age key** — mitigated: two recipients from the first commit, so losing one is recoverable.
- The **restic repository password** — restic encrypts client-side; lose this and backup data is
  unrecoverable even with valid storage access. Escrowed **separately** from the age key.
- Authentik's **encryption/secret key**, when identity is enabled — verified during design work to
  fail loudly (refuses to start) rather than silently corrupt, which is the right failure mode, but
  it's still fatal-if-lost.

**The private CA root key is explicitly not on this list.** Losing it costs a reissue and
re-distributing trust to client devices — no data loss, no application changes.

## What SCRAP tests versus what it merely documents

Every claim above with a listed unlocking capability is asserted by a CI profile
(`tests/profiles/`, `tests/dr/`) once implemented — including a destructive restore verified by
*specific, recently-changed values*, never row counts alone, which is the exact distinction that
mattered in a real incident during this platform's own design work. A claim without a corresponding
test is not yet a guarantee, and this document will say so rather than implying otherwise.
