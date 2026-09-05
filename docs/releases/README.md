# docs/releases/

The release-notes artifact for each SCRAP tag — what a first-time reader or operator should read
before relying on that specific version. See
[`docs/decisions/0015-versioning-and-release-process.md`](../decisions/0015-versioning-and-release-process.md)
for the versioning scheme and exactly how a tag gets here, and
[`docs/release-readiness.md`](../release-readiness.md) for the **live, authoritative** evidence
snapshot every entry below summarizes at its own point in time. If the two ever disagree,
`docs/release-readiness.md` is correct and the affected entry below is stale — it describes what
was true at the time that candidate/release was assembled, not a moving target.

| Release | Status | Exact commit | Notes |
|---|---|---|---|
| [v0.1.0-rc.1](v0.1.0-rc.1.md) | **Pre-release**, tagged 2026-08-28 — [GitHub Release](https://github.com/platta/scrap/releases/tag/v0.1.0-rc.1) | [`b5eeb298`](https://github.com/platta/scrap/commit/b5eeb2987b9139b5272da37c4c38b045aad6350b) | First public release candidate. Get it with `git checkout v0.1.0-rc.1`; read that document's evidence boundary before relying on it. |

**Which of these should you install?** The newest tagged release above — currently
`v0.1.0-rc.1`. Tagged releases are the supported consumption point for adopters; see
[Getting started](../getting-started.md#2-clone-the-repository) for the clone-and-checkout
commands and for which branches are, and are not, meant to be installed.

`CHANGELOG.md` (repository root) is the terse, chronological counterpart to this directory — one
entry per tag, linking here for the full picture.
