# platform/observability/

**Tier 2.** Depends on `platform/crds/` only.

Provides: Prometheus, Alertmanager, kube-state-metrics, node-exporter, and the Prometheus Operator
CRDs (`PodMonitor`, `PrometheusRule`) that form the actual application metrics/alerting contract —
this directory is the `HelmRelease` only. The golden-path `PodMonitor` and baseline
`PrometheusRule` that actually *use* those CRDs live in the separate
`platform/observability-config/` Kustomization, `dependsOn` this one with `wait: true` — the same
real ordering bug documented in `platform/cert-manager-config/kustomization.yaml`: a Flux
Kustomization dry-runs all its resources together, so a raw manifest of a CRD kind cannot safely
share a Kustomization with the `HelmRelease` that installs that CRD.

## Why this is CORE and not an optional capability

The deciding argument, not the obvious one: **backup without alerting is not a safety system.** A
platform that backs up application data but cannot tell its operator that backups have stopped has
shipped the exact failure mode this whole project exists to prevent. The single most valuable alert
this layer carries is "a backup job failed" — see `platform/backup/`.

Alertmanager runs with **no receiver configured by default**, and that is a stated, visible fact at
install time, not a silent placeholder — bootstrap's postflight check reports this explicitly rather
than letting it go unnoticed the way it did in the reference implementation. Configuring a real
receiver (SMTP, ntfy, webhook) is `capabilities/alert-delivery/`, a separate optional capability
that wires delivery via a namespace-scoped `AlertmanagerConfig` object — this tier's own base
config never changes, for any instance, regardless of which capabilities it enables (see that
capability's own README, and `helmrelease.yaml`'s own `alertmanagerConfigMatcherStrategy` comment
for a real routing gap that mechanism alone would have hit). `capabilities/heartbeat/` is a
distinct, separate optional capability for knowing the *cluster itself* is unreachable, which no
in-cluster alert — delivered or not — can ever tell you.

## The application contract

- **Metrics** are opt-in: label a pod `observability.scrap.io/scrape: "true"`, name its metrics
  port `metrics`. One cluster-wide `PodMonitor` picks it up — no per-application `PodMonitor`
  object, ever.
- **Logs** are automatic for any app that logs to stdout (the log-shipping capability,
  `capabilities/logs/`, ships them onward; this tier only makes the metrics/alerting contract
  exist).
- **Alerts** beyond the baseline are opt-in: ship a `PrometheusRule`, auto-discovered.
- **Dashboards** are opt-in and live in `capabilities/grafana/`, not here — Grafana itself is a
  fully supported capability, not core.

Not in this repository's core: Grafana, Loki, Alloy. See `capabilities/grafana/` and
`capabilities/logs/`.
