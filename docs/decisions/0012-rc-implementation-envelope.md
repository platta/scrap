# 0012 — RC implementation envelope: existence before candidacy, proof during it

**Decision:** a release candidate must **contain an implementation of every behavior that is
mandatory before final v1**. What `0011-release-candidate-policy.md` permits a candidate to defer
is **proof**, never **existence**. Concretely, for the six surfaces this decision was written to
resolve — heartbeat, dyndns, UPS, public ingress, alert delivery, and the Topology B onboarding
generator required by `0009-repository-topology.md` — all six must be implemented before
`v0.1.0-rc.1` is cut, and all six remain mandatory before final v1. None of them is removed from
the v1 envelope, and none of them receives an RC exemption.

**Recorded 2026-08-22, operator-adjudicated release-policy decision.** This is the explicit
envelope decision the project's two independent RC-readiness reviews both anticipated: each found
these surfaces unimplemented and ruled candidacy blocked *unless an explicit
architecture/release-policy decision* said otherwise. This record makes that decision — in the
strict direction. It extends ADR-0011; it does not change anything ADR-0011 settled.

## The question this resolves

ADR-0011 defines a release candidate as containing "the intended v1 product behavior" and allows
a v1 requirement to remain **unproven** in a candidate under three explicit conditions. It never
says whether "unproven" stretches to cover **unimplemented**. The repository's own texts pulled in
both directions:

- `docs/release-readiness.md` groups unimplemented capabilities and unproven behaviors under one
  "INTENDED FOR v1 BUT NOT YET PROVEN" table, and its preamble frames that whole table as "what a
  release candidate may still leave open" — the loose reading.
- The accepted adjudication of the first RC-readiness review settled the strict reading:
  implemented-but-awaiting-qualification may defer under ADR-0011; still-unimplemented surfaces
  are pre-RC work unless the envelope itself is explicitly re-decided. The second review reached
  the same verdict against the reconciled tree.
- For Topology B specifically, `docs/release-readiness.md` flagged the RC-vs-final boundary as
  deliberately unresolved, because ADR-0009's "Required for v1" wording contains no RC/final
  split.

Rather than letting that ambiguity be re-litigated at every review, this record decides it.

## The rule, and why it is the only reading that keeps "candidate" meaningful

A release candidate is, by definition, an artifact that **could become the final release
unchanged** if the remaining qualification passes against it. That is the entire content of the
word "candidate," and it is what ADR-0011's own qualification loop assumes: `rc.N` either survives
qualification and becomes v1, or a failure is fixed and produces `rc.N+1`.

The three implementation/evidence states, made explicit:

1. **Implemented and proven** — the behavior exists in its intended form and current, sound
   evidence (live acceptance, structural CI, or the documented operator-run boundary) backs it.
2. **Implemented but not yet fully qualified** — the behavior exists in its intended form; some
   designated proof (T-E/R3, T-D, T-F, whole-system integration) has not yet run. If that proof
   passes against the candidate, the candidate needed no change: it genuinely was a possible v1.
   This is exactly the state ADR-0011's three-condition allowance was written for.
3. **Specified/designed but not implemented** — a README, an ADR, a roadmap entry; no manifests,
   no code, nothing to enable. An artifact in this state for a mandatory-v1 behavior **cannot**
   become v1 unchanged — further implementation is already known to be required — so it is not a
   candidate for v1 no matter what its tag claims. Calling it `rc.1` would misstate the artifact's
   maturity to every consumer, including a Topology B operator pinning to the tag per ADR-0009.

A candidate may ship states 1 and 2. State 3 is permitted in a candidate **only** for behavior
that is explicitly classified DEFERRED / OPTIONAL / POST-v1 — outside the final-v1 envelope — in
`docs/release-readiness.md`. "Optional to enable" is not "optional to exist": the five pending
capabilities are optional for an operator to turn on, but their existence as implemented,
supported capabilities is part of the v1 envelope (`capabilities/README.md`, "FULLY SUPPORTED"),
so state 3 is not available to them.

This also keeps ADR-0011's loop honest in the other direction: implementing whole new
capabilities between candidates is new product development, not the "failure → fix → `rc.N+1`"
remediation the loop describes, and whole-system evidence gathered against an earlier candidate
(a host-loss rehearsal, for instance) would be evidence about a materially different artifact than
the one finally tagged.

## What "contains the intended v1 product behavior" concretely means for `rc.1`

