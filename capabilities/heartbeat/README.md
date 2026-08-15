# capabilities/heartbeat/

**FULLY SUPPORTED.** Depends on `platform/observability/` (pushes a periodic signal derived from
Alertmanager's own health) only.

An external dead-man's-switch: a scheduled push to a third-party heartbeat/uptime service. This is
the **only** mechanism in SCRAP that can tell an operator the cluster itself is unreachable — every
other alert lives inside the cluster it monitors and is silent exactly when it matters most.
Silence from the heartbeat service is the alarm.

## New assumptions this introduces

Internet access and an account with a heartbeat provider (most offer a free tier). No cloud spend
required.
