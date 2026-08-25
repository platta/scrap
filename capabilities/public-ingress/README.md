# capabilities/public-ingress/

**Architectural classification: FULLY SUPPORTED.** **Current implementation status: DESIGNED, NOT
YET IMPLEMENTED** — this directory contains only this README; no `Kustomization`, `HelmRelease`, or
other manifest exists yet, so there is nothing to enable. See `docs/release-readiness.md` for the
current, repository-wide proven/unproven/deferred snapshot.

Once built, this is intended to depend on `platform/ingress/` and to be strongly recommended
alongside `capabilities/public-tls/` (though not required by it — public trust and public exposure
are independent choices, see that directory's own README).

## Why this remains unimplemented — a real architecture gap, not an oversight

`docs/decisions/0012-rc-implementation-envelope.md` requires every mandatory-v1 capability, this one
included, to ship **real manifests** and a documented copy-in enabling mechanism before `rc.1` —
"never a README alone." Investigating this directly (PLAT-36) found that public ingress genuinely
doesn't fit that template the way every other capability so far has:

`platform/ingress/`'s `Gateway`/`Service` is already CORE — always present, identical whether or not
this capability is ever enabled. What actually determines whether the platform is reachable from the
internet is entirely **outside Kubernetes' control**: router port-forwarding (or a tunnel, for an
operator without router control) — the router/tunnel side has no Kubernetes object to represent it at
all. Unlike `capabilities/public-tls/`, which genuinely runs a mechanism in-cluster (cert-manager
speaking ACME) even though *proving* it needs a real domain, there is no in-cluster mechanism here
that "port-forwarding" could plausibly be a manifest **for** — SCRAP also ships no `NetworkPolicy`
enforcement layer at all (`docs/out-of-scope/README.md`), so a `NetworkPolicy` "restricting" ingress
would be structurally inert on this project's own default CNI, not a real control, and would misstate
what it does.

The one path that **would** produce a genuine, real, in-cluster manifest — a tunnel client for
operators behind CGNAT or without router control — requires picking a specific tunnel
software/protocol. Nothing in this repository's accepted architecture (any ADR, `docs/extensions/`,
`docs/supported/`) already licenses one, unlike `capabilities/dyndns/`'s and
`capabilities/public-tls/`'s shared RFC2136 choice, or UPS's already-named NUT. Picking one
unilaterally, for a security-sensitive inbound-exposure mechanism, is exactly the kind of material
provider/mechanism decision this project's own working agreement requires stopping for adjudication
on rather than deciding silently inside an implementation task — see PLAT-36's own Jira history for
the `QUESTION` this finding produced, and its resolution once recorded.

## The concrete runbook, once a mechanism is decided (port-forwarding path)

For the router-port-forwarding case specifically — the primary case, and the one requiring no new
architecture decision at all — enabling this is, and will remain, entirely operator-side
configuration rather than a Kubernetes manifest:

1. **Confirm `platform/ingress/reserved-ports.yaml` reflects everything you intend to expose.**
   `tests/assertions/check_reserved_ports.py` already enforces this on every pull request for
   anything landing in this repository, but the review is only meaningful if you actually read the
   file before forwarding a port at your router — it's the single place claimed host ports are
   declared, diffable in review, not a live surprise.
2. **Forward TCP 80 and 443** (or only 443, if you never need ACME HTTP-01 — SCRAP's own
   `capabilities/public-tls/` uses DNS-01 exclusively, so 80 is optional unless something else on
   your network needs it) from your router to the k3s node's own LAN address
   (`instance-config.yaml`'s `NODE_ADDRESS`). No SCRAP-side configuration changes this step at all —
   the same `Gateway`/`Service` already answers LAN traffic on those ports today.
3. **Split-horizon DNS**, so that internet clients and LAN clients resolving the same
   `*.${BASE_DOMAIN}` hostname reach the right address without depending on your router's NAT
   hairpin behavior working correctly (a real, previously undiagnosed dependency in the reference
   implementation): your LAN's own DNS server (not something this repository runs) should answer
   `*.${BASE_DOMAIN}` with `NODE_ADDRESS`; your **public** DNS zone (wherever
   `capabilities/public-tls/`'s DNS-01 solver lives, if enabled, or wherever the domain's
   authoritative records live otherwise) should answer with your public IP —
   `capabilities/dyndns/`, if your public IP changes, keeps that second answer current automatically.
4. **A materially larger threat model** — documented plainly, not minimized, this remains the
   capability with the most consequential new assumptions in the entire envelope. Review
   `docs/out-of-scope/README.md`'s own "no NetworkPolicy isolation" note before exposing anything:
   nothing in this platform limits what an internet-reachable Gateway can, structurally, reach inside
   the cluster.

## For an operator without router control (CGNAT, or a network you don't administer)

A tunnel client is the general answer — an outbound-only connection from inside your network to a
relay you (or the tunnel provider) control, terminating publicly and forwarding to the platform
Gateway's own `Service` — but *which* tunnel mechanism SCRAP ships, if any, is the open question
above. Until that's decided, this repository documents the **contract** an alternative must satisfy,
the same way `docs/extensions/README.md` already does for every other seam this project intentionally
doesn't pick a single implementation for: forward TCP 443 (and optionally 80) to the Gateway's own
`Service`, `traefik.traefik.svc.cluster.local`, without terminating TLS itself — the platform's own
wildcard certificate must still be what a browser actually sees. Any tunnel software satisfying that
contract works; SCRAP neither promises one works nor tests one, exactly `docs/extensions/README.md`'s
own "What extension is not" section already describes for every other undecided seam.

## Consistent with the project's own precedent

This isn't the first "designed, not yet implemented" capability in the ADR-0012 envelope to need its
own dedicated mechanism decision before implementation could honestly proceed: UPS's own
shutdown-authority question (its version of "which specific mechanism gets to act") was raised as a
separate, dedicated adjudication ticket (PLAT-41, blocking the UPS implementation ticket PLAT-37)
producing its own architecture-decision record, rather than an implementing agent deciding it inline
inside the implementation work. Public ingress's own exposure-mechanism question is recorded here for
the same reason, not as a stall — see `docs/decisions/README.md` for whichever ADR that ticket
ultimately produces, once merged.

## New assumptions this introduces

A public IP or a tunnel provider account; router control, or a tunnel; a materially larger threat
model than a LAN-only install, since the Gateway is now reachable by anyone. Documented plainly, not
minimized — this is the capability with the most consequential new assumptions in the entire
envelope.
