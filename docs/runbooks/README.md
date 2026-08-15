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
- Single-application destructive restore
- Host-loss rehearsal (R3) — blank machine, only the artifacts the recovery model says survive
