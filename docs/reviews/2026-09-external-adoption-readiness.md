# External-adoption readiness review — SCRAP `v0.1.0-rc.1` (2026-09)

**Question this review answers:** can a technically competent person who is not the owner —
no chat history, no undocumented conventions — discover, understand, install, operate, recover,
and report problems with SCRAP from the published repository and release artifacts alone?

**Baseline reviewed:** the `v0.1.0-rc.1` tag (`b5eeb2987b9139b5272da37c4c38b045aad6350b`,
published 2026-08-28 as a GitHub pre-release) treated as the product baseline, with docs and
scripts read at `develop` commit `6deeb01` (which contains everything the tag does plus
post-RC doc/test work). This is a review artifact, not a fix pass: findings are recorded here
and routed as bounded follow-ups (§7); no product docs were changed by this review beyond the
index entry that makes this artifact discoverable.

**Method:** a front-to-back external-user walk of the README → getting-started → install →
verify → add-an-app → enable-capabilities → recover → report-a-problem journey; two independent
full-tree documentation audits (architecture/evidence docs; capability/config docs); a
mechanical check of every relative link and anchor in every Markdown file; and live checks of
the actual GitHub repository/release state (default branch, tag, Release page, Issues settings,
CI history). Every finding below was verified against the file and, where applicable, the live
GitHub state — line references are to `develop` `6deeb01`.

**Severity scale:** **BLOCKER** = a competent outsider following the documented path gets hard-stuck
or materially misled; **HIGH** = likely to cause a failed or abandoned attempt; **MEDIUM** = real
friction or trust damage, recoverable; **LOW** = polish.

---

## 1. Executive summary

The foundation is unusually good. The core docs (README, getting-started,
choosing-capabilities, adding-an-application, understanding-scrap, recovery-model) are honest,
newcomer-first, and mechanically accurate; every relative link in the repository resolves
(zero dead links, verified mechanically); the example configuration is fully commented with
safe placeholder values and no owner-environment leakage; preflight genuinely fail-louds with
actionable messages; the release machinery works (tag → CHANGELOG-sourced GitHub pre-release);
and CI is fully green on both branches (10/10 workflows on `develop` at `6deeb01`).

Three problem clusters currently stand between this and a real external adopter:

1. **The release-consumption chain is broken at the last step** (§3). The docs that tell a user
   *which version to install and how to get it* still carry pre-tag wording — the release notes
   literally say "Before the tag exists, there is nothing to install under this name yet" about
   a tag that has existed since 2026-08-28 — and the install path never mentions the tag at all:
   a fresh `git clone` lands on `main`, which has moved past the candidate. **BLOCKER**, and
   docs-only to fix.
2. **The secrets/SOPS path breaks for anyone not running the happy path** (§2, E4–E7). The
   documented *manual* re-keying procedure re-keys one of eight secret files and then deletes
   the reference key; the Topology B generator ships the same defect and doesn't produce the
   per-capability secret directories its own generated README says exist; the identity
   capability never tells the user to replace seven publicly-decryptable credentials, including
   the SSO superuser bootstrap password/token. **BLOCKER** cluster — the automated
   `install.sh` path already handles all of this correctly; the docs and generator were never
   synced to it.
3. **There is no feedback loop** (§5). Issues are enabled but no doc anywhere points at them;
   there are no issue templates, no CONTRIBUTING.md (so an outsider cannot know PRs go to
   `develop`), no SECURITY.md, and getting-started says "that's a real bug worth reporting"
   without saying where. **HIGH**, and cheap to fix.

Nothing found requires re-cutting `rc.1`, new core architecture, or reopening any accepted
decision. Every blocker above is a documentation, template-comment, or small-script defect in
the *adoption surface*, not in the platform. The recommended path: land follow-ups F1–F4 (§7),
then run the first external-user trial per the plan in §6.

---

## 2. External-user journey findings

Walked as: land on the GitHub repo → decide what SCRAP is → choose a version → install →
verify → add an app → enable capabilities → think about recovery → hit a problem → report it.

### What works well (worth preserving, and worth saying plainly)

- **Identity and audience** are immediately clear from the README; "probably not for you if"
  is honest and accurate.
