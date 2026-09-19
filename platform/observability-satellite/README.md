# platform/observability-satellite/

**Tier 2.** A Kustomize *overlay* of `platform/observability/` (`resources: - ../observability`),
never a fork of it — see `docs/decisions/0018-observability-topology.md` for the full design this
implements. Depends on `platform/crds/` only, exactly like the base it overlays.

One of the three CORE observability **topology** choices (`standalone` — the default,
`platform/observability/` unchanged — `satellite` — this directory — and `hub`, not yet
implemented). Topology is an instance decision, never a per-application or per-capability one;
selecting it does not touch `platform/observability-config/`, which stays a single,
topology-invariant artifact — the golden-path `PodMonitor` and baseline `PrometheusRule` are
identical, and evaluated identically, in every topology.

## What this actually changes, and what it doesn't

Everything `platform/observability/README.md` says about standalone stays true here: Prometheus
Operator + CRDs, node-exporter, kube-state-metrics, the golden-path `PodMonitor`, the baseline
rules, and Alertmanager all still run **locally**, and the alerting invariant — "backup without
alerting is not a safety system" — is evaluated and delivered exactly the same way. What genuinely
changes, via `values-patch.yaml`'s delta onto the base `HelmRelease`:

- **Retention drops** from 14d to 6h — a small multiple of the longest baseline rule's lookback
  window (15m), never the literal minimum; local rule evaluation only ever needs recent data.
- **Storage shrinks** from 8Gi to 1Gi — the honest resource statement `docs/decisions/0018`
  states: this is the genuinely guaranteed saving, disk only, **not** primarily a RAM optimization
  (Prometheus memory is dominated by active series, not retention).
- **`remoteWrite` is added**, shipping this satellite's series to one configured external
  destination — Prometheus remote-write 1.0, the supported v1 transport contract. The destination
  needs to satisfy nothing more than "accepts remote-write, plus whatever auth it requires" — a
  SCRAP hub is one compatible destination, never a requirement (`docs/decisions/0018`'s own
  "Topology is not provider" section).
- **`remote-write-health-alerts.yaml` is added** — the F3 telemetry-path-health baseline rule
  (`SatelliteRemoteWriteFailing`, `SatelliteRemoteWriteStale`), meaningless in standalone (which
  has no remote-write to lose) and therefore not part of the topology-invariant
  `platform/observability-config/`.

## Enabling this topology

Two edits, both under `clusters/<name>/` — never a fork of this directory:

1. **Replace** the content of your existing `clusters/<name>/platform-observability.yaml` with
   `cluster-kustomization.yaml`'s content (same filename, same Kustomization name — every
   dependent, e.g. `platform-observability-config`, keeps working unchanged). This is a
   *replacement*, not an addition — see that file's own header for why CORE topology selection
   is not the same "copy a new file in" shape a capability uses.
2. **Add** `cluster-secrets-kustomization.yaml`'s content as a new
   `clusters/<name>/platform-observability-satellite-secrets.yaml`, and list it in
   `clusters/<name>/kustomization.yaml`'s `resources:`.

Then, **create** (not edit — there is no pre-existing placeholder to fill in, a deliberate,
stated deviation from every other capability's two-file-copy convention, since this credential
has no meaningful placeholder value to ship ahead of a real destination):

```sh
mkdir -p clusters/<name>/secrets/observability-satellite
cat > clusters/<name>/secrets/observability-satellite/kustomization.yaml <<'EOF'
# No namespace.yaml -- lands in "monitoring", which platform-observability
# already creates unconditionally in every topology.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - observability-satellite-credentials.sops.yaml
EOF
# Written directly under its FINAL name (still plaintext at this point) --
# `sops -e plaintext.yaml > plaintext.sops.yaml` never actually shows sops
# the output filename (shell redirection is invisible to the sops
# process), so clusters/<name>/.sops.yaml's own creation_rules
# (`path_regex: secrets/.*\.sops\.ya?ml$`) would be matched against the
# INPUT path instead, which doesn't end in ".sops.yaml" and never
# matches ("no matching creation rules found"). Naming it correctly up
# front and encrypting in place (`-i`) avoids this.
cat > clusters/<name>/secrets/observability-satellite/observability-satellite-credentials.sops.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: observability-satellite-credentials
  namespace: monitoring
stringData:
  SATELLITE_REMOTE_WRITE_USERNAME: "changeme"
  SATELLITE_REMOTE_WRITE_PASSWORD: "changeme"
EOF
cd clusters/<name>/secrets
sops -e -i observability-satellite/observability-satellite-credentials.sops.yaml
```

Finally, set `SATELLITE_REMOTE_WRITE_URL` in `clusters/<name>/instance-config.yaml` to your
destination's remote-write endpoint (e.g. `https://hub.example.internal/api/v1/write`, or a SCRAP
hub's own address once that topology exists).

Revert to standalone by restoring `platform-observability.yaml`'s original content and removing
the two secrets-related files/entries — the same reverts-cleanly shape every other topology-file
swap in this repository proves live.

## Honest limits

- **F2 (whole node death) is not detected by anything in this directory.** A satellite whose node
  or k3s dies entirely leaves nothing local to alert — see `capabilities/heartbeat/` (strongly
  recommended in this topology) and, once implemented, hub-side absence detection. Postflight
  states plainly which of these, if any, are armed for this instance.
- **WAL buffering during an outage is finite, not infinite.** A sufficiently long telemetry-path
  outage loses samples for the *destination's* history once the buffer is exceeded — local rule
  evaluation never depended on them regardless.
- **This directory makes no ARM64/small-node claim.** The honest resource statement above is
  disk only; whether the resulting memory floor fits a genuinely small node is empirical,
  unproven here, and owned by separate small-node validation work.
- Whether satellite belongs to final v1's claim set or lands post-v1 is not decided by this
  directory — see `docs/decisions/0018-observability-topology.md`.
