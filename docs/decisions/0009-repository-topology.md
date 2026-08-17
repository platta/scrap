# 0009 — Repository topology: monorepo vs. a separate operator repository

**Decision:** SCRAP supports two repository topologies natively, using Flux's own multi-source
mechanism — **no SCRAP-specific abstraction is introduced**. Operators are not required to fork
this repository merely to configure an installation.

## The question

Everything built so far — `clusters/example/` — lives inside `platta/scrap` itself and points at
itself: every `Kustomization`'s `spec.sourceRef.name: scrap` refers to the same `GitRepository` the
whole repository was cloned as. That's the simplest possible starting point, but it implicitly
assumes an operator forks or clones this repository and edits `clusters/<name>/` in place —
meaning every operator install carries a full copy of `platform/`, `capabilities/`, and
`components/`, and picking up upstream changes means merging against a fork. Reasonable for a
first install; not what most operators should have to live with long-term.

## The answer: Flux already solves this

A Flux `Kustomization`'s `spec.sourceRef` can name **any** `GitRepository` (or `OCIRepository`)
object that exists in the cluster — not only the one the root bootstrap `Kustomization` itself was
applied from. This is documented, native Flux behavior, used throughout the Flux ecosystem for
exactly this "consume a shared upstream, keep your own overlay separate" shape. SCRAP invents
nothing here.

### Topology A — Monorepo (fork/clone)

What exists today. Simplest to start from. The operator's repository *is* a copy of
`platta/scrap`; `clusters/<name>/`'s Kustomizations reference the single self-named `scrap`
`GitRepository`. Upgrading means merging or rebasing against upstream.

### Topology B — Separate operator repository + pinned upstream source

The operator's own repository contains **only**: `clusters/<name>/` (instance config,
capability-enabling files, and the platform-tier pointer `Kustomization`s — copied once from
`platta/scrap`'s `clusters/example/`, not maintained as a fork), their own `apps/`, and their own
`secrets/` (SOPS-encrypted, always instance-specific regardless of topology). It contains **no
copy** of `platform/`, `capabilities/`, or `components/` at all.

Two Flux sources exist in the cluster:

```yaml
# In the operator's own repo — this is what Flux is bootstrapped against.
# D5 unaffected: this can be a local bare repository for the minimum profile.
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m0s
  ref: { branch: main }
  url: ssh://git@example.com/my-scrap-instance.git
---
# ALSO in the operator's own repo -- a pinned reference to the upstream
# platform. Pin via a tag once SCRAP starts cutting releases; a specific
# commit SHA works identically in the meantime -- both are equally "pinned."
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: scrap-platform
  namespace: flux-system
spec:
  interval: 1h
  ref: { tag: v0.3.0 } # or: { commit: <sha> }
  url: https://github.com/platta/scrap
```

Every platform-tier `Kustomization` the operator copied from `clusters/example/` changes exactly
one field:

```diff
 apiVersion: kustomize.toolkit.fluxcd.io/v1
 kind: Kustomization
 metadata:
   name: platform-ingress
   namespace: flux-system
 spec:
   interval: 10m0s
   path: ./platform/ingress
   prune: true
   sourceRef:
     kind: GitRepository
-    name: flux-system
+    name: scrap-platform
   dependsOn:
     - name: platform-crds
     - name: platform-cert-manager-config
```

`flux-system` is not an arbitrary choice — it's the name `flux bootstrap git` itself creates for
the operator's own repository by convention, every time, regardless of topology. Every
`Kustomization` under `clusters/example/` in this repository already targets `flux-system` for
exactly this reason: it's what `bootstrap/install.sh` (running `flux bootstrap git`) actually
produces, verified end to end, not assumed.

`spec.path` is unchanged — it resolves inside whichever source `sourceRef` names. This is the
entire diff. Every `platform/`, `capabilities/`, and `components/` manifest in this repository is
already topology-agnostic by construction: none of them reference a source name themselves, and
none of them need to change for this to work.

### Components across repositories

