# 0013 — UPS shutdown authority lives on the host; the cluster gets visibility, never host power

**Decision:** the UPS capability's protective action — powering off the node when the UPS reports
low battery — is implemented as a **host-level NUT install** (`upsd` + `upsmon`, with `upsmon`'s
own `SHUTDOWNCMD` holding the shutdown authority), delivered by an operator-run script under
`bootstrap/host/` in exactly the shape `install-k3s.sh` already established: a one-shot script that
installs a persistent, distro-packaged systemd service. The **in-cluster half** of the capability —
UPS metrics into Prometheus and alert rules over them — remains an ordinary, unprivileged
capability, enabled by the normal Kustomization-copy mechanism, reading `upsd`'s own TCP protocol
(port 3493, a read-only NUT user) over the node's LAN address. Two corollaries are decided
explicitly at the same time, because this is the first capability that forced them into the open:

1. **No SCRAP-shipped workload ever holds host power authority.** No `privileged` container, no
   `hostPID`, no hostPath-mounted D-Bus/systemd socket, for this capability or any future one. The
   norm every implemented capability has held implicitly (`capabilities/logs/README.md` states it
   as a virtue) is now a recorded rule, revisable only by a future record here.
2. **The capability enablement rule gains its first recorded exception.** The one rule in
   `docs/core/configuration-model.md` — enabled by the presence of Flux `Kustomization` file(s),
   disabled by deleting them — remains the rule for everything that runs in the cluster, including
   this capability's visibility half. The host half is enabled by running its `bootstrap/host/`
   script and disabled by its documented uninstall path, because what it manages (a systemd unit
   with authority to power off the machine) does not exist inside anything Flux reconciles. This
   exception is licensed here, once, for host shutdown authority — it is not a precedent for
   routing around Flux when Flux-managed delivery is possible.

**Recorded 2026-08-25, resolving the architecture gap PLAT-37 stopped on (PLAT-41).** This gives
PLAT-37 a licensed mechanism to implement against. It designs no manifests and no scripts — per
ADR-0012, the specifics belong to the implementation work item.

## The question this resolves

`capabilities/ups/README.md` promises NUT integration for *graceful shutdown on power loss* — a
protective action against a real, previously-observed failure mode (unclean shutdown of a
single-node, single-disk host running local-disk databases). Every capability implemented so far
fits two constraints that a real shutdown mechanism cannot satisfy simultaneously:

- **Enablement**: everything is enabled by Kustomization-copy — purely in-cluster, Flux-reconciled.
- **Privilege**: no capability workload is privileged; every worst-case failure so far is "doesn't
  notify" or "doesn't retain data."

Host shutdown requires either a host daemon outside Flux's reach (breaking the first constraint) or
an in-cluster pod with host privileges (breaking the second). ADR-0012 requires UPS to be
implemented before `rc.1` and forbids silently weakening what its README promises, so the tension
had to be decided, not worked around. This record breaks the first constraint, deliberately and
narrowly, and makes the second one law.

## Why the host side is the right side

**Availability at the only moment that matters.** A shutdown mechanism is exercised precisely when
the environment is degrading — mains lost, battery sagging, possibly repeated brownouts. `upsmon`
under systemd depends on the kernel, the UPS data link, and nothing else. An in-cluster agent
depends on kubelet, the scheduler, a pulled image, a healthy container runtime, and Flux having
reconciled the right revision — an availability chain that is longest exactly when the power event
arrives. The one component that must not fail with the cluster is the one that saves the cluster's
data.

**Authority and blast radius.** This capability's worst-case failure is categorically different
from every predecessor's: a malfunctioning shutdown mechanism powers off a healthy host. Keeping
the authority on the host, in a distro-packaged daemon with a hand-editable configuration, keeps
the set of things that can trigger it small and auditable. Placing it in a pod would make the
entire GitOps pipeline part of the shutdown mechanism's attack and failure surface: anyone or
anything that can change what Flux reconciles could acquire host-root/host-power. Today a bad
commit's worst case is a broken reconciliation; that property is worth keeping.

**The USB reality.** The UPS data link is a host device. An in-cluster `upsd` would need
`/dev/bus/usb` host mounts and device privileges anyway — the privileged-pod option does not avoid
host coupling, it launders it through a pod spec while keeping all of the availability costs above.
(For a network-attached UPS the data link is TCP and `upsd` may even live elsewhere, but the
shutdown authority — `upsmon` and its `SHUTDOWNCMD` — stays on the host being protected either
way.)

