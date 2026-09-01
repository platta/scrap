# 0017 — P4 port reservation ownership: per-app declaration, not a central platform file

**Decision:** an application's own P4 (raw TCP/UDP, `docs/patterns/README.md#p4`) port is declared
reserved in a `reserved-ports.yaml` file colocated with the application, under `apps/<name>/` --
not in `platform/ingress/reserved-ports.yaml`. `tests/assertions/check_reserved_ports.py` merges
every such file with the platform-owned allowlist into one namespace and fails if two sources ever
claim the same port. `platform/ingress/reserved-ports.yaml` continues to exist, scoped to
platform-owned ports (today: 80/443, the ingress Gateway's own fixed ports) plus one deliberately
unmigrated legacy entry -- see "What this record leaves undone" below.

## The contradiction this resolves

Two CI-enforced rules, both individually correct, were jointly impossible to satisfy for a new P4
application:

- `check_reserved_ports.py` required a new P4 app's port to already exist in
  `platform/ingress/reserved-ports.yaml`, and that file's own header comment said the allowlist
  edit belonged in the *same pull request* as the application.
- `check_app_addition_boundary.py` enforces T2 by rejecting any pull request that touches both
  `apps/` and `platform/` (or `capabilities/`).

A P4 app's PR was required to touch both `apps/` (the application) and `platform/` (its port
declaration), and forbidden from touching both, at the same time. There was no pull request that
could satisfy both checks. This was found live during PLAT-112 (an assessment of migrating an
existing homelab to a tagged `v0.1.0-rc.1` install), against the tagged candidate itself, tracked
as PLAT-115.

**For Topology B (`docs/decisions/0009-repository-topology.md`) this wasn't just inconvenient, it
was unfixable by the operator at all:** an operator's own repository never contains `platform/` --
it's the pinned upstream Flux source, referenced by a separate `GitRepository`, never checked out
alongside the operator's own `apps/`. There was no file the operator could edit to reserve a port,
short of forking the pinned upstream release, which is exactly what Topology B (`0009`) exists to
make unnecessary.

## Why per-app ownership, not (for example) relaxing T2

The safety property `check_reserved_ports.py` exists for is real and unchanged: an incident where
an ingress controller's default `LoadBalancer` Service silently claimed a host's real production
ports, undetected for roughly 49 minutes. The fix that mattered was making a new port claim
*explicit, diffable, and reviewed* -- never that the explicit declaration must specifically live
under `platform/`. T2 (`0009`, `docs/core/application-contract.md`) is a frozen invariant for a
good, independent reason (adding a normal application must never require a platform change,
proven by a diff rule, not merely documented) -- weakening it for P4 specifically would mean P4 is
no longer really "just an application pattern," undermining the same contract every other pattern
relies on. Moving the *declaration*, not the *requirement*, is the smaller, more targeted fix:

- A **new** application's own pull request touches only `apps/<name>/` -- the application's
  manifests and its own `reserved-ports.yaml` -- so it satisfies T2 exactly like every other
  pattern.
- The declaration is exactly as diffable and reviewable as before -- more so, arguably: a reviewer
  looking at the app's own PR sees the port claim right there, instead of having to also notice an
  edit to a shared file elsewhere in the diff.
