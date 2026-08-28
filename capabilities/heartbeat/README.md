# capabilities/heartbeat/

**Architectural classification: FULLY SUPPORTED. Current implementation status: IMPLEMENTED,
LIVE-TESTED** — see `docs/release-readiness.md` and `tests/profiles/t-a-alert-heartbeat.sh`'s own
`T-A-alert-heartbeat/heartbeat-*` checks.

Depends on `platform/observability/` only (the `monitoring` namespace it creates unconditionally,
and the `alertmanager-operated` Service its own `HelmRelease` creates), exactly as originally
designed. This is the **only** mechanism in SCRAP that can tell an operator the cluster itself is
unreachable: every other alert — delivered or not, `capabilities/alert-delivery/` included — lives
inside the cluster it monitors and is silent exactly when it matters most. Silence from the
heartbeat provider is meant to be the alarm.

## The real mechanism

One `CronJob` (`cronjob.yaml`), every 5 minutes: query Alertmanager's own `/-/healthy` liveness
endpoint — deriving health from the observability/Alertmanager plane that already exists, never a
parallel, SCRAP-authored health authority — and, **only if that check passes**, `POST`/`GET` a
configured URL at a third-party heartbeat/uptime provider (most offer a free tier: healthchecks.io,
Better Uptime, Uptime Kuma's own push-monitor mode, or any URL that treats "did I get pinged
recently" as its own alarm condition). If the check fails, or Alertmanager itself is unreachable, the
job deliberately withholds the push and exits successfully — **that withholding is the entire
point**: the external provider's own missed-ping detection is what should fire next, not this job.

This is a genuine dead-man's-switch, not a "ping succeeded" health check pushed the other direction:
a health check reports "I am up" only when queried and can itself go silently unreachable; a
dead-man's-switch inverts the failure mode so that *silence itself* is the signal, which is exactly
what's needed for the one failure class no in-cluster alert can ever report — the cluster (or this
job's own ability to reach the internet) being down.

**A CronJob, not a long-running process, is a deliberate choice, not an oversight:** a live process
that pushed continuously would need its own liveness story (who alerts if *it* crashes?) — Kubernetes
already re-schedules a `CronJob`'s missed executions and this project already has an established,
observable pattern for "did the scheduled thing actually run" (`platform/observability-config/baseline-alerts.yaml`'s
own `BackupStale`-style staleness alerts), so this reuses that shape rather than inventing a second
kind of long-running watcher.

## Enabling this capability — two files, not one

Same shape as `capabilities/identity/`'s, `capabilities/public-tls/`'s, and
`capabilities/alert-delivery/`'s: the credential (the provider's own ping URL — typically embeds a
unique check ID or token, so it's credential material, never committed in plaintext) lives under
`clusters/<name>/secrets/`, never under `capabilities/`. Copy **both** into
`clusters/<name>/capabilities/`:

- `cluster-kustomization.yaml` → rename to `heartbeat.yaml`. Installs the `scrap-heartbeat`
  `CronJob`.
- `cluster-secrets-kustomization.yaml` → rename to `heartbeat-secrets.yaml`. Installs
  `clusters/<name>/secrets/heartbeat/` — the `heartbeat-credentials` `Secret` (your
  `HEARTBEAT_PING_URL`) into the existing `monitoring` namespace.

Then:

1. Create a check with a third-party heartbeat/uptime provider, set its expected interval to
   comfortably more than 5 minutes (10–15 minutes gives margin for one missed run without a false
   alarm), and copy its own ping URL.
2. Replace the placeholder `HEARTBEAT_PING_URL` value in `heartbeat-credentials.sops.yaml` with that
   URL (`cd clusters/<name>/secrets/heartbeat && sops heartbeat-credentials.sops.yaml` — see
   `clusters/example/secrets/README.md` for the general re-encrypt-on-save pattern).
3. **Configure the provider's own alert channel** (email, SMS, push — whatever it offers) so *it*
   can reach you when pings stop. This capability only ever pushes signal outward; the provider's own
   notification path back to you is outside anything this repository controls or tests — the same
   "operator-run, not CI-executed" boundary `capabilities/public-tls/verify-live.sh` already draws
   for real certificate issuance.

## Configuration errors fail visibly — verified, not assumed

A missing or malformed `HEARTBEAT_PING_URL` makes the push `curl` call fail (`-f`, so a non-2xx
response counts as failure), which — under this script's own `set -e` — fails the whole `Job`
visibly (`Job` status `Failed`, inspectable via `kubectl get jobs -n monitoring`), never a silent
no-op. There is no SCRAP-authored fallback or retry-and-ignore logic in this path.

## Acceptance evidence

Two distinct evidence levels, kept honestly separate:

**1. Static/structural — every push and PR, no external dependency:** the `CronJob` renders, is
owned by this capability's own Kustomization (T1: absent from a `minimal`-profile cluster), and
makes no Kubernetes API call of its own (`automountServiceAccountToken: false` — verified
structurally, not merely asserted in prose).

**2. A real conditional push, against an ephemeral receiver this project stands up itself — every
push and PR, no external provider account (`tests/profiles/t-a-alert-heartbeat.sh`):** a from-zero
bootstrap with this capability enabled, `HEARTBEAT_PING_URL` pointed at a real, disposable HTTP
listener the test script runs on the same runner (reached in-cluster the same way P6's
external-proxy example and `capabilities/offsite-backup/`'s own MinIO target already are). Both
directions are proven, not just the happy path:

- **Positive:** with Alertmanager healthy (the normal, already-bootstrapped state), a manually
  triggered run of the `CronJob` genuinely reaches the ephemeral receiver — a real HTTP request
  observed arriving, not inferred from the `Job`'s own exit status alone.
- **Negative control, the actual dead-man's-switch invariant:** with Alertmanager's own
  `StatefulSet` deliberately scaled to zero (a real, live-induced unhealthy/unreachable state — not
  a mocked response), a fresh triggered run makes **zero** requests to the receiver and still exits
  successfully — proving the withholding behavior is real, not merely documented, closing the same
  class of vacuous-pass gap `capabilities/logs/`'s own never-emitted-marker check closes for a
  different capability. Alertmanager is scaled back up and confirmed healthy again before the script
  ends.

**Honest limit of this level:** a *real* third-party provider's own missed-ping alarm and its own
notification channel (email, SMS, push) are not something CI can own an account for and never will
be — this level proves the `CronJob`'s own conditional logic is genuinely correct against a real HTTP
target; it does not and cannot prove any one commercial provider's own detection or notification
path. That is the operator-run step described above, under "Enabling this capability."

## New assumptions this introduces

Internet access and an account with a heartbeat/uptime provider (most offer a free tier). No cloud
spend required, no new meaningful memory footprint — one CronJob, no persistent workload.