The **product surface** is what the candidate must be complete over: `bootstrap/`, `platform/`,
`capabilities/`, `components/`, `clusters/example/`, and the normative documentation's claims
about them. For a capability, "implemented" means what it has meant for every capability accepted
so far: real manifests exist and the documented enabling mechanism (`capabilities/README.md` —
copying the capability's `Kustomization` file(s)) actually enables it — never a README alone. For
Topology B, "implemented" means the generator ADR-0009 requires, together with the automated
bootstrap/reconcile test that ADR-0009's own operator decision makes part of the requirement
(unlike T-E/T-F, nothing about it structurally requires a release to exist first — ADR-0009
states commit-SHA pinning "works identically").

The evidence bar at implementation time is the discipline already established by the accepted
capabilities, not something new: the CI-provable envelope proven with sound oracles and negative
controls where practical, and inherently-external interactions bounded the way
`capabilities/public-tls/` bounds real-domain issuance (operator-run verification with the
CI-provable part proven). The specifics belong to each surface's own implementation work item —
this record deliberately does not design the capabilities.

**Qualification infrastructure is not product surface.** T-C/T-D/T-E/T-F harnesses may be built
during the RC cycle — running remaining qualification is what the RC window is *for*, and ADR-0011
already accepts that T-F cannot even exist before a first candidate does. Test additions that
leave the product surface unchanged do not invalidate a standing candidate. The dependency runs
one way only: T-C's *heartbeat component* is product and must exist before `rc.1`; the T-C nightly
profile that exercises it is qualification and may follow.

## What may change after `rc.1`

- **Remediation of a demonstrated qualification failure or defect** in the product surface:
  permitted — this is ADR-0011's loop, and any such product change produces a new candidate
  (`rc.2`, `rc.3`, ...). Evidence already gathered is re-evaluated against the new candidate per
  ADR-0011.
- **Qualification infrastructure, release notes, and evidence-boundary documentation**: may accrue
  during the RC cycle without forcing a new candidate, provided the product surface is unchanged.
- **New intended-v1 behavior first landing after `rc.1`**: prohibited. If the envelope itself is
  ever re-scoped mid-cycle, that is a recorded decision under `docs/decisions/` amending this one
  — never an RC convenience — and the resulting artifact starts a new candidate, since the
  previous candidates' claims no longer describe it.

## No silent downgrade

This decision removes nothing from the v1 envelope and weakens no final-v1 requirement — it makes
the requirements *earlier*, not weaker. Every one of the six surfaces remains "blocks final v1" in
`docs/release-readiness.md` exactly as before, now with the RC boundary stated explicitly instead
of inferred. Moving any behavior out of the v1 envelope requires its own recorded decision here,
with this rule applied to whatever envelope results.

## Rejected alternatives

- **The milestone-RC reading** (cut `rc.1` now; let the six land during the RC cycle, honestly
  labeled): rejected. Its only benefit is an earlier tag date. Its costs: the tag would name a
  "candidate" that is knowably incapable of becoming v1 (a public overclaim to anyone pinning it,
  however honest the internal labels); whole-system qualification run against early candidates
  would be spent on artifacts guaranteed to be superseded by new implementation, not by fixes; and
  the distinction between the implementation phase and the qualification phase — the distinction
  ADR-0011 exists to draw — would collapse. This is also precisely the "redefine the boundary
  merely to cut a candidate sooner" move the first review's accepted adjudication already
  declined.
- **A per-capability split** (require before `rc.1` only the surfaces woven into frozen
  qualification — heartbeat for T-C, the ADR-0009 generator — and let dyndns/UPS/public-ingress
  land during the cycle): rejected. It has a statable principle ("does a frozen profile need it?")
  but fails the candidate-identity test all the same — an artifact awaiting *any*
  mandatory-for-v1 implementation still cannot become v1 unchanged — and it would make
  "candidate" mean different things per capability while every later addition invalidated the
  candidates before it. One uniform rule resolves all six; six-way case law would be convenience,
  not principle.

## Consistent with

`0011-release-candidate-policy.md` (extended, not changed: its three-condition deferral allowance
is confirmed as a *proof* allowance, which is what its own text says — "remain unproven";
its T-E/R3 and T-F conclusions are untouched); `0009-repository-topology.md` (its "Required for
v1" now has the explicit RC/final answer its wording left open: required before `rc.1`, no RC
exemption); `docs/release-readiness.md` (updated alongside this record to state the `rc.1`
boundary on the affected rows and to resolve its deliberately-flagged Topology B ambiguity);
`0008-abstract-decisions-not-technologies.md` (a release-process rule; no new mechanism).