- `platform/ingress/reserved-ports.yaml` keeps doing its original job for platform-tier ports,
  which are rare and genuinely platform-owned (the ingress Gateway's own 80/443) -- a platform-only
  change to that file never touches `apps/`, so T2 has nothing to say about it either.

### The collision check is new, and load-bearing

A single central file made duplicate port claims visually obvious to any editor by construction --
one file, one diff. Splitting the declaration across every app's own directory loses that for
free, so `check_reserved_ports.py` now explicitly merges every declared `(port, protocol)` across
all sources (the platform file, or its fixed-port fallback -- see below -- plus every
`apps/**/reserved-ports.yaml`) and fails if the same key is declared more than once, naming every
conflicting source. Without this, two applications could silently claim the same port and nothing
would notice until they actually collided at runtime -- reintroducing exactly the kind of silent
claim this mechanism exists to prevent, just moved from "platform vs. app" to "app vs. app."
`tests/fixtures/violations/reserved-port-collision/` and
`tests/fixtures/violations/reserved-port-topology-b-fixed-collision/` prove this check actually
fires; `tests/fixtures/valid/p4-app-owned-port/` proves the supported path stays clean.

## Topology A and Topology B, explicitly

- **Topology A (monorepo):** `platform/ingress/reserved-ports.yaml` and every app's own
  `reserved-ports.yaml` are all checked out in the same tree. `check_reserved_ports.py` sees all of
  them and can catch every collision -- platform vs. app, and app vs. app -- directly.
- **Topology B (separate operator repository + pinned upstream):** the operator's own repository
  contains `clusters/<name>/`, their own `apps/`, and `secrets/` -- never `platform/`. Their own
  CI therefore never sees `platform/ingress/reserved-ports.yaml` at all, and
  `check_reserved_ports.py` falls back to `PLATFORM_FIXED_PORTS`, a small hardcoded constant (80,
  443 -- the ingress Gateway's own fixed ports, true in every SCRAP release and every topology,
  per `platform/ingress/README.md`) standing in for the file that isn't there. This is enough to
  stop an operator's own app from claiming one of those two specific ports by accident, and enough
  to let their own apps' declarations be checked against each other -- but it is **not** a general
  cross-repository check against whatever the pinned upstream release happens to reserve beyond
  those two fixed ports (today, none beyond the one legacy entry below, which is an
  `apps-examples` port that doesn't exist in an operator's own Topology B repository in the first
  place). That gap is pre-existing and unchanged by this record -- Topology B's own CI has never
  had visibility into the pinned upstream's repository content, for any check, not just this one --
  and is called out here rather than silently assumed away.

## What this record leaves undone

`apps/examples/p4-raw-tcp/` -- the P4 pattern's own worked example -- is **not** migrated to its
own `reserved-ports.yaml` by this record. Its port 9000 stays declared in
`platform/ingress/reserved-ports.yaml`, marked there as a deliberately unmigrated legacy entry.

This isn't an oversight: migrating it atomically requires a single change that removes the entry
from `platform/ingress/reserved-ports.yaml` *and* adds it to
`apps/examples/p4-raw-tcp/reserved-ports.yaml` together -- if either half lands without the other,
either the port becomes briefly unreserved (removed from the platform file, not yet declared by
the app) or briefly double-reserved (declared in both places, which this record's own new
collision check correctly rejects). A single pull request making both changes at once touches both
`apps/` and `platform/`, which is exactly what `check_app_addition_boundary.py`'s diff rule
forbids -- unconditionally, with no carve-out for "this change doesn't add a new application, it
relocates an existing declaration." Splitting it into two sequential pull requests doesn't avoid
the problem either, since each intermediate state is exactly the failure this record's collision
check (or the pre-existing "declared somewhere" check) is supposed to catch, and rightly does.

Weakening `check_app_addition_boundary.py` to carve out this shape of change was considered and
rejected here: that check has never been modified since it was first written, precisely because
its unconditional diff rule *is* what makes T2 a proof rather than a convention. Deciding whether
an exception is warranted -- and if so, how narrowly to scope it so it can't become a general
escape hatch -- is a genuine, independently-scoped architectural question this record does not
decide unilaterally. It's recorded as a `FOLLOW-UP` on PLAT-115 for adjudication. Until that's
resolved, the example stays on its original, still-fully-valid central-file declaration; nothing
about the new mechanism requires migrating it for the mechanism itself to work for every new P4
app going forward.

## What changed to support this

- `tests/assertions/check_reserved_ports.py`: now merges `platform/ingress/reserved-ports.yaml`
  (or the `PLATFORM_FIXED_PORTS` fallback when that file is absent) with every
  `apps/**/reserved-ports.yaml`, and flags any `(port, protocol)` declared in more than one source.
- `platform/ingress/reserved-ports.yaml`: header comment rewritten to describe the new mechanism
  and mark the port 9000 entry as a deliberately unmigrated legacy declaration; the entry itself
  unchanged.
- New fixtures under `tests/fixtures/violations/` proving the collision check fires (two
  applications claiming the same port; an application colliding with a `PLATFORM_FIXED_PORTS`
  entry in a Topology-B-shaped tree with no `platform/` directory), and under
  `tests/fixtures/valid/` proving an app's own declaration authorizes its own port cleanly with no
  `platform/` present at all.
- `docs/patterns/README.md`, `docs/core/application-contract.md`, `docs/adding-an-application.md`,
  `platform/ingress/README.md`, `tests/assertions/README.md`: updated to describe per-app
  declaration as the path for a *new* P4 app, while being explicit that the existing example
  predates this record.

## Consistent with

`0009-repository-topology.md` (T1/T2 unaffected in shape -- this record is precisely what makes
P4 actually honor T2 in practice for every new application, and makes Topology B's "no fork
required" promise hold for P4 specifically, which it previously did not); `0008-abstract-decisions-not-technologies.md`
(no new mechanism -- still a plain YAML file checked by a plain Python script, just colocated
differently); `docs/core/application-contract.md` (the two CI-checked invariants named there are
unchanged; this record is what makes both actually satisfiable together for pattern P4, for every
application added from now on).
