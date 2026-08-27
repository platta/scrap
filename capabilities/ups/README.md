# capabilities/ups/

**Architectural classification: FULLY SUPPORTED. Current implementation status: IMPLEMENTED,
LIVE-TESTED** — see `docs/release-readiness.md` and `tests/profiles/t-a-ups.sh`'s own
`T-A-ups/*` checks. This capability has **two halves with two different enabling mechanisms** —
see "Enabling this capability" below — decided explicitly in
`docs/decisions/0013-ups-shutdown-authority.md` after PLAT-37 first stopped on the architecture
gap a real shutdown mechanism creates for every other capability's own assumptions.

No dependency on other capabilities. Provides NUT (Network UPS Tools) integration for graceful
shutdown on power loss — real corruption protection for stateful applications with local-disk
databases, which is most of what SCRAP hosts. An unclean shutdown is a realistic and
previously-observed failure mode for a single-node, single-disk install.

## The real mechanism — two halves, deliberately asymmetric

**Host half (the actual shutdown authority):** a persistent, distro-packaged NUT install —
`upsd` (serves UPS status) and `upsmon` (decides when to shut down and holds `SHUTDOWNCMD`
authority) — delivered by `bootstrap/host/install-nut.sh`, the same one-shot-script-installing-
a-persistent-systemd-service shape `install-k3s.sh` already established. `upsmon`'s own
`SHUTDOWNCMD` runs a real, orderly `shutdown -h` on sustained on-battery + low-battery.

**That termination window is not automatic — `install-k3s.sh` arms it explicitly.** A real
finding from an independent review of this capability's own first implementation: kubelet's
Graceful Node Shutdown feature has had its feature gate on by default since Kubernetes v1.21,
but the feature does nothing until `shutdownGracePeriod`/`shutdownGracePeriodCriticalPods` are
set to non-zero values — both default to `0`, which
[upstream Kubernetes documentation](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/)
states plainly does not activate it. Both fields are `KubeletConfiguration` fields, not CLI
flags, on this project's pinned k3s version — a real finding, live: the deprecated CLI-flag form
the same upstream documentation still shows (`--shutdown-grace-period=...`) has been removed
outright on this kubelet, not merely deprecated, and crash-loops kubelet if passed
(`Error: failed to parse kubelet flag: unknown flag: --shutdown-grace-period`).
`bootstrap/host/install-k3s.sh` instead writes a real `KubeletConfiguration` file
(`/etc/rancher/k3s/scrap-kubelet-shutdown-config.yaml`, `shutdownGracePeriod: 30s` /
`shutdownGracePeriodCriticalPods: 10s` — the exact worked example from that same documentation)
and points kubelet at it via `--kubelet-arg=config=<path>` (kubelet's own long-stable `--config`
flag), and raises systemd-logind's `InhibitDelayMaxSec` to `45` so that window isn't silently
truncated by whatever a given distribution's own default happens to be. This is a property of the
k3s host itself, not of this capability specifically — it protects any operator-initiated
`shutdown -h` on this single-node stack, not only a UPS-triggered one — but
`bootstrap/host/install-nut.sh`'s `SHUTDOWNCMD` is what makes it matter unattended.