**The ADR-0008 test.** NUT from distro packages, configured in `/etc/nut/`, debugged with NUT's own
tooling and documentation, is exactly the "understandable, standards-based" component that survives
SCRAP disappearing. This is also not a new pattern for this repository: `bootstrap/host/` already
installs SCRAP's most important persistent host daemon — k3s itself — via a one-shot script. NUT is
the second instance of that same shape, not a new mechanism.

**The clean-shutdown requirement, stated once.** The licensed `SHUTDOWNCMD` path is a *clean* host
shutdown (an orderly systemd poweroff), so stateful workloads get their normal termination path —
the entire point is that databases flush. Proving that termination actually reaches pods cleanly
(and how: k3s service shutdown behavior, kubelet shutdown handling) is PLAT-37's implementation and
evidence obligation, deliberately not designed here.

## What this means for ADR-0012's "implemented"

ADR-0012 defines implemented as "real manifests exist and the documented enabling mechanism
actually enables it — never a README alone." For this capability that reads, honestly, as two
halves with two documented enabling mechanisms, both shipped as real artifacts in the repository:

- **In-cluster half**: manifests, enabled by Kustomization-copy — identical to every other
  capability, and provable in CI the same way.
- **Host half**: a real script under `bootstrap/host/` whose documented invocation genuinely
  installs and arms the shutdown path. `docs/core/bootstrap-lifecycle.md` already documents
  per-capability operator-run bootstrap steps ("Additional steps introduced by supported
  capabilities"); this row joins that table.

The CI-provable envelope exists for both halves: NUT's own `dummy-ups` driver can simulate a
power-loss/low-battery sequence against a real installed `upsd`/`upsmon` with `SHUTDOWNCMD` pointed
at a sentinel, proving the trigger path genuinely fires — with the matching negative control (a
healthy simulated UPS must *not* fire it). The physical pull-the-plug test against real hardware is
an operator-run verification boundary, the same shape `capabilities/public-tls/verify-live.sh`
established for real-domain issuance. Test design beyond this boundary sketch belongs to PLAT-37.

## Rejected alternatives

- **Privileged in-cluster pod** (DaemonSet with `hostPID`/`privileged`, or a hostPath D-Bus socket
  into `systemd-logind`): rejected. It preserves the letter of the Kustomization-copy rule by
  breaking something more important — it grants host power to the reconciled cluster state, making
  a Git commit a potential host-root operation; its availability chain is longest exactly during
  power events; and it still needs host device access for USB, so it does not even deliver the
  isolation it appears to offer. Every implemented capability's README treats "no host privilege"
  as a feature; this record makes that a rule rather than breaking it for the one capability whose
  failure mode is the most destructive.
- **Scope the promise down to status/alerting only**: rejected. ADR-0012 explicitly forbids
  weakening a final-v1 requirement as an RC convenience, and this would be exactly that — the
  README's stated purpose is *corruption protection*, against a failure mode this project has
  actually observed. Alerting does not protect an unattended host: the shutdown must happen while
  nobody is watching, which is also why the mechanism's availability argument above dominates.
- **Rely on kubelet/k3s graceful-node-shutdown alone**: not an alternative — it addresses how pods
  terminate once a shutdown is underway, not what decides to shut down. Nothing triggers it on
  power loss without exactly the UPS integration this record licenses. (It may well be part of
  PLAT-37's clean-termination evidence; that is implementation, not architecture.)

## Consistent with

`0012-rc-implementation-envelope.md` (UPS remains mandatory pre-`rc.1`, its promise unweakened —
this record makes it implementable, not smaller); `0008-abstract-decisions-not-technologies.md`
(distro NUT, hand-editable config, no wrapper — the operator holds a standard tool);
`docs/core/configuration-model.md` (its one rule now carries one recorded, narrowly-scoped
exception, stated there and licensed here); `capabilities/README.md` (the tier rule is untouched;
the no-host-privilege corollary strengthens it); `docs/out-of-scope/README.md` ("general host
management beyond `bootstrap/`" stays out of scope — this lives *in* `bootstrap/`, the carve-out
that row itself names); `0009-repository-topology.md` (host scripts are upstream product surface,
identical in both topologies; nothing here is instance-specific content).
