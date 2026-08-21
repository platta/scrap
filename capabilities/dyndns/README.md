# capabilities/dyndns/

**Architectural classification: FULLY SUPPORTED.** **Current implementation status: DESIGNED, NOT
YET IMPLEMENTED** — this directory contains only this README; no `Kustomization`, `HelmRelease`, or
other manifest exists yet, so there is nothing to enable. See `docs/release-readiness.md` for the
current, repository-wide proven/unproven/deferred snapshot.

Once built, this is intended to have no dependency on other capabilities, and to be relevant
alongside `capabilities/public-tls/` and `capabilities/public-ingress/` when the host's public IP
is not static: a generic dynamic-DNS updater contract, backed by any provider with an API, not one
specific vendor. Purely outbound — keeps a DNS record pointed at the current public IP.

## New assumptions this introduces

A dynamic-DNS-capable domain/provider and internet access. No inbound exposure by itself.
