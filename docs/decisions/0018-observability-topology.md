# 0018 — CORE observability topology: standalone, satellite, hub

**Decision:** SCRAP's CORE observability contract becomes explicitly topology-aware, with exactly
three modes — **standalone** (today's model, unchanged, still the default), **satellite** (local
collection and local baseline-rule evaluation, with metric storage shipped to a configured external
backend over a provider-neutral transport), and **hub** (a standalone deployment that additionally
accepts satellites' shipped metrics). The alerting invariant — backup without alerting is not a
safety system — is preserved in every mode by keeping baseline-rule evaluation and Alertmanager
**on the monitored node in all three topologies**; what a satellite externalizes is metric
*storage, retention, and dashboards*, never the alerting guarantee itself. The supported satellite
transport contract is Prometheus remote-write, which any compliant receiver satisfies — **a SCRAP
hub is one convenient compatible destination, never a requirement**. No new backend technology
(Mimir or otherwise) is introduced; hub ingestion for small fleets is the existing standalone
Prometheus with its native remote-write receiver enabled.

This record is design only. It authorizes deriving bounded implementation tickets (see
"Implementation decomposition" below); it does not itself change any manifest, and nothing below
is a support claim until the corresponding CI evidence exists
(`docs/release-readiness.md` discipline).

## The question

`platform/observability/` currently *is* CORE observability: Prometheus, Alertmanager,
kube-state-metrics, node-exporter, and the Prometheus Operator CRDs, all local to the instance,
with the golden-path `PodMonitor` and baseline `PrometheusRule`s in the separate
`platform/observability-config/` Kustomization. That conflates two decisions that are actually
independent:

1. **The contract** — what SCRAP guarantees an operator can observe and be alerted about
   (topology-independent).
2. **The placement** — where metric storage, retention, and dashboards live
   (a per-instance deployment decision).

A small node (the ARM64/Raspberry Pi validation target is the motivating example, not the design
target) should be able to run only what the contract genuinely requires locally and send the rest
to an existing observability stack elsewhere — without weakening SCRAP's mandatory visibility into
backup/platform health, and without that "elsewhere" having to be another SCRAP install.

## The invariant, stated independently of the implementation

What CORE observability must guarantee in **every** topology:

- **O1 — Backup failure and staleness must not silently disappear.** The baseline alert rules
  (`platform/observability-config/baseline-alerts.yaml`: backup, node, pod, disk, certificate)
  must exist and be continuously evaluated by a live rule engine against this instance's metrics,
  and their firing must reach whatever delivery is configured. This guarantee is SCRAP's to keep —
  a design that satisfies it only if an operator remembers to hand-maintain rules somewhere else
  has not satisfied it.
- **O2 — The metrics contract is unchanged.** Opt-in pod scraping via the golden-path
  `PodMonitor` label, node and cluster state via node-exporter and kube-state-metrics, application
  `PrometheusRule`s auto-discovered — exactly as `platform/observability/README.md` promises today.
- **O3 — Loss of the telemetry path must itself be detectable.** If metrics stop flowing —
  locally or to a remote destination — something must be able to say so, and the design must state
  *from which failure domain* that detection operates rather than implying the monitoring system
  can watch itself unconditionally.
- **O4 — Alert-delivery state stays explicit.** "No receiver configured, you will not be told if
  backups stop" is reported plainly (`bootstrap/postflight.sh`), never implied away. Topology adds
  new states of the same kind (see "Bootstrap, preflight, postflight" below) and they get the same
  treatment.
- **O5 — Bootstrap/postflight must prove or honestly report contract satisfaction for the chosen
  topology**, with the same evidence discipline as today: proven where a script can prove it,
  stated as an honest limit where it can't.

**No current invariant requires Prometheus/Alertmanager specifically to be local.** O1 requires a
rule engine and a delivery path *somewhere trustworthy*; O2 requires collection *locally*. The
implementation choice this record makes (local evaluation in every mode) is justified below on
provider-neutrality grounds, not because the invariant forces it.

**One invariant genuinely gets stronger with an external component.** Today, the death of the
whole node is invisible to in-cluster alerting — delivered or not, every alert lives inside the
cluster it monitors, which is exactly why `capabilities/heartbeat/` exists and why its README calls
silence the alarm. A satellite's external backend sits outside the monitored node's failure
domain, so *absence of recently-ingested telemetry* there can detect whole-node death — the one
failure class local evaluation can never see. The design below treats that as a layered addition
on the same two-domain model SCRAP already has (in-cluster alerting + external dead-man's-switch),
not as a replacement for either layer.

## The three topologies

### Component placement matrix

| Component / function | standalone | satellite | hub |
|---|---|---|---|
| Prometheus Operator + CRDs (`PodMonitor`, `PrometheusRule`, ...) | local | local | local |
| node-exporter, kube-state-metrics | local | local | local |
| Golden-path `PodMonitor` + baseline `PrometheusRule`s (`platform/observability-config/`) | local, unchanged | local, unchanged | local, unchanged |
| Prometheus | local, server mode, 14d retention | local, server mode, **short retention** (enough for rule lookback windows; ~hours, exact floor set at implementation), `remote_write` to the configured destination | as standalone, **plus** native remote-write receiver enabled |
| Baseline-rule evaluation | local | **local** (see next section) | local (self), plus hub-side satellite-staleness rules |
| Alertmanager + delivery | local | **local, unchanged** | local, unchanged |
| Long-term metric storage / dashboard-grade retention | local (14d) | external (the configured destination) | local, for itself and its satellites |
| `capabilities/grafana/` | optional, works | optional but of limited value locally (short retention); dashboards belong at the destination | optional; when enabled, its Prometheus datasource sees satellite series too |
| `capabilities/logs/` | optional, unchanged | optional, unchanged (log forwarding is deferred — see "Technology choices") | optional, unchanged |
| `capabilities/heartbeat/` | optional, recommended | optional, **strongly recommended** unless the destination provides absence detection | optional, recommended |
| `capabilities/alert-delivery/` | optional, unchanged | optional, unchanged | optional, unchanged |

### standalone

Exactly today's deployment, byte-for-byte the intended outcome for existing installs: full
`kube-prometheus-stack` per `platform/observability/helmrelease.yaml`, everything local. Remains
the default; an instance that says nothing about topology gets standalone. Minimum/recovery
guarantees, postflight behavior, and every documented honest limit are unchanged.

### satellite

Runs everything the contract requires **locally**: operator, exporters, the golden-path
`PodMonitor`, the baseline rules, a Prometheus in server mode with retention reduced to a small
multiple of the longest rule lookback window (currently 15m — `PodCrashLooping`'s
`increase(...[15m])`; `for:` durations are pending-state, not lookback, and need no retention),
and Alertmanager with the normal `capabilities/alert-delivery/` seam. Additionally configured with
`remote_write` to one external destination, carrying an instance-identifying external label
(reusing `INSTANCE_NAME`, which `clusters/<name>/instance-config.yaml` already defines for exactly
this "never merge two instances' timelines" purpose on the backup side).

What is genuinely external: storage beyond the local retention floor, dashboards, and (optionally,
where the destination supports it) absence-based detection of this satellite's own death.

What satellite does **not** change: the alerting invariant's mechanism (local rules, local
Alertmanager — a satellite whose WAN is down still pages about a failed backup exactly as
standalone does, to whatever delivery it can still reach); `capabilities/heartbeat/`'s mechanism
and value (it queries the local Alertmanager's `/-/healthy`, which still exists); the recovery
model (telemetry is operational data, not application data — no backup/restore obligation in any
topology, as `capabilities/logs/README.md` already states for logs).

**Honest resource statement:** satellite's guaranteed savings are retention disk (8Gi → ~1Gi) and
the absence of dashboard/query components from the small node. It is **not primarily a RAM
optimization**: Prometheus memory is dominated by active series, not retention, so the
server-mode satellite's memory floor is close to standalone's Prometheus request
(`platform/observability/helmrelease.yaml`: 256Mi request / 768Mi limit). Whether that floor fits
comfortably on a 4GB/ARM64 node is empirical and stays with the ARM64 validation work
(`docs/release-readiness.md`'s T-D row) — this design deliberately does not claim it. The
alternative that would cut RAM further (agent mode) is rejected below because it silently moves
the alerting guarantee off-node.

### hub

**Compositional, not a separate product shape:** a hub is a standalone deployment whose Prometheus
additionally accepts remote-write ingestion, exposed and authenticated (see "Security and trust"),
plus hub-side satellite-staleness rules. Everything standalone guarantees about the hub monitoring
*itself* is unchanged and is the same artifact. What the hub owes its satellites is deliberately
bounded: ingestion and retention of their shipped series, dashboard visibility over them when
`capabilities/grafana/` is enabled, and staleness/absence alerting keyed on the instance label —
**not** evaluation of the satellites' baseline rules (each satellite evaluates its own; see next
section) and **not** any claim about the satellites' own delivery paths.

A hub is one SCRAP instance trusting operator-owned satellites in the same trust domain. It is
explicitly **not** a multi-tenant observability service: satellites share one series namespace
distinguished by label, and nothing isolates a misbehaving satellite's cardinality or label claims
from the rest. That is a stated boundary, not a gap to be closed later by default.

## Topology is not provider: the transport contract

Two axes, configured independently:

- **Topology** — `standalone | satellite | hub`: where storage/retention lives and whether this
  instance ingests for others.
- **Transport/provider** — how a satellite's telemetry moves and what the destination must
  implement.

The supported satellite transport contract for v1 of this design is **Prometheus remote-write**
(the 1.0 wire format): the de-facto standard push protocol, implemented natively by the Prometheus
already in CORE (no new shipping component), and accepted by a wide receiver ecosystem. The
destination contract is exactly: *an endpoint that accepts Prometheus remote-write, plus whatever
authentication it requires*. SCRAP claims nothing about what the destination does with the data.

**Compatibility claims follow the repository's evidence discipline.** The only destination shape
CI will prove is "a remote-write receiver" — an ephemeral receiver the test stands up itself, the
same pattern `t-a-offsite-backup.sh` (MinIO) and `t-a-alert-heartbeat.sh` (ephemeral HTTP
receiver) already use. A SCRAP hub is additionally proven when the hub profile lands. Mimir,
Grafana Cloud, VictoriaMetrics, Thanos Receive and similar systems all implement remote-write
receive and are listed as **non-normative examples only** — none becomes "supported" by name
without its own evidence, and none is architecturally special. A SCRAP hub satisfies the same
contract any of them does; **satellite mode must work, and must be CI-proven, against a
destination that is not SCRAP**.

OTLP metrics ingestion/export is a deferred extension point, not the v1 contract (see "Technology
choices").

## Where baseline rules are evaluated in satellite mode

The decisive distinction: **sending metrics is not preserving the alerting invariant.** Shapes
evaluated:

1. **Remote metrics + externally managed rules** — the operator recreates the baseline rules on
   their backend. **Rejected as the guarantee mechanism:** O1 becomes "satisfied if the operator
   did undocumented manual work correctly and keeps it in sync with upstream rule changes," which
   is exactly the class of implied-but-untested claim this repository refuses elsewhere. Remains
   available as an operator extension on top, like any other use they make of their own backend.
2. **SCRAP-provisioned/validated remote rules** — SCRAP pushes its baseline rules into the
   destination's rule engine and verifies them. **Rejected for v1:** every real destination exposes
   a different rule-management control plane (Mimir ruler API, Grafana Cloud API, plain Prometheus
   has none for dynamic rules), so this is provider-specific by construction — the opposite of the
   contract-before-technology requirement — and it hands SCRAP write credentials to the
   destination's control plane, a larger trust surface than shipping samples. Recorded as a
   possible future per-provider extension, never the base guarantee.
3. **Local evaluation with external storage** — the satellite's own Prometheus (server mode,
   short retention) evaluates the unchanged `platform/observability-config/` rules; Alertmanager
   and delivery are local and unchanged; storage/retention is external. **Accepted.** The alerting
   invariant's mechanism is byte-identical across all three topologies, provider assumptions on
   the destination drop to "accepts remote-write," and the entire existing evidence base for
   alerting (postflight receiver reporting, `t-a-alert-heartbeat.sh`'s live delivery proof, the
   heartbeat negative control) carries over structurally rather than needing per-provider
   re-proof.

The honest limit of local evaluation — a dead node evaluates nothing — is the **same** limit
standalone has today, covered the same layered way: `capabilities/heartbeat/` (unchanged), plus,
new with this design, destination-side absence detection where the destination supports it
(guaranteed and shipped when the destination is a SCRAP hub; the operator's own affair otherwise,
and postflight says which of these states the instance is actually in — O4).

Agent mode (Prometheus agent / Alloy as the only local piece) was considered and **rejected as
the satellite baseline** precisely because agent mode cannot evaluate rules or serve queries:
choosing it would force shape 1 or 2 and silently convert O1 from a SCRAP guarantee into an
operator hope. Revisit only with empirical evidence (the decision-README rule) — concretely, if
small-node validation demonstrates the server-mode floor genuinely does not fit the hardware SCRAP
intends to support, that evidence reopens this trade, at which point shape 2 for the hub-destination
case (where SCRAP controls both ends) is the likely candidate.

## Failure modes: what detects what, from which failure domain

| # | Failure | Detected by | Detector's failure domain |
|---|---|---|---|
| F1 | Workload/backup job fails; node healthy | Local baseline rules → local Alertmanager → configured delivery. Identical in all three topologies. | Same node (acceptable: the node is alive by hypothesis) |
| F2 | Satellite node/k3s dies entirely | Nothing local survives — by construction. Detected by `capabilities/heartbeat/` (provider's missed-ping alarm) and/or destination-side absence detection (shipped hub rules keyed on the instance label; operator-configured elsewhere). With neither configured, node death is **silent**, and postflight must have said so in advance (O4/O5). | External (heartbeat provider / destination) |
| F3 | Network path satellite → destination fails; node healthy | Locally: a **new baseline rule on the satellite** alerting on sustained remote-write failure/lag (O3 made concrete; exact metric names confirmed live at implementation, per the repository's own confirmed-not-assumed discipline for `baseline-alerts.yaml`). Destination side: same absence signal as F2 — it cannot distinguish F2 from F3, and the design does not pretend it can. Delivery caveat: if the *same* network outage also breaks the local alert-delivery webhook path, local paging fails too — then heartbeat's withheld-push semantics are what fires. Stated, not solved recursively. | Same node (rule) + external (absence, heartbeat) |
| F4 | Remote destination itself fails | From the satellite: indistinguishable from F3, same local rule fires. The destination's own health is outside SCRAP's guarantee when it is not SCRAP; when it is a SCRAP hub, the hub is a standalone instance whose own O1–O5 apply to itself. | Same node + the destination's own operator |
| F5 | Alert delivery fails (receiver down/misconfigured) | Unchanged from today: `AlertmanagerConfig` status, `alertmanager_notifications_failed_total`, capability README's documented semantics; heartbeat covers the delivery plane being entirely dead. Topology adds nothing and takes nothing here. | Same node + external (heartbeat) |
| F6 | Remote-write outage ends | Prometheus WAL-buffers and retries; samples beyond the WAL/queue bound are lost **for the destination's history** (local rules never depended on them). The buffering bound is finite and stated, not implied infinite — exact behavior measured at implementation. | — |

No mode claims the monitoring system makes itself infallible. The guarantee boundary is: F1 is
SCRAP's alone; F2 requires a detector outside the node, which CORE cannot itself be — SCRAP ships
the layers (heartbeat, hub absence rules) and postflight reports which are armed.

## Bootstrap, preflight, postflight

- **Preflight (satellite):** destination URL configured, resolvable, and reachable (connection-level
  check) — fails loudly per `bootstrap/preflight/` discipline. A deliberately not-yet-up
  destination is a real scenario; the failure message says what was checked, and the operator can
  bring the destination up and re-run, same as any other preflight failure.
- **Postflight (satellite), added checks:** remote-write is genuinely delivering (nonzero
  sent/succeeded samples and a recent highest-sent timestamp from the local Prometheus — proven,
  not inferred from config existing); the local baseline rules are loaded and the telemetry-path
  rule (F3) exists; and a plain-language statement of the F2 posture, extending the existing
  "STATED PLAINLY, NOT HIDDEN" receiver report: which of heartbeat / hub-absence /
  operator-attested-external-absence / **nothing** will notice this node dying. "Nothing" is a
  legitimate, honestly-reported state, exactly like "no receiver configured" today.
- **Postflight (hub), added checks:** the receiver endpoint is enabled and serving; ingested
  satellite instances currently visible (informational); the satellite-staleness rules are loaded.
- **Standalone:** no change of any kind.

## Configuration model

Consistent with `docs/core/configuration-model.md` — scalars in `instance-config.yaml`, secrets
under `clusters/<name>/secrets/`, capability-style file presence for what is deployed, no
conditional logic, no new tooling:

- **Topology selection is an instance decision expressed only under `clusters/<name>/`.** The
  recommended mechanism is the one the repository already has for either/or deployment choices:
  which checked-in pointer/variant file the instance copies — the same "enabling is copying a
  file" semantics as capability selection, applied to a CORE mode. The satellite variant should be
  a **values-level delta of the same pinned chart** (retention, storage size, `remoteWrite`, and
  for hub the receiver flag), checked into `platform/` as a reviewed artifact — not a fork of the
  observability stack, and not an inline patch soup in cluster files. Exact file/directory naming
  is deliberately left to the implementation ticket (this record fixes the boundary, not the
  filenames), with one structural constraint: `platform/observability-config/` — the contract —
  stays a single, topology-invariant artifact consumed unchanged by all three modes. The existing
  `observability` / `observability-config` split already is the backend-vs-contract boundary this
  design needs; no new top-level structure is required.
- **New instance-config scalars (names illustrative, frozen at implementation):** the satellite
  destination URL; hub-side values only if implementation shows any are needed. Defaults preserve
  standalone; placeholders are harmless when the mode is unused, the same convention every existing
  optional key follows (`ACME_*`, `DYNDNS_*`, `UPS_NAME`).
- **Credentials:** the satellite's remote-write credential (basic-auth/bearer, whatever the
  destination requires) is credential material under `clusters/<name>/secrets/`, wired with the
  established two-file capability shape (`capabilities/heartbeat/README.md`'s pattern). A hub's
  ingestion credential likewise.
- **Instance identity:** satellite external labels reuse `INSTANCE_NAME`. No new identity concept.

Backwards compatibility: an existing install's `clusters/<name>/` contains no topology selection,
which **is** the standalone selection. Nothing to migrate, no behavior change, no new required
keys. CI's existing profiles keep proving standalone exactly as today.

## Security and trust

- **Shipping telemetry is disclosure.** Metric names, label values, and alert annotations reveal
  what runs on the instance. Choosing satellite mode against a third-party destination is choosing
  to disclose that to the destination — documentation states this plainly; SCRAP adds no
  minimization layer (0008: no concealment, no SCRAP-specific filtering abstraction).
- **Transport security:** off-LAN destinations require TLS. Trust anchoring for a SCRAP hub
  destination on the minimum path means trusting the hub's private CA from the satellite — a real
  cross-instance trust-distribution step (one more file in the satellite's secrets/config, exact
  mechanism at implementation) — or the hub enables `capabilities/public-tls/`. Nothing new is
  invented: it is the same trust distribution `platform/cert-manager-config/`'s exported CA
  already requires for client devices.
- **Hub ingestion is a write path, so it authenticates.** Forged or flooded remote-write can fake
  health, suppress attention, or exhaust the hub — integrity matters, not just confidentiality.
  Requirement fixed by this record: the hub's ingest endpoint is TLS-terminated and authenticated;
  an unauthenticated ingest endpoint reachable beyond the host is not an acceptable default in any
  documented configuration. The concrete mechanism (Gateway-level mTLS, an auth-terminating
  receiver front, or native web-config options of the pinned stack) is a genuinely open
  implementation question — candidates have materially different ergonomics and none is verified
  against the pinned chart yet — and is the hub ticket's first design task, not something this
  record freezes speculatively.
- **Credential loss:** the remote-write credential is replaceable, not fatal-if-lost; it joins no
  escrow list. `docs/core/recovery-model.md`'s fatal-if-lost set is unchanged.
- **Trust domain:** satellites and hub are assumed operator-owned, one administrative domain. This
  design makes no multi-tenant or hostile-satellite claims (see hub definition above).

## Recovery model, tiers, and capabilities

- **Recovery model unchanged.** Telemetry is operational data in every topology; no backup
  obligation, no new fatal-if-lost secret, R0–R2 semantics untouched. Incidental (unclaimed)
  benefit: a satellite's metric history survives its host's loss at the destination.
- **Tier/DAG unchanged.** Observability stays tier 2 in every mode; `platform/` still references
  nothing under `capabilities/`; hub-side satellite-staleness rules are CORE artifacts of the hub
  topology variant, inside `platform/`'s existing boundary. No new tier, no new dependency edge,
  existing `tests/assertions/` graph checks apply as-is.
- **Capabilities unchanged in code.** Grafana, logs, alert-delivery, heartbeat keep their exact
  manifests and dependency direction in all modes; the only deltas are documented guidance
  (dashboards belong at the destination in satellite mode) and heartbeat's elevated importance for
  the F2 posture. Satellite-side *log* forwarding (Alloy can ship Loki-bound logs remotely) is
  explicitly deferred — metrics-topology first; a log topology decision would be its own record.

## Technology choices

| Choice | Disposition |
|---|---|
| Prometheus remote-write (1.0 wire format) as the supported satellite transport | **Accepted** — native to the CORE stack, provider-neutral, wide receiver ecosystem |
| Local baseline-rule evaluation in every topology (server-mode Prometheus, short retention on satellites) | **Accepted** — the only shape that keeps O1 a SCRAP guarantee with zero destination assumptions |
| Standalone Prometheus + native remote-write receiver as the initial hub backend | **Accepted** — credible for small (home-scale) satellite counts; single-node durability equals the hub's own recovery posture; verified against the pinned chart at implementation |
| Prometheus agent mode / Alloy as the satellite's metrics core | **Rejected** — cannot evaluate rules; forces the alerting guarantee off-node into provider-specific territory. Revisit only on empirical small-node evidence |
| Mimir (or another scalable multi-tenant backend) | **Rejected for now, deliberately revisitable** — nothing at SCRAP's scale needs it; it would add object-storage and operational surface with no invariant it uniquely satisfies. Evidence that reopens it: satellite counts or retention needs a single Prometheus demonstrably cannot serve, or a real multi-tenancy requirement. If introduced, it slots in as a hub backend implementation behind the same remote-write contract — satellites would not change |
| SCRAP-provisioned rules in external backends (Mimir ruler API etc.) | **Deferred** — possible per-provider extension, never the base guarantee |
| OTLP (ingest or export) | **Deferred** — an extension point; adds no capability remote-write lacks for this design's scope today |
| Satellite log forwarding | **Deferred** — separate future decision |

## Implementation decomposition (proposed, not created — owner adjudicates)

Bounded tickets this design supports deriving, in dependency order:

1. **Satellite topology.** The `platform/` values variant + cluster-side selection artifacts;
   instance-config keys and secret shape; the remote-write-health baseline rule (metric names
   confirmed live); preflight/postflight additions; CI acceptance profile with an **ephemeral
   non-SCRAP remote-write receiver** (proving the destination-neutrality boundary directly), with
   negative controls at minimum: bad credential fails visibly; induced path outage genuinely fires
   the F3 rule; baseline alerting still delivers locally during the outage.
2. **Hub topology.** Receiver enablement on the standalone variant; the ingest
   exposure/authentication mechanism decision (the one open security question above) and its
   implementation; satellite-staleness rules keyed on the instance label (self-calibrating vs.
   configured-list decided with live evidence, honest limits stated either way); postflight
   additions; CI profile pairing a satellite with a hub, with a negative control proving absence
   detection genuinely fires when the satellite's shipping stops.
3. **Documentation pass.** `docs/core/configuration-model.md`, `docs/supported/hardware-tiers.md`
   (satellite row, honest resource statement), observability READMEs, `docs/choosing-capabilities.md`,
   `docs/release-readiness.md` rows for the new proof surfaces. (Landing docs alongside tickets 1–2
   rather than as a third ticket is an acceptable alternative decomposition.)
4. **Deferred (unscheduled, listed for traceability):** hub ingest hardening beyond the accepted
   mechanism, OTLP, satellite log forwarding, per-provider rule provisioning, Mimir evaluation
   trigger review.

Not resolved by this record and left to the owner: **whether satellite/hub belong to final v1's
claim set or land post-v1.** `docs/decisions/0012-rc-implementation-envelope.md` froze the RC
envelope's mandatory surfaces; this design deliberately does not add itself to any release's
requirements — that is an adjudication, not a producer decision.

## What remains unproven (validation needed before any support claim)

- The pinned kube-prometheus-stack version's support for the receiver flag and the exact values
  paths for the satellite delta (verify by rendering the pinned chart, the repository's
  established method).
- Remote-write health metric names/semantics for the F3 rule (confirm against a live endpoint,
  as `baseline-alerts.yaml` did for `kube_job_status_failed`).
- The satellite retention floor vs. rule lookback windows, and the actual disk/memory delta of the
  short-retention configuration (measure, don't estimate).
- WAL buffering bounds during a path outage (F6) — how long an outage is survivable without
  destination-history loss.
- The hub ingest authentication mechanism's feasibility within the existing ingress/Gateway
  architecture.
- Absence-rule behavior at the hub, both directions (fires on real staleness; silent on a healthy
  satellite), via the negative controls above.
- Whether the satellite set fits the small-node/ARM64 resource floor — empirical, owned by the
  ARM64 validation work, and no claim of this design.

## Consistent with

`0008-abstract-decisions-not-technologies.md` (the contract is remote-write and native Prometheus
Operator objects — no SCRAP abstraction, no concealment, no plugin surface);
`0009-repository-topology.md` (topology selection lives in `clusters/<name>/`, so it composes with
Topology B unchanged — a satellite operator repo pins upstream exactly as any other);
`0011`/`0012` (this design adds no RC-envelope surface and defers all support claims to CI
evidence); `0013-ups-shutdown-authority.md` and `0014-public-ingress-edge-authority.md` (the same
honest-boundary discipline for what CORE can and cannot detect from inside its own failure
domain); `docs/core/recovery-model.md` (guarantee boundaries stated per configuration, never
implied); `docs/core/configuration-model.md` (scalars + file presence + SOPS secrets, no new
mechanism).
