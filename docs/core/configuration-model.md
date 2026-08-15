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

A capability is enabled by **the presence of its Flux `Kustomization` file** in
`clusters/<name>/capabilities/`. Enabling is copying one file from the capability's own directory;
disabling is deleting it. Git-diffable, reviewable in a pull request like any other change, no
conditional logic anywhere.

## Profiles

A "profile" is just a documented, named set of which capability files are present:

- **`minimal`** — `clusters/example/` as checked in: no capability files. The tested floor.
- **`standard`** — adds `grafana`, `logs`, typically alert delivery. What most installs will
  actually run.
- **`connected`** — adds off-site backup, public TLS, external heartbeat, external Git hosting.
  What most installs converge to over time.

Profiles are documentation, not a mechanism — there is no `profile: standard` setting anywhere.
