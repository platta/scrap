# capabilities/alert-delivery/

**Architectural classification: FULLY SUPPORTED. Current implementation status: IMPLEMENTED,
LIVE-TESTED** — see `docs/release-readiness.md` and `tests/profiles/t-a-alert-heartbeat.sh`'s own
`T-A-alert-heartbeat/alert-delivery-*` checks.

Depends on `platform/observability/` only (the `monitoring` namespace it creates unconditionally,
and the Prometheus Operator CRDs its `HelmRelease` installs) — never on `capabilities/grafana/` or
`capabilities/logs/`.

## The real mechanism

A single `AlertmanagerConfig` object (`alertmanagerconfig.yaml`) with one receiver: a generic
**webhook** — Alertmanager's own native receiver type
([`webhook_config`](https://prometheus.io/docs/alerting/latest/configuration/#webhook_config)), the
smallest mechanism that can honestly claim "alerts that actually reach you" without this project
authoring an SMTP client or a vendor-specific integration of its own. `docs/extensions/README.md`'s
own alert-delivery extension-point row already states the real contract this ships one instance of:
"Standard Alertmanager configuration — anything Alertmanager itself supports." Swap this receiver's
block for `emailConfigs`, `slackConfigs`, or any other native Alertmanager receiver type — nothing
else in this capability changes; the `AlertmanagerConfig` object is the extension seam, not a SCRAP
abstraction over it.

A generic webhook works unmodified with [ntfy](https://ntfy.sh) (point it at a topic's own publish
URL) and with any other HTTP endpoint willing to accept Alertmanager's own JSON payload shape —
covering the "ntfy" and "webhook" cases `docs/supported/README.md` and
`docs/release-readiness.md` have named since before this capability existed; SMTP is available as a
same-seam swap (`emailConfigs`) for an operator who wants it, not shipped by default here, to keep
this capability's own credential surface to one URL rather than a mail-relay credential this project
would then have to document a secret-rotation story for.

## Why an `AlertmanagerConfig` object, not editing `platform/observability/`'s own config

The capability boundary this whole repository enforces
(`capabilities/README.md`'s "may depend on `platform/`, never the reverse") rules out the obvious
alternative — setting `alertmanager.config` directly in `platform/observability/helmrelease.yaml` —
even though that field is literally what the chart's own comment there points at. Doing that would
mean every instance's CORE observability config differs depending on which optional capability
happens to be enabled, and disabling this capability would require reverting a `platform/` file, not
deleting a `capabilities/` one — T1 (delete the whole capability directory, nothing outside it is
affected) would no longer hold. `AlertmanagerConfig` is the native Prometheus-Operator mechanism for
exactly this seam: a namespace-scoped object that layers a receiver onto Alertmanager's config
without the base config ever changing. `platform/observability/helmrelease.yaml`'s own base
`alertmanager.config` therefore stays at the chart's untouched default — `route → receiver 'null'` —
for every instance, whether or not this capability is enabled; only the merged, running config
Alertmanager actually evaluates differs.

**Real routing gap, found live building this:** the Prometheus Operator's default
`alertmanagerConfigMatcherStrategy` (`OnNamespace`) strips whatever matcher an `AlertmanagerConfig`'s
own route declares on the `namespace` label and silently replaces it with `namespace: <the object's
own namespace>`. This object lives in `monitoring`, but `platform/observability-config/baseline-alerts.yaml`'s
own alerts mostly carry the *alerting workload's* namespace (`scrap-backup`, an application
namespace, a bare node) — never `monitoring` itself. Under the default strategy, this capability
would apply cleanly, report healthy, and genuinely deliver almost nothing: the exact silent-no-op
class of bug this project has already found once in this same file (`baseline-alerts.yaml`'s own
`NodeDown` comment, a different selector). `platform/observability/helmrelease.yaml` sets
`alertmanagerConfigMatcherStrategy.type: None` to disable that automatic injection — a generalization
of the same maximally-permissive-selector pattern already established there for every other
Prometheus Operator CRD (`podMonitorSelector: {}`, `serviceMonitorSelector: {}`, `ruleSelector: {}`),
not new architecture: it is a platform-level policy setting that costs nothing for an instance with
this capability disabled, and makes the object type usable at all for one with it enabled. See that
file's own comment for the full reasoning.

## Enabling this capability — two files, not one

Same shape as `capabilities/identity/`'s and `capabilities/public-tls/`'s: the credential (the
webhook URL — most real receivers, ntfy included, embed a topic name or bearer token directly in the
URL itself, so it's treated as credential material, never committed in plaintext) lives under
`clusters/<name>/secrets/`, never under `capabilities/`. Copy **both** into
`clusters/<name>/capabilities/`:

- `cluster-kustomization.yaml` → rename to `alert-delivery.yaml`. Installs the `AlertmanagerConfig`.
- `cluster-secrets-kustomization.yaml` → rename to `alert-delivery-secrets.yaml`. Installs
  `clusters/<name>/secrets/alert-delivery/` — the `alert-delivery-credentials` `Secret` (your
  `WEBHOOK_URL`) into the existing `monitoring` namespace.

Then replace the placeholder `WEBHOOK_URL` value in `alert-delivery-credentials.sops.yaml` with your
real receiver's URL (`cd clusters/<name>/secrets/alert-delivery && sops alert-delivery-credentials.sops.yaml`
— see `clusters/example/secrets/README.md` for the general re-encrypt-on-save pattern).

## Configuration errors fail visibly — verified, not assumed

If `WEBHOOK_URL` is missing or malformed, the Prometheus Operator does not silently fall back to
delivering nowhere in a way that looks like success — there is no SCRAP-authored fallback logic in
this path. This object's own `.status.conditions` records `Accepted: False` with the real reason
(`kubectl describe alertmanagerconfig -n monitoring scrap-alert-delivery`), and Alertmanager keeps
running on whatever the rest of the merged config already was — one broken `AlertmanagerConfig`
cannot take the whole delivery plane down, native Prometheus Operator behavior, not something this
capability adds. A genuinely unreachable or rejecting endpoint (the URL resolves and accepts
connections but the far side errors) surfaces in Alertmanager's own
`alertmanager_notifications_failed_total` metric — already scraped by CORE (`platform/observability/`'s
opt-in metrics contract requires nothing extra for Alertmanager's own `/metrics`, which the chart
wires in unconditionally) — and in Alertmanager's own logs.

## Acceptance evidence

Two distinct evidence levels, kept honestly separate:

**1. Static/structural — every push and PR, no external dependency:** the `AlertmanagerConfig`
object renders, is owned by this capability's own Kustomization (T1: absent from a `minimal`-profile
cluster), and the platform-level selector/matcher-strategy settings it depends on are present in
`platform/observability/helmrelease.yaml`.

**2. A real webhook delivery, against an ephemeral receiver this project stands up itself — every
push and PR, no external account (`tests/profiles/t-a-alert-heartbeat.sh`):** a from-zero bootstrap
with this capability enabled, `WEBHOOK_URL` pointed at a real, disposable HTTP listener the test
script runs on the same runner (reachable from inside the cluster the same way P6's external-proxy
example and `capabilities/offsite-backup/`'s own MinIO target already are — no mock, no
SCRAP-specific stand-in for the wire protocol); a genuinely-firing alert (the same deliberately-failed
backup job pattern `tests/profiles/t-a-minimal.sh` uses for its own `alert-reaches-surface` check)
is confirmed to arrive at that receiver as a real HTTP POST carrying Alertmanager's own webhook JSON
payload — not merely that it reached Alertmanager's `/api/v2/alerts` surface, which T-A already
proves independently. **Negative control:** the receiver's own request count is confirmed at zero
before the alert fires, closing the same class of vacuous-pass gap `capabilities/logs/`'s own
never-emitted-marker check closes.

**Honest limit of this level:** a *real* third-party receiver (a live ntfy topic, a real SMTP relay)
is not something CI can own an account for and never will be — this level proves Alertmanager
genuinely executes a webhook delivery to whatever `WEBHOOK_URL` resolves to, using the real webhook
wire protocol; it does not and cannot prove any one commercial provider's own API accepts the
payload. Confirming a real provider receives and displays your alert is the one operator-run step
this capability leaves to you, the same evidentiary shape `capabilities/public-tls/verify-live.sh`
already establishes for real-domain certificate issuance.

## New assumptions this introduces

An HTTP(S) endpoint willing to accept Alertmanager's own webhook JSON payload (a self-hosted relay,
or a hosted service like ntfy's free tier) and internet access to reach it, unless self-hosted
in-cluster. No new memory footprint of consequence — this capability is one CRD object, no new
workload.