**In-cluster half (visibility/alerting only):** `scrap-ups-exporter`, a small, self-contained
Prometheus exporter (`exporter-deployment.yaml`) that connects to `upsd` over the node's LAN
address (`${NODE_ADDRESS}:3493`, `instance-config.yaml`) and reads its status via a **read-only
NUT user** — a `upsd.users` account with a password and no `upsmon`/`instcmds`/`actions` grant,
so it can never receive an FSD broadcast, `SET VAR`, or `INSTCMD` anything, regardless of what it
authenticates as. **Real limit, found live (`tests/profiles/t-a-ups.sh`'s own first negative
control, redesigned after evidence, not assumption — see "Configuration errors fail visibly"
below): upsd does not actually validate this user's password for `LIST VAR` read access at all** —
only privileged operations enforce it. The account still documents and scopes *intent* (this is
the identity the read-only client authenticates as, auditable in `upsd`'s own logs), and the
privilege grants above are real and enforced; password secrecy for this specific user is not a
real access-control boundary against another host already able to reach port 3493 on the LAN.
`servicemonitor.yaml` and `prometheusrule.yaml` wire the exporter's metrics into Prometheus and
Alertmanager the normal way (`UPSOnBattery`, `UPSLowBattery`, `UPSReplaceBattery`, and
`UPSCommunicationLost` if the exporter itself loses contact with `upsd`).

**No SCRAP-shipped workload ever holds host power authority** — `docs/decisions/0013`'s own
corollary, enforced structurally here, not just documented: the exporter pod is an ordinary
unprivileged container — no `privileged`, no `hostPID`, no host mount, `allowPrivilegeEscalation:
false`, every Linux capability dropped, no `ServiceAccount` token — and its NUT credential cannot
trigger a shutdown even if the pod were fully compromised. It does run as root *inside* that one
ordinary container, needed to install `python3` at start the same way every other apk-based
capability here does (`capabilities/dyndns/cronjob.yaml`, `capabilities/heartbeat/cronjob.yaml`) —
root-in-a-container is not the host-power-authority privilege ADR-0013 forbids; a privileged
container, `hostPID`, or a host mount would be, and this has none of them. Only `upsmon`, running
on the host itself outside anything Flux reconciles, can decide to power the node off.

## Why no third-party exporter image

The NUT network protocol (`USERNAME`/`PASSWORD`/`LIST VAR ... END LIST VAR`) is a handful of
plain-text lines, stable for decades — small enough to implement directly in stdlib Python
(`exporter-deployment.yaml`'s own embedded script) with nothing else to audit, pin, or trust.
This is the same "install what's needed at container start, from an official base image"
pattern `capabilities/dyndns/cronjob.yaml` already establishes for a CronJob; applied here to a
`Deployment`, since Prometheus needs something to scrape continuously, not something that runs
on a schedule.

## Enabling this capability

**The two halves are enabled independently. Enabling the in-cluster half without the host half is
meaningful** (a dashboard/alert surface with `UPSCommunicationLost` permanently firing until the
host half exists) **but the host half is what actually protects data — enable both for a real
install.**

### Host half — an operator-run script, not a file copy

Decided in `docs/decisions/0013-ups-shutdown-authority.md`: what this manages (a systemd unit
with authority to power off the machine) exists outside anything Flux reconciles, so it cannot be
toggled by copying a `Kustomization` the way every other capability is — the second capability
(after `public-ingress/`'s own operator-edge procedure) to carry a recorded exception to
`docs/core/configuration-model.md`'s one rule.

1. Connect your UPS to the host (USB or network — a data connection, not just power).
2. Run `bootstrap/host/install-nut.sh` on the host, with (at minimum) `NUT_UPS_NAME`,
   `NUT_DRIVER` (see [NUT's own hardware compatibility list](https://networkupstools.org/stable-hcl.html)
   for which driver your model needs — `usbhid-ups` covers the overwhelming majority of USB
   UPSes), `NUT_PORT` (usually `auto` for `usbhid-ups`), and `NUT_READONLY_PASSWORD` (must match
   the in-cluster half's own credential — see below). See that script's own header comment for
   every variable, including `NUT_SHUTDOWNCMD` (defaults to a real poweroff).
3. Disable with `bootstrap/host/uninstall-nut.sh`.

### In-cluster half — the normal two-file copy

Same shape as `capabilities/heartbeat/`'s and `capabilities/alert-delivery/`'s: the credential
(the read-only NUT user's password) lives under `clusters/<name>/secrets/`, never under
`capabilities/`. Copy **both** into `clusters/<name>/capabilities/`:

- `cluster-kustomization.yaml` → rename to `ups.yaml`. Installs `scrap-ups-exporter` (the
  `Deployment` + `Service`), the `ServiceMonitor`, and the `PrometheusRule`.
- `cluster-secrets-kustomization.yaml` → rename to `ups-secrets.yaml`. Installs
  `clusters/<name>/secrets/ups/` — the `ups-credentials` `Secret` (`NUT_USERNAME`/
  `NUT_PASSWORD`) into the existing `monitoring` namespace.

Then set `UPS_NAME` in `instance-config.yaml` to match `NUT_UPS_NAME` above (the exporter queries
this exact name), and replace the placeholder values in
`ups-credentials.sops.yaml` with the same username/password the host half's
`NUT_READONLY_USER`/`NUT_READONLY_PASSWORD` used (`cd clusters/<name>/secrets/ups && sops
ups-credentials.sops.yaml` — see `clusters/example/secrets/README.md` for the general
re-encrypt-on-save pattern).

**Dependency direction:** `ups` `dependsOn` `ups-secrets` — the exporter is a `Deployment` that
starts immediately on apply, the same reasoning `capabilities/identity/README.md`'s own
"Enabling this capability" section gives for its own direction (the opposite of
`capabilities/heartbeat/`'s CronJob, whose `secretKeyRef` is only resolved when a Job starts).

## Configuration errors fail visibly — verified, not assumed

A wrong `NUT_USERNAME`, a wrong `UPS_NAME`, or an unreachable `upsd` all fail the same way: the
exporter's own `query_nut()` raises, `nut_up` reports `0`, and `UPSCommunicationLost` fires after
5 minutes — never a silent zero-value metric indistinguishable from "everything is fine, on
mains, 100% charged." There is no SCRAP-authored fallback or retry-and-ignore logic in this path.

**Real finding, not assumed — a wrong `NUT_PASSWORD` alone does *not* fail this way.**
`tests/profiles/t-a-ups.sh`'s own first design asserted it would; direct evidence across two full
live CI runs (a deliberately wrong password held for minutes, multiple Prometheus scrape
intervals, and the exporter's own `scrape failed: ...` stderr diagnostic — which fires on any
protocol rejection — never once printed) showed `upsd` accepts `USERNAME`/`PASSWORD` for a plain
user's `LIST VAR` access without actually validating the password. The negative control this
project actually ships instead breaks `NUT_UPS_NAME`, a failure `upsd` genuinely does enforce
(`ERR UNKNOWN-UPS`). See "Enabling this capability" above for what a wrong `NUT_PASSWORD`
therefore does and doesn't buy.

## Acceptance evidence

Three distinct evidence levels, kept honestly separate:

**1. Static/structural — every push and PR, no external dependency:** the `Deployment`,
`Service`, `ServiceMonitor`, and `PrometheusRule` render, are owned by this capability's own
Kustomization (T1: absent from a `minimal`-profile cluster), and the exporter pod's own
security posture (no privilege escalation, every Linux capability dropped, no service account
token) is asserted structurally, not merely claimed in prose.

**2. A real host-level NUT install, driven by NUT's own `dummy-ups` driver, against a real
exporter reading real (simulated) UPS data — every push and PR, no physical hardware
(`tests/profiles/t-a-ups.sh`):** `bootstrap/host/install-nut.sh` runs for real on the CI runner
itself, installing and starting genuine `upsd`/`upsmon` systemd services against NUT's own
`dummy-ups` driver (a real NUT driver, shipped by the same `nut` package as every real driver —
not a SCRAP-authored stand-in for NUT). The in-cluster exporter, enabled the documented way
against an already-bootstrapped cluster, is confirmed to read real values through Prometheus's
own query API — not just that the objects exist. Both directions are proven:

- **Positive:** with the simulated UPS reporting healthy (`OL`, on line), the exporter's
  `nut_up` and `nut_ups_status_flag{flag="OL"}` genuinely read `1` through Prometheus, sourced
  from the real dummy-ups driver, not asserted from the manifest alone.
- **The actual protective mechanism, proven live:** the dummy-ups driver's own live-editable
  `.dev` file is rewritten to report `OB LB` (on battery, low battery) — a real, live-induced
  device state, not a mocked signal — and `upsmon`'s own `SHUTDOWNCMD`, pointed at a sentinel
  file (never a real `shutdown`, which would kill the CI runner itself — see
  `tests/profiles/t-a-ups.sh`'s own comment), is confirmed to fire for real.
- **Negative control:** the sentinel file is confirmed **absent** both before the on-battery
  event and immediately after the dummy-ups driver starts healthy — the trigger path is proven
  to fire only on the real degraded condition, not unconditionally.
- **`UPSCommunicationLost`, proven both ways:** the alert is confirmed silent while the exporter
  can reach `upsd`, and confirmed to fire when it deliberately cannot (the exporter's own
  `NUT_UPS_NAME` pointed at a UPS `upsd` never configured — a real, visible `LIST VAR` failure,
  not a mock; see "Configuration errors fail visibly" above for why this is the negative control
  actually used, not a wrong password).

**3. The termination window itself is genuinely armed, live, on the exact host under test — every
push and PR (`tests/profiles/t-a-ups.sh`'s own `T-A-ups/kubelet-*` and
`T-A-ups/logind-inhibit-delay-raised` checks):** `bootstrap/host/install-k3s.sh` installs k3s
with kubelet's Graceful Node Shutdown explicitly configured (see "The real mechanism" above) and
a matching `systemd-logind` `InhibitDelayMaxSec` override. This is checked live, not re-asserted
from the installer's own script text: the real installed `k3s.service` unit genuinely points
kubelet at the real `KubeletConfiguration` file on disk (which genuinely carries both fields),
`systemd-logind`'s own running D-Bus property genuinely reflects the raised `InhibitDelayMaxUSec`,
and — the central proof — a real `systemd-logind` "shutdown"/"delay"
inhibitor lock is genuinely held, which only exists while kubelet's node-shutdown manager is
actually running with a non-zero grace period. Before this fix, no such lock existed on any host
this project bootstrapped; the node still reported `Ready`, silently masking the gap.

**Honest limits — two distinct boundaries, kept honestly separate:**

- NUT's `dummy-ups` driver simulates the *device's own reported state* faithfully (the same code
  path a real driver's readings flow through), but a *real* UPS's physical behavior under an
  actual mains outage — battery chemistry, runtime estimation accuracy, USB/serial link
  reliability — is not something CI can own hardware for and never will be. The **physical
  pull-the-plug test against real hardware is an operator-run verification boundary**, the same
  evidentiary shape `capabilities/public-tls/verify-live.sh` establishes for real-domain
  certificate issuance: after completing "Enabling this capability" above with your own real UPS,
  pull the plug (or use your UPS's own test-discharge feature) and confirm the host shuts down
  cleanly.
- Level 3 above proves the mechanism that gives workloads a termination window is genuinely armed
  on this host, but proving it live end-to-end — that a real shutdown transaction actually pauses
  for a representative stateful pod's own SIGTERM/`preStop`/exit before the node powers off — is
  **also an operator-run verification boundary**, for a different reason than the hardware one
  above: a GitHub-hosted CI runner's own job-completion protocol assumes the runner survives to
  report a result, and deliberately shutting one down mid-job cannot be turned into a repeatable,
  interpretable green/red signal, while `systemd`'s own shutdown negotiation offers no supported
  way to exercise the real `PrepareForShutdown`-triggered eviction path without following through
  on an actual poweroff. On your own scratch VM or real host, after enabling both halves, watch
  `kubectl get events -w` (or a representative stateful pod's own logs) from a second machine
  while triggering a real shutdown (the UPS's own test-discharge feature, or `sudo shutdown -h
  +0` directly) to confirm your workloads actually receive their configured termination window.

Nothing in this repository can fabricate either boundary's evidence in CI, and nothing here
claims to.

## New assumptions this introduces

A UPS with a data connection to the host (USB or network). No cloud dependency. The host half
adds one persistent host daemon (`nut-server` + `nut-monitor`, negligible resource cost); the
in-cluster half adds one lightweight `Deployment` (no persistent workload beyond the one pod,
~32Mi requested).
