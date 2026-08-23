# 0011 — Release-candidate policy: the boundary between `rc.N` and final v1

**Decision:** a SCRAP release candidate contains the intended v1 product behavior and is the
artifact against which final whole-system release qualification is performed. A requirement
designated for v1 may remain unproven in a release candidate only when all three of the following
hold:

1. it is explicitly identified as unproven, in this repository, at the time the candidate is cut;
2. the candidate's own documentation/release notes make no claim that it is satisfied;
3. it remains mandatory before final v1 — nothing is quietly downgraded to optional by virtue of
   missing a candidate.

Failed qualification produces another candidate (`rc.2`, `rc.3`, ...), not a redefinition of what
qualification requires. All final-v1 requirements must be satisfied before the final v1 tag.

```
intended v1 implementation
    ↓
v0.1.0-rc.1
    ↓
remaining release qualification, including T-E/R3
    ↓
failure → fix → rc.2
    ↓
all final-v1 gates satisfied
    ↓
final v1
```

**Concretely, for the items this decision was written to resolve:** T-E (the host-loss rehearsal)
does not need to pass before `rc.1` is created, but it does need to pass before final v1. R3 (host
loss) remains explicitly **UNPROVEN** in every release candidate's own claims until T-E actually
establishes blank-host recovery from the artifacts the recovery model says survive. The same
reasoning applies to R4, which depends on R3.

## Why this is a gap-filling decision, not a reopening of anything frozen

Nothing in this repository's decision records, `docs/core/`, or `tests/profiles/README.md`
previously defined what a "release candidate" *is*, or where the boundary between it and "final
v1" falls. `tests/profiles/README.md`'s own acceptance matrix marks T-E and T-F as triggered
**"pre-release"** — a trigger tier, not a semantic definition of which release (candidate or
final) that precedes. This decision supplies the missing definition; it does not weaken, relax, or
reinterpret any requirement that was already settled. In particular:

- It does **not** downgrade T-E/R3 from "required" to "optional." T-E remains mandatory before
  final v1, exactly as `docs/core/recovery-model.md` and the frozen recovery model already state.
- It does **not** relax T1/T2, the one-directional dependency rule, or any structural CI
  assertion — those are proven today and remain proven regardless of this policy.
- It does **not** retroactively excuse a claim of *already-satisfied* behavior that current
  evidence doesn't support. A capability that is unimplemented, or a recovery class that is
  unproven, must say so in a release candidate's own documentation — this decision does not
  create a "candidate" exception that lets an unproven claim through unmarked. Point 2 above is
  the safeguard: the RC period exists for what's honestly labeled unproven, not for what's
  silently misrepresented as proven.
- It does not change `tests/profiles/README.md`'s own T-E/T-F trigger tier ("pre-release") — it
  interprets that tier as running during the candidate-qualification window (between `rc.1` and
  final v1), which is the only reading consistent with T-F's own definition ("previous release →
  current"): T-F cannot execute at all until a first release — a release candidate — exists to
  upgrade *from*. `rc.1` is the precondition for T-F, not something T-F blocks.

## What this decision does not cover

This ADR is scoped to the RC/final-v1 semantic boundary only. It does not specify:

- the mechanics of cutting a tag, a CHANGELOG, or a release workflow (tracked as separate,
  explicitly deferred work — see `docs/release-readiness.md`);
- which specific items are unproven *today* (that is a snapshot, tracked in
  `docs/release-readiness.md` and `docs/core/recovery-model.md`, not repeated here so this
  document doesn't need to be edited every time a milestone closes a gap);
- how many candidates a given release cycle will need, or what "qualification" consists of beyond
  the frozen acceptance profiles (`tests/profiles/`, `tests/dr/`) already defined.

**Addendum (2026-08-22):** this ADR's deferral allowance is written for requirements that remain
*unproven*; it was later asked whether that stretches to behavior that is still *unimplemented*.
It does not — that boundary is decided explicitly by
[`0012-rc-implementation-envelope.md`](0012-rc-implementation-envelope.md): a candidate may defer
proof, never existence.

## Consistent with

`docs/decisions/0008-abstract-decisions-not-technologies.md` (this is a release-process
convention, not a new technology or abstraction); `docs/core/recovery-model.md` (the R0–R5
classification and its "what SCRAP tests versus what it merely documents" section, unchanged by
this decision).
