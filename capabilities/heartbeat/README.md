# capabilities/heartbeat/

**Architectural classification: FULLY SUPPORTED.** **Current implementation status: DESIGNED, NOT
YET IMPLEMENTED** — this directory contains only this README; no `Kustomization`, `HelmRelease`, or
other manifest exists yet, so there is nothing to enable. See `docs/release-readiness.md` for the
current, repository-wide proven/unproven/deferred snapshot.

Once built, this is intended to depend on `platform/observability/` only (pushing a periodic signal
derived from Alertmanager's own health), and to work as an external dead-man's-switch: a scheduled
push to a third-party heartbeat/uptime service. This would be the **only** mechanism in SCRAP that
can tell an operator the cluster itself is unreachable — every other alert lives inside the cluster
it monitors and is silent exactly when it matters most. Silence from the heartbeat service is meant
to be the alarm.

## New assumptions this introduces

Internet access and an account with a heartbeat provider (most offer a free tier). No cloud spend
required.