`components/` (`backup/`, `forward-auth/`, `metrics/`, `ca-trust/`) are plain Kustomize
components. An application's own `kustomization.yaml`, living in the operator's repo, references
one via Kustomize's native **remote base** syntax instead of a local relative path:

```yaml
components:
  - https://github.com/platta/scrap//components/backup?ref=v0.3.0
```

Also native — no SCRAP mechanism, standard Kustomize remote-resource resolution.

## Why this doesn't touch anything frozen

- **T1/T2** are about the *relationship* between `platform/`, `capabilities/`, and `apps/` — not
  about which repository each physically lives in. Topology B doesn't weaken either invariant; if
  anything, a repository boundary makes "platform never depends on an application" harder to
  violate by accident than a directory convention alone.
- **D5** (a local bare Git repository is sufficient for the minimum profile) is about the repo
  Flux is bootstrapped against — unaffected. The pinned upstream source is a second,
  separately-polled `GitRepository`, reachable at install/update time the same way an
  `HelmRepository` already is; it is not a runtime dependency of an already-reconciled cluster.
- **The transparency principle** (`0008-abstract-decisions-not-technologies.md`) is reinforced,
  not compromised: the entire mechanism is Flux's own documented multi-source model and Kustomize's
  own remote-resource syntax. An operator who wants to understand it reads Flux's `GitRepository`
  docs, not a SCRAP-specific page.

## What this means for `bootstrap/`

**Nothing changes in `bootstrap/`'s own implementation.** Its job — install k3s, seed the age key,
run `flux bootstrap` against a repository URL the operator provides — is identical regardless of
which topology that repository follows. The topology choice is entirely about what an operator
puts inside `clusters/<name>/`, never about how `bootstrap/` gets Flux running. `bootstrap/`'s
documentation should mention both topologies are supported and link here; its scripts need no
topology-specific branching.

## Required for v1: a Topology B generator

**Recorded 2026-08-17, operator decision — supersedes this ADR's original "open, non-blocking"
framing below.** Topology B must become an implemented, tested onboarding path, not merely an
architectural possibility documented above. Tracked in the roadmap (repository root `README.md`).

Scope:

- A generator/scaffold tool — a script, not a new abstraction — that produces a minimal, standalone
  operator repository containing only `clusters/<name>/`, the operator's own `apps/`, and
  `secrets/`, correctly wired to a pinned SCRAP upstream release exactly per this ADR's "Topology
  B" section above (the `scrap-platform` `GitRepository`, and every copied `Kustomization`'s
  `sourceRef.name` already pointed at it) — with zero manual reconstruction of that diff by the
  operator.
- Output must stay ordinary Flux/Kustomize/SOPS resources — no proprietary SCRAP configuration
  format, no generated indirection layer that isn't itself a plain manifest a reader can open and
  understand (the transparency principle, `0008-abstract-decisions-not-technologies.md`). The
  generated repository should be small enough that an operator can read the whole thing and see
  exactly how their instance consumes upstream SCRAP.
- Must not require GitHub, or any specific host. Generation produces a normal Git repository;
  hosting it — a local bare repo over SSH, GitHub, GitLab, Forgejo, anything else with a Git
  remote — is the operator's choice, never something the generator assumes or bakes in.
- Requires an automated test (`tests/dr/` or `tests/profiles/`) demonstrating that a repository the
  generator produced actually bootstraps and reconciles a clean SCRAP installation end to end —
  not merely that the generator's output looks structurally correct.

### Previously open, folded into the scope above

- SCRAP does not yet cut tagged releases — Topology B is fully usable today pinned to a commit
  SHA, but a real release/tagging convention makes "pinned/versioned" mean what it should. Still
  tracked as its own piece of future work; the generator can target a commit SHA in the meantime.
- Whether `clusters/example/` should ship a second, explicitly-labeled static example demonstrating
  Topology B's `sourceRef` diff is superseded by the generator itself: a generated repository *is*
  the Topology B example, produced on demand rather than hand-maintained statically alongside
  `clusters/example/`.
