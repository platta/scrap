# capabilities/logs/

**Architectural classification: FULLY SUPPORTED. Current implementation status: IMPLEMENTED,
LIVE-TESTED** — see `docs/release-readiness.md` and `tests/profiles/t-b-standard.sh`'s own
`T-B/logs-*` checks. This capability is also part of the frozen `T-B` acceptance definition
(identity + Grafana + logs) — that gap is now closed: `tests/profiles/t-b-standard.sh` proves a
real log record enters the shipped path and is retrievable, through Grafana's own configured data
source, not just that components report Ready.

Depends on `platform/observability/` only (the `monitoring` namespace it creates unconditionally),
exactly as originally designed — never on `capabilities/grafana/`. Grafana integration is wired
from the other side, the same direction `capabilities/grafana/`'s own OIDC integration with
`capabilities/identity/` already works: `capabilities/grafana/helmrelease.yaml` provisions a Loki
datasource unconditionally, inert unless this capability happens to be enabled too (same reasoning
that file's own README gives for its unused-if-disabled OAuth Provider).

## The real mechanism

Loki (single-binary deployment mode, filesystem storage — no object storage backend, no MinIO) and
Grafana Alloy as a DaemonSet, discovering every pod via the Kubernetes API
(`discovery.kubernetes`, `role = "pod"`) and tailing its stdout the same way —
[`loki.source.kubernetes`](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.kubernetes/),
which reads through the kubelet's own `pods/log` subresource (the same one `kubectl logs` uses),
**not** a `hostPath` mount of the node's `/var/log`. That was a deliberate choice, not the only
option the upstream chart offers: it means the DaemonSet needs no privileged container, no root
user, and no node filesystem access at all — one fewer host-level assumption, consistent with this
capability's own "no new assumptions beyond `platform/`" promise. The tradeoff, stated plainly: it
costs more Kubelet API traffic/CPU per log line than the hostPath-tailing alternative
(`loki.source.file`) would. At this project's scale (a home cluster, not a fleet), that tradeoff is
the right one.

An application does nothing to participate beyond logging to stdout, which every well-behaved
container image already does — no per-app label, no sidecar, no opt-in (unlike the metrics
contract in `platform/observability/README.md`, which *is* opt-in). Every pod on every node is
tailed unconditionally, the same way `platform/observability/`'s own baseline covers every node's
resource metrics without an opt-in.

Log lines are labeled `namespace`, `pod`, `container`, `node` — enough to filter by any of them in
Grafana's Explore view or a LogQL query, without carrying every raw Kubernetes metadata label as a
Loki stream label (a real, previously-observed Loki cardinality/cost problem this design avoids on
purpose).

## Enabling this capability

One file — no credential of its own, the same reasoning `capabilities/grafana/README.md` gives for
being a single-file capability:

```
cp capabilities/logs/cluster-kustomization.yaml clusters/<name>/capabilities/logs.yaml
```

Disabling is deleting that one file. `capabilities/logs/helmrelease-loki.yaml` and
`helmrelease-alloy.yaml` never reference each other's HelmRelease directly — both are owned by the
one Kustomization this file applies, so T1 (delete the whole directory, nothing outside it is
affected) holds for the pair together, the same as any other single-Kustomization capability here.

## Querying

Through Grafana (once `capabilities/grafana/` is also enabled): the **Loki** datasource this
capability's presence makes functional, via Explore or a dashboard panel — the exact path
`tests/profiles/t-b-standard.sh`'s own `T-B/logs-marker-ingested-and-queried` check proves live.
Without Grafana: Loki's own HTTP query API directly,
`http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/query_range`, from inside the cluster
(there is no `HTTPRoute` for Loki itself — it is not meant to be reached from outside the cluster
at all; Grafana is the intended query surface for a human).

## Honest limitations

* **Retention is a fixed 7 days** (`limits_config.retention_period: 168h`, compactor-driven
  deletion), hardcoded the same way `platform/observability/helmrelease.yaml` hardcodes
  Prometheus's own 14-day retention — a tuning default, not an instance-specific value exposed
  through `docs/core/configuration-model.md`'s `${VAR}` mechanism. An operator who wants a
  different window edits `capabilities/logs/helmrelease-loki.yaml` directly.
* **No disk-pressure alert.** The 10Gi `local-path` PersistentVolumeClaim backing Loki's chunks and
  index can still fill before 7-day retention catches up under a genuine log storm; nothing in this
  capability pages an operator about it. `platform/observability/`'s own baseline alerts don't cover
  it either. Left as explicit future work, not silently assumed safe.
* **No log-based alerting.** This capability ships collection, storage, and query — not a rule
  engine over log content. `platform/observability/`'s `PrometheusRule` mechanism remains the
  supported way to alert on anything measurable; a metric derived from logs (e.g. an error-rate
  count) is out of scope here.
* Disabling this capability affects nothing in the recovery model
  (`docs/core/recovery-model.md`) — logs are operational telemetry, not application data; there is
  no backup/restore obligation for them, the same as metrics.

## New assumptions this introduces

None beyond `platform/`. No internet, no account. ~200–700 MB additional memory across Loki (one
replica) and Alloy (one pod per node) — see `helmrelease-loki.yaml`/`helmrelease-alloy.yaml`'s own
resource requests/limits for the exact numbers. Purely operational value.
