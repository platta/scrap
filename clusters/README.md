# clusters/

**The only place instance-specific values live.** Every domain, IP address, email, timezone, and
retention setting a real install needs appears in exactly one place, under one of these
directories — never hardcoded into `platform/`, `capabilities/`, or `apps/`. CI checks this on every
pull request (`tests/assertions/`).

One directory per SCRAP instance. `clusters/example/` is the reference instance: a real,
documented, working `instance-config.yaml` schema and an empty `capabilities/` (nothing enabled —
the `minimal` profile).

## You do not need to fork this repository to run SCRAP

Copying `clusters/example/` into a fork/clone of this repository (**Topology A**) is the simplest
way to start, and is what this repository's own CI and scratch validation exercise end to end. But
it is not the only supported way: an operator can instead maintain a **separate repository**
containing only their `clusters/<name>/`, `apps/`, and `secrets/`, pinned to a specific released
version of `platform/`/`capabilities/`/`components/` here via a second Flux `GitRepository` source
(**Topology B**) — no fork, no merging against upstream changes just to add an application. Every
`Kustomization` in `clusters/example/` already names its source explicitly
(`sourceRef.name: scrap`); adopting Topology B is a one-line change to that field, repeated per
file. Full mechanism, a worked example, and why this needs no SCRAP-specific abstraction:
`docs/decisions/0009-repository-topology.md`.

## How instance values reach manifests

Flux's built-in `postBuild.substituteFrom` — no templating language, no new tooling. A manifest
under `platform/`, `capabilities/`, or `apps/` references `${VAR_NAME}`; the value is defined once,
in this instance's `instance-config.yaml`. CI checks that every referenced variable is defined
somewhere under `clusters/`, and that no file outside `clusters/` contains a literal value (an IP
address, in particular) that should have been a variable instead.

## How a capability is enabled

By the **presence** of its Flux `Kustomization` file in `clusters/<name>/capabilities/`. Enabling a
capability is copying one file from the capability's own directory; disabling it is deleting that
file. A "profile" (`minimal`, `standard`, `connected`) is just a documented set of which files are
present — see `docs/core/configuration-model.md`.
