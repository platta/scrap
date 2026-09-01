# Application contract

**CORE.** What an application can consume, and what adding one is allowed to require. See
[`docs/patterns/`](../patterns/) for how these compose into the six integration patterns.

## Mandatory for every application

Deployment only — ordinary manifests under `apps/`. Everything below is opt-in; an application that
consumes nothing but deployment is a complete, valid SCRAP application.

## What's available, and who has to know about it

| Capability | Provided by | What the application declares | What it does NOT need to know |
|---|---|---|---|
| Deployment/reconciliation | `platform/` (Flux) | Standard manifests | Nothing |
| Persistent storage | `platform/storage/` | A `PersistentVolumeClaim` | The `StorageClass` implementation |
| HTTP routing | `platform/ingress/` | An `HTTPRoute` | Which controller implements Gateway API |
| TLS | `platform/cert-manager/` | **Nothing** | Which issuer is active — private CA or ACME, never referenced |
| Raw TCP/UDP | `platform/ingress/` | A `LoadBalancer` `Service`, port declared in the app's own `reserved-ports.yaml` ([`0017`](../decisions/0017-p4-port-reservation-ownership.md)) | ServiceLB internals |
| Backup | `platform/backup/` | A label, optionally a consistency method via `components/backup/` | Destination, credentials, schedule, retention |
| Restore | `platform/backup/` | Nothing | The restore procedure itself |
| Metrics | `platform/observability/` | A pod label + a port named `metrics` | The scrape config |
| Logs | `capabilities/logs/` (if enabled) | Log to stdout | Everything else |
| Alerts | `platform/observability/` | A `PrometheusRule`, if it wants more than baseline | Nothing |
| Dashboards | `capabilities/grafana/` (if enabled) | A labelled `ConfigMap` | Nothing |
| Native OIDC | `capabilities/identity/` (if enabled) | Issuer URL + client `Secret` | Which product is the IdP |
| Forward-auth | `capabilities/identity/` (if enabled) | One `HTTPRoute` filter via `components/forward-auth/` | Everything about the auth flow |
| External LAN backend | none | A selectorless `Service` + `EndpointSlice` | — |
| Workload trust of the platform CA | `components/ca-trust/` | One line in `kustomization.yaml` | Which CA, or whether one is even needed (no-op on the ACME path) |

## The two things CI actually checks

1. A pull request that touches `apps/` may not also touch `platform/` or `capabilities/` — T2,
   enforced as a diff rule, not merely a convention.
2. No `Certificate` resource, and no `ClusterIssuer` reference, exists anywhere under `apps/` — the
   TLS half of "the application declares nothing" is proven statically, not just claimed.

See [`tests/assertions/`](../../tests/assertions/) for both.
