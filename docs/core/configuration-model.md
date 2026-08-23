# Configuration model

**CORE.** Goal: instance values live in exactly one place, and enabling a capability is a file, not
a framework.

## Instance values

One SOPS-able ConfigMap/Secret pair per instance, at `clusters/<name>/instance-config.yaml` — see
`clusters/example/instance-config.yaml` for the real, documented schema (base domain, node address,
timezone, ACME email, backup retention, backup destination). Consumed via Flux's built-in
`postBuild.substituteFrom`. Scalars only. No templating language, no new tooling.

A manifest anywhere under `platform/`, `capabilities/`, or `apps/` references a value as
`${VAR_NAME}`; CI checks that every such reference resolves to a key defined in some instance's
config, and that no instance-specific literal — an IP address, in particular — appears outside
`clusters/` at all.

## Capability selection

A capability is enabled by **the presence of its Flux `Kustomization` file(s)** in
`clusters/<name>/capabilities/`. Enabling is copying file(s) from the capability's own directory;
disabling is deleting them. Git-diffable, reviewable in a pull request like any other change, no
conditional logic anywhere.

`clusters/<name>/capabilities/` is itself a real Flux `Kustomization` (`clusters/example/capabilities.yaml`)
pointed at that directory with deliberately no `kustomization.yaml` of its own — Flux's fallback
behavior for a path with no `kustomization.yaml` (discover and flatten every YAML file found) is
exactly the semantics this needs: any file placed there is picked up, none of them reference each
other except via their own explicit `dependsOn`.

**A capability needing its own credential is two files, not one** — a small, real exception to
"copying one file," found while implementing `capabilities/identity/` (the first capability built).
The credential itself lives under `clusters/<name>/secrets/`, never under `capabilities/`, so it
stays out of what Topology B treats as pinned, shared upstream content
(`docs/decisions/0009-repository-topology.md`). That means a second, small Flux `Kustomization`
pointed at the credential's own directory, alongside the capability's main one — see
`capabilities/identity/README.md`'s "Enabling this capability" section for the concrete pair, and
why the dependency between them runs in the direction it does (not always the same direction as
`platform-backup`/`platform-secrets` — it depends on whether the capability's workload is a
`CronJob` or something that starts immediately, like a `Deployment`).

## Profiles

A "profile" is just a documented, named set of which capability files are present:

- **`minimal`** — `clusters/example/` as checked in: no capability files. The tested floor.
- **`standard`** — adds `grafana`, `logs`, and `alert-delivery` (all implemented) — see
  `docs/release-readiness.md` for the current, authoritative snapshot. What most installs will
  actually run.
- **`connected`** — adds off-site backup, public TLS, and heartbeat (all implemented), plus external
  Git hosting (already available today via `bootstrap/install.sh`'s own `REPO_URL`, no capability
  file needed). What most installs converge to over time.

Profiles are documentation, not a mechanism — there is no `profile: standard` setting anywhere.
