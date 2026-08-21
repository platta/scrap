# capabilities/public-ingress/

**Architectural classification: FULLY SUPPORTED.** **Current implementation status: DESIGNED, NOT
YET IMPLEMENTED** — this directory contains only this README; no `Kustomization`, `HelmRelease`, or
other manifest exists yet, so there is nothing to enable. See `docs/release-readiness.md` for the
current, repository-wide proven/unproven/deferred snapshot.

Once built, this is intended to depend on `platform/ingress/` and to be strongly recommended
alongside `capabilities/public-tls/` (though not required by it — public trust and public exposure
are independent choices, see that directory's own README). The design: make the platform Gateway
reachable from the public internet via router port-forwarding, or a tunnel provider for users
behind CGNAT or without router control, with split-horizon DNS guidance so that LAN clients and
internet clients resolving the same hostname don't depend on router NAT hairpin behavior working
correctly — a real, previously undiagnosed dependency in the reference implementation.

## New assumptions this introduces

A public IP or a tunnel provider account; router control, or a tunnel; a materially larger threat
model than a LAN-only install, since the Gateway is now reachable by anyone. Documented plainly, not
minimized — this is the capability with the most consequential new assumptions in the entire
envelope.