- **Prerequisites** (hardware floor, OS expectations, no hidden cloud/domain requirements) are
  stated up front and then genuinely enforced by `bootstrap/preflight/` with loud,
  self-explanatory failures — including the non-obvious ones (sshd for the local-git path,
  resolver sanity, cgroup v2). The preflight scripts' own docstrings record real bugs found
  testing them; this is credible engineering, visible to a stranger.
- **The minimum install path asks for exactly two decisions** (`INSTANCE_NAME`,
  `BASE_DOMAIN`), and `clusters/example/instance-config.yaml` is a model template: every field
  commented, every placeholder from documentation ranges, "harmless to leave as placeholder"
  stated per field.
- **Verification is concrete**: postflight prints an explicit report, and the doc tells the
  user to prove the platform with a real HTTPS request to a real pod, not object statuses.
- **Failure triage exists** (getting-started §6 distinguishes preflight failure / partial
  install / ready-but-unreachable) and honestly names re-runnability expectations.
- **The recovery entry point is honest**: `docs/runbooks/README.md` refuses to call anything
  tested that CI doesn't execute, and the destructive-restore runbook records three real
  executions with the failure modes found on the way. `docs/core/recovery-model.md`'s
  ingredient-vs-recipe framing for R3 is exactly what an early adopter needs to calibrate risk.
- **No owner-environment leakage in the config/manifest surface**: all example addresses are
  RFC 5737, all domains RFC 8375 `.internal`, all providers generic. Verified by sweep.

### E1 — Version selection and the clone step (HIGH)

`docs/getting-started.md:32` tells the user to
`git clone https://github.com/<your-fork-or-upstream>/scrap.git`. Two problems:

- The canonical upstream URL (`https://github.com/platta/scrap`) is never stated anywhere in
  the install path — the placeholder asks a first-time user to supply a fork they don't have.
- Nothing instructs checking out `v0.1.0-rc.1`. A fresh clone lands on the default branch
  `main`, which has advanced past the tag (RC-remediation merges), and `develop` — visible in
  the branch list — is ordinary integration work an adopter should never consume. No user-path
  document says any of this; the branch policy exists only in
  `docs/decisions/0016-post-rc-branching-policy.md`, which a new user has no reason to read.

An adopter today installs an unlabeled superset of the candidate without knowing it. See §3
for the contract this review recommends publishing.

### E2 — The release documents deny the release exists (BLOCKER)

The chain a first-time reader is explicitly routed down —
`docs/releases/README.md` → `docs/releases/v0.1.0-rc.1.md` — still reads pre-tag:

