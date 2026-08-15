# capabilities/grafana/

**FULLY SUPPORTED.** Depends on `platform/observability/` (reads the core Prometheus) only.

Grafana, with local authentication by default. Dashboards load from any ConfigMap labeled
`grafana_dashboard: "1"` in any namespace — an application ships its own dashboard the same way it
ships its own `PrometheusRule`, no platform change required.

## The dependency direction that matters

When `capabilities/identity/` is also enabled, **the identity capability** supplies Grafana's OIDC
client configuration — this directory never references identity, checks whether it exists, or
branches on it. Grafana without identity gets local auth; Grafana with identity enabled gets an
OIDC client wired in by the identity capability's own manifests. This is the concrete shape of the
one-directional dependency rule (`capabilities/README.md`), and it is the direct fix for the
reference implementation's `infra-monitoring dependsOn apps-authentik` defect.

## New assumptions this introduces

None beyond `platform/`. No internet, no account, no domain. ~250–400 MB additional memory.
