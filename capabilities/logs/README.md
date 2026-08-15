# capabilities/logs/

**FULLY SUPPORTED.** Depends on `platform/observability/` only.

Loki (single-binary, filesystem storage — no object storage backend needed) and Grafana Alloy as a
DaemonSet, discovering every pod via the Kubernetes API and shipping stdout to Loki. An application
does nothing to participate beyond logging to stdout, which every well-behaved container image
already does.

## New assumptions this introduces

None beyond `platform/`. No internet, no account. ~300 MB additional memory. Purely operational
value — disabling this capability affects nothing in the recovery model (`docs/core/recovery-model.md`).
