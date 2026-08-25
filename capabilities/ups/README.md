# capabilities/ups/

**Architectural classification: FULLY SUPPORTED.** **Current implementation status: DESIGNED, NOT
YET IMPLEMENTED** — this directory contains only this README; no `Kustomization`, `HelmRelease`, or
other manifest exists yet, so there is nothing to enable. See `docs/release-readiness.md` for the
current, repository-wide proven/unproven/deferred snapshot.

Once built, this is intended to have no dependency on other capabilities, and to provide NUT
(Network UPS Tools) integration for graceful shutdown on power loss — real corruption protection
for stateful applications with local-disk databases, which is most of what SCRAP hosts. An unclean
shutdown is a realistic and previously-observed failure mode for a single-node, single-disk
install.

**The mechanism is now decided** — `docs/decisions/0013-ups-shutdown-authority.md` (2026-08-25):
shutdown authority is a host-level NUT install (`upsd` + `upsmon`, `SHUTDOWNCMD`) delivered by an
operator-run `bootstrap/host/` script in the `install-k3s.sh` pattern; the in-cluster half of this
capability is unprivileged visibility/alerting only (a read-only NUT client over TCP), enabled by
the normal Kustomization-copy mechanism. No SCRAP workload holds host power authority.
Implementation remains open (PLAT-37).

## New assumptions this introduces

A UPS with a data connection to the host (USB or network). No cloud dependency.
