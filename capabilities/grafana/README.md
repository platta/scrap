# capabilities/grafana/

**FULLY SUPPORTED. Current implementation status: IMPLEMENTED, LIVE-TESTED** — see
`docs/release-readiness.md`. Depends on `platform/observability/` (reads the core Prometheus) only.

Grafana, via the official standalone `grafana/grafana` chart — **not** kube-prometheus-stack's own
bundled Grafana sub-chart, which `platform/observability/helmrelease.yaml` explicitly disables
(`grafana: { enabled: false }`, "capabilities/grafana/ owns Grafana entirely"). A separate
`HelmRelease` costs one more chart install; it buys T1 staying genuinely true — delete this whole
directory and `platform/observability/` is completely unaffected, no exception carved out for it.

Ships with a real Prometheus datasource already provisioned (`http://prometheus-operated.monitoring.svc.cluster.local:9090`
— the Prometheus Operator's own fixed Service name, the same convention `tests/profiles/t-a-minimal.sh`
already relies on for Alertmanager), and dashboard auto-discovery: any ConfigMap labeled
`grafana_dashboard: "1"` in any namespace loads automatically, via the chart's own sidecar — an
application ships its own dashboard the same way it ships its own `PrometheusRule`, no platform
change required.

Local admin authentication works unconditionally — the chart's own default admin account, nothing
this repository manages. Anonymous access is explicitly disabled (`auth.anonymous.enabled: false`),
stated plainly in `helmrelease.yaml` rather than left to trust the chart's own default.

Also ships a **Loki** datasource, provisioned the same unconditional way — see "The dependency
direction that matters" below. It answers real queries once `capabilities/logs/` is also enabled;
until then it's simply inert, the same as the OIDC Provider identity provisions whether or not this
capability is ever enabled.

## The dependency direction that matters

When `capabilities/identity/` is also enabled, **the identity capability** supplies Grafana's OIDC
client configuration — this directory never references identity, checks whether it exists, or
branches on it. `capabilities/identity/blueprints-configmap.yaml` provisions a Grafana OAuth2
Provider unconditionally (the same way it already does for the P2/P3 example apps — an unused
Provider costs nothing if this capability is never enabled), including a custom `groups` scope
mapping and a dedicated `scrap-admins` group, since authentik ships no default "groups" OAuth claim.
Grafana's own `role_attribute_path` reads that claim to decide `Admin` vs `Viewer` — a real,
attributable role mapping, not merely "some claims came back."

**The client secret exists in two namespaces, unavoidably.** Kubernetes Secrets are namespace-scoped
and there is no cross-namespace reference: identity's own `identity-credentials.sops.yaml` (in the
`authentik` namespace) supplies the value to the Blueprint via authentik's native `!Env` tag, and
this capability's own **optional** `clusters/<name>/secrets/grafana/grafana-oidc-credentials.sops.yaml`
(in the `monitoring` namespace) supplies the identical value to Grafana's own environment. An
operator enabling both capabilities together copies the same value into both files. This is not a
SCRAP shortcut — it's the same duplication any two independently-configured OAuth client/server
pairs require when they live in different trust domains.

**Enabling Grafana alone needs one file** (`cluster-kustomization.yaml`) — unlike
`capabilities/identity/` or `capabilities/public-tls/`, a credential-less install is genuine here,
since local auth needs nothing from this repository. Copy the second file
(`cluster-secrets-kustomization.yaml`) only when identity integration is also wanted.

## Workload CA trust — the real mechanism, reached a different way

`components/ca-trust/`'s Kustomize component can't attach to this capability: it patches a raw
`Deployment` object Kustomize builds directly, and this Deployment is chart-rendered by
helm-controller, invisible to Kustomize's own patching step. `helmrelease.yaml` reaches the *same*
mechanism — the real `scrap-ca-bundle` ConfigMap `platform/cert-manager-config/trust-bundle.yaml`
already publishes, mounted at the identical path and `SSL_CERT_FILE` value the component itself
uses — through the chart's own native `extraConfigmapMounts`/`env` extension points instead. Needed
for the same reason P2 needs it: Grafana's backend OAuth token exchange calls
`https://auth.${BASE_DOMAIN}`, private-CA-signed on the minimum path.

## New assumptions this introduces

None beyond `platform/`. No internet, no account, no domain. ~250–400 MB additional memory.
