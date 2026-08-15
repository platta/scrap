# tests/dr/

Not yet implemented. Disaster-recovery rehearsals — the executable counterpart to
[`docs/runbooks/`](../../docs/runbooks/) and [`docs/core/recovery-model.md`](../../docs/core/recovery-model.md).
A recovery claim in this project's documentation is not treated as a guarantee until a test here
actually exercises it.

Planned first entries: a single-application destructive restore (proving R1), and the host-loss
rehearsal described as **T-E** in [`tests/profiles/`](../profiles/) (proving R3) — a blank machine,
rebuilt using only the artifacts the recovery model says survive, on generic virtualization.