- `docs/releases/README.md:14`: the Status column contains a policy sentence ("tag created
  only after independent exact-candidate adjudication"), no date, no SHA, no link to the
  published GitHub pre-release. The releases index cannot tell the reader anything has been
  released.
- `docs/releases/v0.1.0-rc.1.md:117-122` ("Getting this release"): "Once `v0.1.0-rc.1` is
  tagged, install it … **Before the tag exists, there is nothing to install under this name
  yet**." False since 2026-08-28. The same file's "Exact candidate SHA" section (`:24-32`)
  still speculates about which commit will be blessed; the answer (`b5eeb298…`) is known and
  recorded elsewhere (`docs/decisions/0016:7`).
- `docs/decisions/0015-versioning-and-release-process.md:67-69` still says creating
  `v0.1.0-rc.1` "remains a separate, independently-adjudicated step" — present tense, now
  false, and (unlike ADRs 0013/0014) the record carries no date stamp that would let a reader
  interpret it as historical. It sits one file away from ADR-0016's "now that `v0.1.0-rc.1`
  exists."

The GitHub Release body (sourced from `CHANGELOG.md`'s section, by design) opens with the same
adjudication meta-prose and contains no "how to install this" line. None of this is dishonest —
it is unpropagated state from before the tag — but to an outsider it reads as either a stale
project or a self-contradictory one, on exactly the page meant to establish trust.

### E3 — Day-2 Git workflow on the default install path is undocumented (HIGH)

On the default (no `REPO_URL`) path, `bootstrap/install.sh` seeds a **snapshot** of the
checkout into a local bare repository (`/var/lib/scrap/repo.git`, served over SSH-to-localhost)
and bootstraps Flux against *that*. From that moment, the clone the user installed from is no
longer the source of truth — but no document says so:

- `docs/adding-an-application.md:99-105` says "Commit both additions … then `flux reconcile`"
  without saying **where** to commit. A user following it in their original clone commits to a
  repository Flux never reads, then watches a reconcile change nothing.
- `docs/choosing-capabilities.md:5-6` promises "every capability here stays addable later" —
  true, but the *mechanics* of "later" on the default path (clone
  `ssh://<user>@<host>/var/lib/scrap/repo.git`, edit, push) appear nowhere in `docs/`.

The only place this workflow can be reconstructed from is `install.sh`'s own source. One short
"making changes after install" section (getting-started or a small dedicated page), covering
both the local-bare-repo default and the `REPO_URL` case, closes this.

### E4 — The documented manual re-keying procedure strands seven secret files (BLOCKER)

`clusters/example/secrets/README.md:79-83` — the procedure explicitly addressed to "Topology B,
or any manual path" — runs `sops updatekeys` against **only** `restic-credentials.sops.yaml`,
then deletes the published reference key. `clusters/example/secrets/` contains **eight**
`*.sops.yaml` files (identity, grafana, public-tls, alert-delivery, heartbeat, dyndns, ups,
restic). A user who follows the procedure and later enables any credential-bearing capability
finds its secret file encrypted to a key they were told to delete, failing at Flux decrypt time
with `age: no identity matched` — an error nothing connects back to this step. (Recoverable
only by realizing the reference key is still published upstream — knowledge the procedure
gives no hint of.)

This is precisely the bug `bootstrap/install.sh:280-298` documents having found and fixed in
the automated path (it uses `find . -name '*.sops.yaml'` for this exact reason); the human
procedure was never updated to match. `bootstrap/generate-topology-b.sh:287-290` re-keys
single-file the same way and (`:324`) refers users to this same incomplete README procedure.

### E5 — Topology B generator omits the secret directories its own README references (BLOCKER)

`bootstrap/generate-topology-b.sh:274-276` copies only `secrets/kustomization.yaml`,
`restic-credentials.sops.yaml`, and the reference key into the generated operator repository.
The README the same script generates (`:267-269`) tells the operator that a capability's
credentials Kustomization "targets `clusters/<name>/secrets/`, part of this repository" — but
the per-capability secret subdirectories (`secrets/identity/`, `secrets/public-tls/`, …) are
never created. A Topology B operator enabling any credential-bearing capability gets a Flux
path-not-found with no documented way to create the missing directory from scratch (the
templates live in the upstream repo their topology exists to avoid checking out).

### E6 — "Rename to match your own instance" hides a required `spec.path` edit (HIGH)

All seven credential-bearing capabilities ship a `cluster-secrets-kustomization.yaml`
hardcoding `path: ./clusters/example/secrets/<cap>` (e.g.
`capabilities/grafana/cluster-secrets-kustomization.yaml:20`). Every enablement instruction
says to copy the file and *rename the file*; the in-file comment ("Path says clusters/example/
because … rename to match your own instance") is the only hint that `spec.path` itself must be
edited, and it reads at least as naturally as being about the filename. No document in `docs/`
instructs editing `spec.path`. A standard adopter (who copied `clusters/example` to
`clusters/<name>`) gets a Kustomization pointed at the *reference* instance's secrets — a
decryption failure (or path-not-found, if they deleted `clusters/example/`) pointing at a
directory they never touched.

### E7 — Identity ships seven publicly-decryptable credentials and never says to replace them (BLOCKER)

`capabilities/identity/README.md`'s "Enabling this capability" section (`:63-90`) is the only
credential-bearing capability enablement section with **no** "replace the placeholder values
with `sops`" step — every sibling (public-tls `:80-82`, alert-delivery `:77-79`, heartbeat
`:57-59`, dyndns `:79-81`, ups `:118-122`) has one.
`clusters/example/secrets/identity/identity-credentials.sops.yaml` carries seven secret keys —
including `AUTHENTIK_BOOTSTRAP_PASSWORD` and `AUTHENTIK_BOOTSTRAP_TOKEN`, the SSO superuser's
credentials — all encrypted to the published reference key. A user following the README
verbatim stands up an SSO provider whose superuser credentials anyone can decrypt from the
public repository. Also undocumented: that `password` must equal `AUTHENTIK_POSTGRESQL__PASSWORD`
(the Bitnami subchart's app-user password) and that `postgres-password` is a third, distinct
value — none of which can be inferred from ciphertext.

*(On the happy path — `install.sh`, Topology A — these files are automatically re-keyed to the
instance's own keys, so the exposure is "well-known default credentials," not "publicly
decryptable"; still a real problem for an SSO superuser, and the README never says to change
them on any path.)*

### E8 — No "how do I get in / did it work" for identity, Grafana, off-site backup (MEDIUM)

- `capabilities/grafana/README.md` never states the URL (`grafana.${BASE_DOMAIN}`, only in
  `httproute.yaml`) or how to obtain the chart-generated admin password (one `kubectl get
  secret` line). A newcomer has a running Grafana and no documented way in.
- `capabilities/identity/README.md` similarly never states `auth.${BASE_DOMAIN}` or frames the
  `akadmin` bootstrap credentials as *the operator's login* (the information exists but only as
  the author's validation evidence).
- `capabilities/offsite-backup/README.md` gives the operator no way to confirm *their* first
  off-site backup landed (e.g. `restic -r <BACKUP_DESTINATION> snapshots --host
  <INSTANCE_NAME>`), unlike every other capability's "fails visibly" section.

### E9 — Two prerequisite gaps in the public-DNS capabilities (MEDIUM)

- `capabilities/public-tls/README.md`'s enablement section (`:73-82`) omits `BASE_DOMAIN` from
  the instance-config values to change, even though leaving it `example.internal` guarantees an
  ACME failure the README only explains deep in an evidence section (`:127`).
- Neither public-tls nor dyndns explains how to *obtain* an RFC2136 TSIG key (`tsig-keygen`
  example, that the secret value is the base64 blob, zone-scoping) — for the self-hoster
  audience this is the least-approachable prerequisite in the envelope, and it gates two
  capabilities.

### E10 — Host-tool prerequisites surface only at preflight time (LOW)

`bootstrap/preflight/check-prerequisites.sh` requires `curl`, `git`, `age-keygen`, `sops`, and
(for the default path) a listening sshd — with excellent failure messages. But
getting-started §1's "check your host" list never mentions them, so the first attempt on a
bare Debian image is a guaranteed preflight bounce the doc's own "saves you a wasted attempt"
framing exists to avoid. One sentence fixes it.

### E11 — Stale content-existence claims that read as "is this finished?" (MEDIUM)

Each verified against the tree:

- `capabilities/README.md:10-11` says several capabilities are "on by default in the documented
  `standard` profile (`clusters/example/capabilities/`)" — that directory is empty and **is**
  the `minimal` profile (its own README says so). Also, `capabilities/README.md` never mentions
  off-site backup's no-file enablement (its "two recorded exceptions" list stops at ups/public-
  ingress; `docs/core/configuration-model.md` handles it correctly).
- `components/README.md:13` lists `components/metrics/` as a usable component with no caveat;
  the directory is "Not yet implemented" and contains no `kustomization.yaml` — referencing it
  fails a Kustomize build.
- `apps/README.md:29-33` describes `apps/catalog/` as containing "a small number of real,
  boring, well-behaved applications"; it is empty by design per its own README.
- `capabilities/identity/README.md:52-54` says P2 is "not yet wired into an `apps/examples/`
  demo; that's the next piece of work" — contradicted by `apps/examples/p2-native-oidc/` and by
  the same file's own live-validation section (`:162+`).
- `components/forward-auth/README.md:41-44` still says "a P3 example needs to add it" —
  `apps/examples/p3-forward-auth/` exists and is live-validated.
- `capabilities/logs/README.md:6` calls identity+Grafana+logs "the frozen T-B acceptance
  definition" while the documented `standard` *profile* is grafana+logs+alert-delivery — one
  disambiguating clause prevents the natural (wrong) T-B ↔ standard equation.

### E12 — Evidence-doc staleness now that the tag exists (MEDIUM)

- `docs/release-readiness.md` introduces itself as a pre-packaging document (`:3-5`), tells the
  reader existence-gap rows "are marked so" when no such markings exist in its own table
  (`:11-12` — the rc.1-blocking column lives in `docs/releases/v0.1.0-rc.1.md` instead),
  forwards to the pre-tag release notes for the candidate's "own current status" (`:79`), and
  reveals the tag exists only in passing (`:81`). One "PROVEN NOW" row (`:37`, bootstrap
  reliability fixes) cites "commit history, `bootstrap/install.sh`" — not the CI-gated profile
  the section header promises for every row.
- `docs/engineering-evidence.md` and `docs/release-readiness.md:53` still present T-F (upgrade
  testing) as blocked on "a first release existing" — that precondition is now satisfied; and
  T-E's "pre-release" trigger tier reads as if a pre-release couldn't ship without it, when one
  deliberately did (per ADR-0011 — the reconciliation is never stated on the evidence page
  itself).
- `docs/core/bootstrap-lifecycle.md:4`, `docs/engineering-evidence.md`, and
  `docs/release-readiness.md:23-25` say acceptance profiles run on "every push/PR" — push
  triggers are `branches: [main, develop]` only; a fork/feature-branch push runs nothing until
  a PR is opened. Minor, but it's a claim about the evidence machinery itself.
- `docs/core/bootstrap-lifecycle.md:16-18` says step 3 "demonstrate[s] the escrow copy is
  readable from somewhere that isn't this host" — `install.sh` actually asks the operator to
  retype the escrow key's fingerprint (an attestation, not a readability demonstration), and
  `SCRAP_ESCROW_CONFIRMED=1` bypasses it non-interactively. The same file honestly flags its
  step-7 deviation; step 3 deserves the same honesty.

### E13 — Owner-context references an outsider can't resolve (LOW, one MEDIUM)

Mostly presented as evidence/history (harmless, but worth a gloss):

- The `detest` scratch cluster is named three times (`capabilities/identity/README.md:26,132`,
  `docs/runbooks/README.md:72`) and defined nowhere — one parenthetical gloss at first use
  ("a disposable single-node scratch instance used for live validation") resolves it.
- PLAT-nnn ticket IDs are used as provenance citations in several docs and ADRs; fine as
  provenance tags, but `docs/decisions/0017:114` parks an *open architectural question* solely
  "as a `FOLLOW-UP` on PLAT-115" — state the question in-repo so its existence doesn't depend
  on a tracker outsiders can't read.
- **MEDIUM:** `docs/decisions/0015`'s release procedure depends on "the Adjudication Protocol
  this project's own workflow already follows for Jira issues" (`:41`) — defined nowhere in the
  repository — and points at "`docs/release-readiness.md`'s evidence boundary" as a named
  section that doesn't exist under that name. As written, no fork maintainer could legitimately
  cut a release by this procedure. (`docs/decisions/0016:71-76` similarly name-drops the
  owner's Omnigent dispatcher; harmless context, worth one qualifying clause.)
- `docs/understanding-scrap.md:137-138` defers the storage non-decision to
  [`decisions/`](../decisions/) "for the reasoning" — no ADR covers storage/local-path. Either
  write the short ADR or drop the pointer.

### E14 — P4 contract/example mismatch (known, tracked) (MEDIUM)

`docs/core/application-contract.md:19` states P4 ports are declared "in the app's own
`reserved-ports.yaml`" with no caveat, while the only shipped P4 example
(`apps/examples/p4-raw-tcp/`) still declares its port centrally in
`platform/ingress/reserved-ports.yaml` — a newcomer copies the example and gets the shape the
contract implies is wrong. ADR-0017 documents why the example is deliberately unmigrated, and
`0017:132-135` believes the caveat was added to `application-contract.md` — it wasn't. This is
adjacent to the already-tracked migration question; the doc caveat itself is a one-line fix.

---

## 3. Distribution and release-consumption contract

The ticket's five questions, answered against the actual repository/release state, with the
contract this review recommends making explicit (all of it docs-only):

1. **Which release should a new user consume?** Intended answer: `v0.1.0-rc.1` (the only
   published release; a pre-release, with its evidence boundary honestly documented). Actual
   repository behavior: a fresh clone silently delivers `main`'s tip. **Recommendation:**
   getting-started names the canonical clone URL and says: check out `v0.1.0-rc.1` to run the
   adjudicated candidate; `main` tip is also acceptable (it advances only through adjudicated
   RC-remediation, per ADR-0016) and is what you'll get by default; never install from
   `develop`.
2. **What artifact/branch/tag is authoritative?** The git tag (and the GitHub Release's
   auto-generated source archives of the same commit — no other artifacts exist, and none are
   needed for a `git`-based install; no packaging system is warranted). This is currently
   discoverable only by inference; the release notes and releases index should state the tag,
   SHA, date, and Release link outright (E2).
3. **What is supported versus development-only?** Nothing states it. **Recommendation:** tagged
   releases + `main` = supported for adopters; `develop` = development-only, no stability or
   evidence claims. One paragraph, in README and/or getting-started.
4. **What compatibility/support claims are warranted?** The existing evidence boundary
   (release-readiness/release-notes: x86-64 CI-proven, arm64 accepted-untested, R3/R4 unproven,
   upgrade path untested — T-F has never run, so no upgrade claim of any kind should be made to
   rc.1 adopters) is exactly right and already honest. No new claims should be added; the
   existing ones need only the staleness fixes in E12.
5. **How do users discover release notes / known issues / upgrade guidance?** GitHub Releases →
   CHANGELOG section → `docs/releases/<tag>.md` is the right, already-built chain; it currently
   undermines itself via E2's stale wording. Known issues: today the honest answer is the
   release notes' gap table plus (once created) the issue tracker; upgrade guidance: honestly
   "none yet, T-F pending" — say so where an adopter will look.

---

## 4. Onboarding/documentation assessment

Prior accepted documentation work holds up; nothing needs a rewrite. The newcomer-first flow
(README → getting-started → choosing-capabilities → adding-an-application, with
understanding-scrap and engineering-evidence as optional depth) is the right shape and mostly
excellent. The smallest set of changes that lets an external user proceed without asking the
owner for context, in order of value:

1. **Fix the consumption chain** (E1+E2): real clone URL, tag checkout guidance,
   supported-vs-development branch statement, release docs updated to post-tag reality.
2. **Fix the manual secrets path** (E4–E7): recursive re-key loop in the secrets README; the
   `spec.path` edit stated once in `docs/choosing-capabilities.md` (and/or per-capability);
   identity credential-replacement step; Topology B generator gap closed or honestly
   documented.
3. **Document day-2 changes** (E3): one short section covering "where do my commits go" for
   both the local-bare-repo default and `REPO_URL` installs.
4. **Add the missing verification one-liners** (E8) and the two prerequisite notes (E9, E10).
5. **Stale-claims sweep** (E11+E12): each is a one-line-to-one-paragraph edit; none blocks an
   install, all erode trust on inspection.

Not recommended: restructuring docs, new packaging, or any install-flow change — the current
flow is good, and every finding above is fixable inside it.

---

## 5. Early-adopter feedback loop (recommendation)

Nothing exists today: Issues are enabled but unreferenced by any doc; no templates, no
CONTRIBUTING.md, no SECURITY.md, no SUPPORT.md; GitHub Discussions is off. Smallest effective
mechanism, all repository-native:

1. **A "Reporting problems" section in README** (and a pointer from getting-started §6) naming
   the issue tracker as the channel for bugs *and* install/support questions — for a
   pre-release with a handful of adopters, one channel is correct; do not enable Discussions
   yet.
2. **Two issue templates** (`.github/ISSUE_TEMPLATE/`):
   - **Bug report**, asking for: SCRAP version (`git describe --tags` output / tag or SHA
     installed), topology (A/B), enabled capabilities, host OS/arch, what failed (preflight /
     install step / reconcile / capability / recovery), exact commands and full output,
     `flux get kustomizations` and relevant `kubectl` output, and what the reporter believes is
     installation vs. environment vs. SCRAP defect (mirroring getting-started §6's triage).
   - **Installation/support question**, a lighter form asking version, topology, what was
     attempted, and what the docs said at the point of confusion (each confusion doubles as a
     doc-defect report — say so in the template).
   - `config.yml` with `blank_issues_enabled: true` (don't force templates on experienced
     reporters).
3. **Feature requests vs. defects:** handle via a label + one line in the bug template ("if
   nothing is broken but something is missing, say 'enhancement'") — a third template is not
   yet warranted.
4. **`SECURITY.md`**: enable GitHub private vulnerability reporting on the repo and point at
   it; explicitly ask that credential-exposure and auth-bypass class issues (this platform
   terminates TLS and fronts an SSO provider) not be filed publicly. Two paragraphs.
5. **`CONTRIBUTING.md`** (one page): PRs target `develop` (ADR-0016 — today an outsider cannot
   learn this without reading the ADR index, and `main` has no branch protection to catch the
   mistake); CI expectations (`tests/assertions/run_all.sh` locally; acceptance profiles run on
   the PR); the T1/T2 invariants in one sentence each; DCO/licensing note (Apache-2.0).
   Recommend (separately, an owner action, not a repo change): a branch-protection rule on
   `main` requiring PRs, now that outside contributors are being invited — ADR-0016 already
   flags this as a reasonable follow-up.

---

## 6. First external-user validation plan

**Purpose:** validate the onboarding surface, not the platform (CI already validates the
platform). The unit under test is the documentation; the user is the instrument.

**Participant profile:** one technically competent early adopter — comfortable with Linux,
Git, and a terminal; Kubernetes familiarity helpful but explicitly not required (the docs
claim to carry a non-Kubernetes-expert; test that claim). Not a prior contributor; has never
discussed SCRAP internals with the owner.

**Environment assumptions (acceptable, per the documented floor):** one x86-64 Linux box or VM
(Debian/Ubuntu current), ≥2 cores / 4 GB RAM / 32 GB disk, LAN + internet access, and the
ability to install packages. arm64 explicitly out of scope for the first trial (untested claim,
per release-readiness — don't stack two experiments). A fresh VM is acceptable and preferred
over hardware for trial 1; a later trial on real scrap hardware can follow.

**Scope — what the user attempts independently, in order:**

1. **Discovery:** starting from only the repository URL, decide what SCRAP is, whether it fits,
   and *which version to install* (this specifically probes E1/E2 — record what they choose and
   why).
2. **Minimum install:** prerequisites → clone → configure (`INSTANCE_NAME`, `BASE_DOMAIN`) →
   `install.sh` → postflight → the documented `curl` verification.
3. **First application:** add one app per `docs/adding-an-application.md` (probes E3 directly).
4. **One capability with a credential:** enable Grafana or alert-delivery per its README
   (probes E6/E8; identity is a reasonable stretch goal and probes E7).
5. **Recovery comprehension (read-only):** without executing a restore, the user explains back
   what is and isn't protected in their install and where they'd start after data loss
   (probes recovery-model/runbook legibility).
6. **File one issue** through whatever reporting path they can discover (probes §5; run the
   trial after F4 lands so there is a path to find).

**Evidence to capture:**

- Full terminal transcript (`script`/`asciinema`) of every session, plus the postflight report.
- A running friction log: every point where the user paused >2 minutes, re-read, guessed, or
  wanted to ask a question — **including questions they suppressed**; each suppressed question
  is an onboarding defect by definition.
- Timestamps per stage (discovery / install / app / capability), for a time-to-first-success
  baseline.
- On any failure: the exact doc step being followed, the command, the full error, and the
  user's own classification attempt (installation / environment / SCRAP defect) before any
  assistance — their misclassifications measure the triage docs.
- The version/ref they actually installed, and how they decided.

**Owner assistance protocol:** the owner does not volunteer help. If the user is blocked
>30 minutes or would abandon, assistance is given — and **logged as a finding**: every
assist = one onboarding defect at that step, with the words that unblocked them captured as
the missing doc content. Environmental failures outside SCRAP's documented floor (broken VM
networking, corporate MITM proxy) may be assisted freely and are not findings.

**Success criteria (trial 1):** the user (a) installs the intended version knowingly, (b)
reaches the documented verified state (postflight clean + `curl` through TLS to the whoami
pod), (c) deploys one app reachable over HTTPS, (d) enables one capability successfully, and
(e) files one well-formed issue — with **zero owner assists** in (b) and at most brief,
logged assists elsewhere. Anything less is not a failed trial; it is a successful measurement
producing findings.

**Converting findings to tickets:** one bounded ticket per distinct defect (not per session),
each carrying: the trial evidence pointer, the doc/step it invalidates, severity by this
review's scale, and — where the fix is wording — the user's own unblocking words as draft
content. Repeat the trial with a second user only after the first trial's BLOCKER/HIGH
findings are fixed; two users hitting the same wall is confirmation, not new information.

**Boundary:** this plan prepares the trial; executing it is its own ticket (F6), per this
review ticket's own scope.

---

## 7. Recommended follow-ups, in dependency order

Bounded, docs-first, no core architecture. F1–F4 before the trial; F5 anytime; F6 last.
Branch routing per ADR-0016 is noted per item but is the adjudicator's call — F1 in
particular changes what `rc.1` consumers read and is RC-remediation-shaped (`main`, then
propagate); the rest is ordinary work (`develop`).

- **F1 — Release-consumption truth pass (docs-only; BLOCKER E2 + HIGH E1).**
  `docs/releases/README.md` status column (tag date, SHA, Release link);
  `docs/releases/v0.1.0-rc.1.md` "Exact candidate SHA" + "Getting this release" rewritten to
  post-tag fact with the checkout command; `docs/getting-started.md` §2 canonical URL + version
  guidance; one supported-vs-development paragraph (README or getting-started);
  `docs/decisions/0015` stale sentence fixed with a date-stamped amendment note;
  release-readiness framing header (the E12 items touching the same files can ride along).
  Small, self-contained, highest trust-per-line value in this review.
- **F2 — Manual secrets path fixes (docs-only; BLOCKERs E4, E7 + HIGH E6 + MEDIUMs E8, E9).**
  `clusters/example/secrets/README.md` re-key procedure → the `find`-based loop `install.sh`
  already uses; the `spec.path` edit documented in `docs/choosing-capabilities.md` and the
  seven template comments clarified; identity README credential-replacement step (all seven
  keys, the two coupled Postgres values, and an explicit "change these on every path" warning);
  Grafana/identity login one-liners; offsite-backup verification command; public-tls
  `BASE_DOMAIN`; a TSIG-key-origin note shared by public-tls/dyndns.
- **F3 — Topology B generator secrets gap (small script change + generated-README wording;
  BLOCKER E5, plus E4's twin in the generator).** Copy the per-capability secret directories
  (re-keying every `*.sops.yaml` via the same `find` loop), or make the generated README
  honestly document hand-creation; regenerate/extend `t-a-topology-b.sh` coverage for a
  credential-bearing capability if practical within scope.
- **F4 — Feedback mechanism (new repo files; §5).** README "Reporting problems" section, two
  issue templates + config.yml, SECURITY.md (with private vulnerability reporting enabled —
  owner console action), CONTRIBUTING.md with the ADR-0016 branch contract. Separate owner
  decision, recommended alongside: branch protection on `main`.
- **F5 — Stale-claims and owner-context sweep (docs-only; E11, E12, E13, E14).** The
  enumerated one-liners: capabilities/components/apps existence claims, identity/forward-auth
  stale "next piece of work" text, logs T-B clause, "every push/PR" wording, bootstrap-
  lifecycle step-3 escrow wording, storage-decision pointer (write the short ADR or drop it),
  `detest` gloss, ADR-0015's Jira-protocol dependency qualified, application-contract P4
  caveat.
- **F6 — Execute the first external-user trial (§6).** After F1–F4; produces its own bounded
  findings tickets per the conversion rule above.

---

## Appendix — what was checked and found clean

- **Link integrity:** every relative link and in-page/cross-file anchor in every tracked
  `*.md` resolves (mechanical sweep + manual anchor verification). Zero dead links.
- **CI:** 10/10 workflows green on `develop` at `6deeb01` (2026-09-01 push) and on `main`'s
  post-tag remediation merges; the rc.1 baseline's own CI history is honestly recorded in the
  release notes, including the one transient MinIO rerun.
- **Release machinery:** tag → `release.yml` → CHANGELOG-sourced GitHub pre-release verified
  against the live Release page (published 2026-08-28, `github-actions`, prerelease flag
  correct, body matches the CHANGELOG section).
- **Owner-environment leakage in config/manifests:** none — all example values are
  documentation-range/reserved-namespace; third-party services named only as generic examples.
- **Example-value safety:** `clusters/example/instance-config.yaml` placeholders are safe to
  install verbatim (and CI installs them); per-field "harmless if unused" annotations are
  accurate except as noted in E9.
- **Honesty architecture:** the PROVEN NOW / NOT YET PROVEN / DEFERRED discipline, negative
  controls, and "fails visibly" sections are real and verified in spot checks — this review
  found staleness and gaps *around* the evidence, not overclaimed evidence itself, with the
  two narrow exceptions noted (E12: the bootstrap-fixes row's evidence citation, and the
  bootstrap-lifecycle escrow wording).
