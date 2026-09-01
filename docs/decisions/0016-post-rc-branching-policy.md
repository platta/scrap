# 0016 — Post-RC branching policy: `develop` for ordinary work, `main` for RC remediation

**Decision:** now that `v0.1.0-rc.1` exists (`docs/decisions/0015-versioning-and-release-process.md`),
SCRAP adopts a two-branch model for the RC-stabilization period:

- **`develop`** is the persistent integration branch for ordinary post-RC development. It was
  created from the exact commit `v0.1.0-rc.1` tags (`b5eeb2987b9139b5272da37c4c38b045aad6350b`,
  which was `origin/main`'s tip at cut time) — the approved RC baseline, not an arbitrary point.
  Normal ticket/feature work targets `develop`.
- **`main`** remains the release-quality line for the duration of RC validation and stabilization.
  It advances only through independently-adjudicated RC-remediation fixes and eventual release
  tags (`docs/decisions/0015`) — never through ordinary feature work landing directly.
- **RC remediation flow:** a fix branches from `main`, PRs into `main`, and — once accepted — the
  same accepted fix is also propagated into `develop` (merge or cherry-pick; see "The procedure")
  so the two branches never silently diverge.
- **Normal development flow:** a ticket/feature branch (as `docs/decisions/`-adjacent process
  already assumes) branches from `develop`, PRs into `develop`.
- This introduces exactly one new persistent branch. It does **not** introduce a full GitFlow
  hierarchy (`release/*`, `hotfix/*`, tracking branches per release, etc.) — nothing observed
  during implementation demonstrated a need for that additional ceremony.

## Why now, and why this shape

`v0.1.0-rc.1` is tagged (`docs/releases/v0.1.0-rc.1.md`), which means `main` has entered the
qualification window `0011-release-candidate-policy.md` describes: the remaining work before
final v1 is dominated by RC-remediation-shaped fixes (T-E, T-D, T-C, T-F — see
`docs/release-readiness.md`'s "INTENDED FOR v1 BUT NOT YET PROVEN" table) and adjudicated
gate reviews, not ordinary feature churn. Before this record, every PR — RC-blocking fix or
routine improvement alike — targeted `main` directly, and nothing distinguished the two. That
was fine pre-RC, when there was no release line to protect; once a release candidate exists,
letting exploratory or unrelated work land on the same branch a fix-verification/tagging cycle
depends on risks destabilizing the very thing the RC period exists to protect.

The two-branch split is deliberately the smallest structure that separates those concerns: one
branch stays release-quality and only receives adjudicated fixes; the other absorbs everything
else and doesn't block on RC-cycle ceremony. A three-or-more-branch GitFlow model (separate
`release/*` branches per candidate, `hotfix/*` naming, etc.) would add ceremony this project has
no evidence it needs — SCRAP cuts one candidate at a time from `main` directly, per `0015`.

## The procedure

1. **Ordinary work:** branch from `develop`, open a PR against `develop`. This is the default for
   any ticket that is not itself adjudicated as RC remediation.
2. **RC-remediation work:** branch from `main`, open a PR against `main`. This is for fixes to
   RC-blocking gaps (the "INTENDED FOR v1 BUT NOT YET PROVEN" rows in `docs/release-readiness.md`)
   or defects found against an already-tagged candidate.
3. **After an RC-remediation PR merges to `main`,** propagate the same accepted change to
   `develop` before the two branches drift further: merge `main` into `develop` (preferred — a
   single, ordinary merge commit keeps full history and needs no re-adjudication of the fix
   itself) or, where a clean merge isn't possible, cherry-pick the specific commit(s). Do this
   promptly rather than batching many RC fixes before syncing; the longer the branches diverge,
   the more likely a `develop`-side change collides with the same files.
4. **Which branch a given ticket targets is a normal part of that ticket's scope**, not a separate
   decision — an issue whose objective is RC remediation says so in its own description; ordinary
   tickets default to `develop` per this record without needing to restate it.

## What this does not decide

- **What happens after final v1 ships.** Whether `develop` continues indefinitely as the ongoing
  integration branch for the next release cycle, is retired, or is redefined is a future decision
  for whoever adjudicates the final-v1 gate — this record only covers the RC-stabilization window
  between `rc.1` and final v1. Deciding that now would be inventing a requirement this ticket
  (PLAT-114) was not asked to settle.
- **Branch protection rules** (requiring PRs, disallowing force-push, requiring status checks)
  are not configured by this record. Today, `main` has no GitHub branch-protection rule at all —
  this policy is a documented convention, enforced by contributor/agent discipline and CI status
  visibility, not by a server-side gate. Adding branch protection would be a reasonable follow-up
  but is a separate, more consequential change (it affects every future contributor's push
  permissions) that this record deliberately leaves to its own decision rather than bundling in
  silently.
- **Dispatcher/agent default-base-branch configuration** that lives outside this repository (for
  example, an Omnigent Project's own "base ref" setting for worktree creation) is not something
  this repository's docs can change. This record establishes the contract those external systems
  should be configured to honor — ordinary work to `develop`, RC remediation to `main` — but
  updating any such external configuration is outside this repository's scope and is called out
  separately, not silently assumed to already be correct.

## What changed to support this

- `develop` created from `main`'s tip at `v0.1.0-rc.1` (same commit the tag points to) and pushed
  to `origin`.
- `.github/workflows/ci.yml` and the `t-a-*`/`t-b-standard` acceptance-profile workflows: their
  `pull_request` triggers already have no branch filter (they run against a PR's target branch
  regardless of which branch that is), so PRs into `develop` were already covered without change.
  Their `push` triggers were restricted to `branches: [main]`; `develop` was added alongside `main`
  so a post-merge push to `develop` re-runs the same acceptance suite a pre-merge PR check already
  ran, instead of relying solely on the PR-time result. `release.yml` (tag-triggered) and the
  nightly DR workflow are unaffected — neither was branch-scoped to begin with.
- `docs/decisions/README.md` gained this record's index entry.

## Consistent with

`0011-release-candidate-policy.md` and `0012-rc-implementation-envelope.md` (the RC/final-v1
qualification window this policy exists to protect, unchanged by this decision);
`0015-versioning-and-release-process.md` (tags are still cut from `main` by independent
adjudication — this record does not change where or how a tag is created, only what else is
allowed to land on the branch it's cut from); `0008-abstract-decisions-not-technologies.md` (two
ordinary Git branches and a couple of workflow trigger lines — no new tooling, no SCRAP-specific
release machinery).
