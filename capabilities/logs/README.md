# capabilities/logs/

**Architectural classification: FULLY SUPPORTED.** **Current implementation status: DESIGNED, NOT
YET IMPLEMENTED** — this directory contains only this README; no `Kustomization`, `HelmRelease`, or
other manifest exists yet, so there is nothing to enable. See `docs/release-readiness.md` for the
current, repository-wide proven/unproven/deferred snapshot. This capability is also part of the
frozen `T-B` acceptance definition (identity + Grafana + logs) — `tests/profiles/t-b-standard.sh`
does not test it, because it doesn't exist yet, not because of a gap in T-B's own implementation.

Once built, this is intended to depend on `platform/observability/` only, and to work as follows:
Loki (single-binary, filesystem storage — no object storage backend needed) and Grafana Alloy as a
DaemonSet, discovering every pod via the Kubernetes API and shipping stdout to Loki. An application
would do nothing to participate beyond logging to stdout, which every well-behaved container image
already does.

## New assumptions this introduces

None beyond `platform/`. No internet, no account. ~300 MB additional memory. Purely operational
value — disabling this capability affects nothing in the recovery model (`docs/core/recovery-model.md`).
