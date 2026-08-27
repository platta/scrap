# 0015 — Versioning and release process

**Decision:** SCRAP releases are ordinary [SemVer 2.0.0](https://semver.org/) Git tags, `v`-prefixed
(`v0.1.0`, `v0.1.0-rc.1`, `v0.3.0`, ...), created manually after independent exact-candidate
adjudication of a specific `main` commit SHA — never automatically from a merge to `main`, and
never by any automation this repository runs on its own. This formalizes what
[`0011-release-candidate-policy.md`](0011-release-candidate-policy.md) and
[`0012-rc-implementation-envelope.md`](0012-rc-implementation-envelope.md) already used throughout
their own text (`v0.1.0-rc.1`, `rc.2`, `rc.3`, "final v1") and what
[`0009-repository-topology.md`](0009-repository-topology.md)'s Topology B example already assumed
(`ref: { tag: v0.3.0 }` — a later release, used purely as an illustrative pin target). It does not
introduce a new scheme; it writes down the one already in use.

## What was actually undecided

`0011` scopes itself to the RC/final-v1 semantic boundary only, and explicitly defers "the
mechanics of cutting a tag, a CHANGELOG, or a release workflow" — tracked, until now, as deferred
work in `docs/release-readiness.md`. This record supplies that missing mechanics. It does not
reopen, relax, or reinterpret anything `0011`/`0012` already settled about what a candidate must
contain or when a requirement may remain unproven.

## The scheme

- **Git tags, not a repository `VERSION` file, are the single source of truth for a release's
  identity.** SCRAP is a GitOps manifest repository, not a compiled or packaged artifact with its
  own build-time version stamp — a `VERSION` file would be a second, driftable copy of information
  Git tags already carry authoritatively. The Topology B generator and `components/` remote-base
  pinning already consume tags directly (`ref: { tag: ... }`, `?ref=v0.3.0` in a Kustomize remote
  base), so this is also the mechanism operators already depend on.
- **Tag format:** `v<MAJOR>.<MINOR>.<PATCH>`, optionally followed by a SemVer pre-release
  identifier. Release candidates use `-rc.<N>` (`v0.1.0-rc.1`, `v0.1.0-rc.2`, ...), matching
  `0011`'s qualification loop (`rc.N` → fix → `rc.N+1` → final v1).
- **SCRAP is in SemVer's initial-development phase (`0.y.z`).** Every place "final v1" appears in
  `0011`/`0012`/`docs/release-readiness.md`, it names the first stable release — tagged `v0.1.0`,
  not `v1.0.0`. This isn't a new call: it's the only reading consistent with the release candidate
  this project is actually cutting (`v0.1.0-rc.1`, this ticket's own subject) and with `0009`'s own
  later-release example (`v0.3.0`, not `v1.3.0`). A future decision to leave the `0.y.z` line and
  adopt SemVer's `1.0.0` stability guarantee is out of scope here and would need its own record if
  ever proposed.
- **A tag is created only after independent exact-candidate approval of a specific commit SHA on
  `main`** — the Adjudication Protocol this project's own workflow already follows for Jira issues.
  No workflow, script, or bot in this repository creates or pushes a tag; every tag is a deliberate,
  human-authorized act against an already-approved commit.

## The procedure

1. An adjudicator approves an exact candidate SHA on `main` (a separate step from — and later than
   — any single issue's own PR merge; see `docs/release-readiness.md`'s evidence boundary for what
   "approved" requires).
2. Whoever the adjudicator authorizes tags and pushes it:
   `git tag -a v0.1.0-rc.1 <approved-sha> -m "v0.1.0-rc.1"` then `git push origin v0.1.0-rc.1`
   (equivalently, through GitHub's own "create tag" UI against that SHA).
3. [`.github/workflows/release.yml`](../../.github/workflows/release.yml) runs on that tag push. It
   extracts the tag's own section from [`CHANGELOG.md`](../../CHANGELOG.md) and publishes a GitHub
   Release from it, marked **prerelease** automatically whenever the tag contains `-rc.`, and
   **latest** otherwise. It creates no tag itself — pushing the tag in step 2 is the adjudicated
   act; this workflow only turns an already-pushed tag into a Release, reproducibly, from
   `CHANGELOG.md`'s own content.
4. [`docs/releases/<tag>.md`](../releases/) carries the full release-notes artifact — capability
   list, the PROVEN NOW / INTENDED FOR v1 BUT NOT YET PROVEN / DEFERRED evidence boundary, and any
   CI-evidence history worth preserving honestly — the document a first-time reader or operator
   should read before relying on that tag. `CHANGELOG.md` stays terse and links to it; the two are
   not duplicates of each other.

## What this does not do

- It does not create, or authorize creating, `v0.1.0-rc.1` itself. That remains a separate,
  independently-adjudicated step outside this ticket's (PLAT-87's) scope — see
  `docs/release-readiness.md` and this record's own "Consistent with" section.
- It does not change what "unproven" or "unimplemented" means for a candidate, or which six
  surfaces `0012` requires before `rc.1` — this record is purely about tag/changelog/workflow
  mechanics.
- It does not add Renovate-style automated version-bump PRs — already tracked separately, and
  deliberately left open, in `docs/release-readiness.md`'s DEFERRED table.

## Consistent with

`0011-release-candidate-policy.md` and `0012-rc-implementation-envelope.md` (both extended, not
changed — see "What this does not do" above); `0009-repository-topology.md` (its tag-pinning
example now rests on an explicit, written convention instead of an assumed one);
`0008-abstract-decisions-not-technologies.md` (Git tags and a GitHub Actions workflow triggered by
a tag push are native, ordinary mechanisms — no SCRAP-specific release tooling is introduced).
