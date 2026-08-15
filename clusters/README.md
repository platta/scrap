# clusters/

**The only place instance-specific values live.** Every domain, IP address, email, timezone, and
retention setting a real install needs appears in exactly one place, under one of these
directories — never hardcoded into `platform/`, `capabilities/`, or `apps/`. CI checks this on every
pull request (`tests/assertions/`).

One directory per SCRAP instance. `clusters/example/` is the reference instance: a real,
documented, working `instance-config.yaml` schema and an empty `capabilities/` (nothing enabled —
the `minimal` profile). Copy it to start a real installation.

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
