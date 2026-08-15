# platform/observability-config/

**Tier 2.** Depends on `platform/observability/` (the Prometheus Operator CRDs it needs must
already be installed — see `kustomization.yaml` in this directory, and
`platform/cert-manager-config/README.md` for the general pattern this repeats).

Three manifests:

- `podmonitor.yaml` — the **one** cluster-wide golden-path `PodMonitor`. An application opts in by
  labeling its pod `observability.scrap.io/scrape: "true"` and naming its metrics port `metrics` —
  no `PodMonitor` object of its own, ever.
- `cert-manager-podmonitor.yaml` — cert-manager's controller does **not** use the golden-path port
  name (`http-metrics`, not `metrics` — checked directly against the chart's rendered output), so
  it gets its own dedicated `PodMonitor` rather than a special case in the generic selector.
- `baseline-alerts.yaml` — the zero-configuration baseline `PrometheusRule`: pod crash-looping,
  pod not ready, node down, disk almost full, certificate expiring soon, certificate not ready.
  `BackupJobFailed` is deliberately **not** here yet — it belongs with `platform/backup/`, a later
  milestone, not shipped speculatively ahead of the thing it alerts on.
