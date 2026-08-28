# capabilities/public-ingress/

**Architectural classification: FULLY SUPPORTED. Current implementation status: IMPLEMENTED,
LIVE-TESTED** (live public reachability of a real install is operator-verified, not CI — see
`verify-live.sh` below) — see `docs/release-readiness.md`. Depends on `platform/ingress/` only, and
is strongly recommended alongside `capabilities/public-tls/` (though not required by it — public
trust and public exposure are independent choices, see that directory's own README).

## Why this capability ships no manifest at all

`platform/ingress/`'s `Gateway`/`Service` is already CORE — always present, identical whether or
not this capability is ever enabled. What actually determines whether the platform is reachable
from the internet is entirely outside Kubernetes' control: your router's own NAT table. There is no
Kubernetes object that represents that decision, and inventing one to satisfy the letter of "ship a
manifest" would misrepresent what it does — SCRAP ships no `NetworkPolicy` enforcement layer at all
(`docs/out-of-scope/README.md`), so a `NetworkPolicy` "restricting" exposure would be structurally
inert on this project's default CNI, not a real control.

`docs/decisions/0014-public-ingress-edge-authority.md` decides this explicitly: this capability's
real, implemented artifacts are the runbook below and `verify-live.sh`, not a `Kustomization` —
the second capability (after `capabilities/ups/`'s host half,
`docs/decisions/0013-ups-shutdown-authority.md`) to carry a recorded exception to the normal
copy-a-Kustomization-in enablement rule (`docs/core/configuration-model.md`). **Enabling this
capability is performing the three steps below; disabling it is removing the router forwards.**
Nothing in the cluster changes in either direction, and `verify-live.sh` is re-runnable at any time.

## Enabling this capability — a runbook, not a file copy

1. **Confirm `platform/ingress/reserved-ports.yaml` reflects everything you intend to expose.**
   `tests/assertions/check_reserved_ports.py` already enforces this on every pull request for
   anything landing in this repository, but the review is only meaningful if you actually read the
   file before forwarding a port at your router — it's the single place claimed host ports are
   declared, diffable in review, not a live surprise.
2. **Forward TCP 443 (and optionally 80)** from your router to the k3s node's own LAN address
   (`instance-config.yaml`'s `NODE_ADDRESS`). Port 80 is only needed if something on your network
   requires it — SCRAP's own `capabilities/public-tls/` uses ACME DNS-01 exclusively, never
   HTTP-01. No SCRAP-side configuration changes for this step at all — the same `Gateway`/`Service`
   already answers LAN traffic on these ports today; port-forwarding it does not touch the
   platform.
3. **Split-horizon DNS**, so that internet clients and LAN clients resolving the same
   `*.${BASE_DOMAIN}` hostname reach the right address without depending on your router's NAT
   hairpin behavior working correctly (a real, previously undiagnosed dependency in the reference
   implementation): your LAN's own DNS server (not something this repository runs) should answer
   `*.${BASE_DOMAIN}` with `NODE_ADDRESS`; your **public** DNS zone (wherever
   `capabilities/public-tls/`'s DNS-01 solver lives, if enabled, or wherever the domain's
   authoritative records live otherwise) should answer with your current public IP —
   `capabilities/dyndns/` keeps that second answer current automatically if your public IP
   changes; a static-IP install needs no dyndns at all.

**A materially larger threat model** — stated plainly, not minimized, before the step that creates
it: this remains the capability with the most consequential new assumptions in the entire envelope.
SCRAP provides no in-cluster segmentation (`docs/out-of-scope/README.md`) — an internet-reachable
Gateway can reach whatever the application contract routes. Nothing about exposure changes TLS
issuers, certificate shape (`docs/decisions/0006-tls-wildcard-and-issuer-independence.md`), or
which routes require forward-auth/OIDC — only reachability changes.

## Acceptance evidence

Two distinct evidence levels, kept honestly separate — CI owns no router and this repository
controls no public edge, so CI cannot prove *an exposure*, but it can and must prove the tool an
operator relies on to check one:

**1. Static/structural — every push and PR, no external dependency:** the reserved-ports
allowlist and its CI enforcement (`tests/assertions/check_reserved_ports.py`) — already exists,
unconditional, and applies to this capability's own application contract exactly as it does to
every raw-port pattern.

**2. `verify-live.sh`'s own oracle proven live, against the from-zero-bootstrapped cluster's real
Gateway — every push and PR, no router or public domain required
(`tests/profiles/t-a-public-ingress.sh`):** this script's decisive check — reading the certificate
actually served at a target and comparing its SHA-256 fingerprint, byte-for-byte, against the real
`Secret` cert-manager wrote for the platform's own wildcard certificate — is proven both ways: PASS
when pointed at the platform's own genuinely-serving Gateway, and FAIL when pointed at a
deliberately different, unrelated TLS endpoint. A verifier that had never been shown to turn red
would be aspirational prose with a shebang, not a proof.

**3. Live public reachability of a real install — operator-run, not CI-executed
(`capabilities/public-ingress/verify-live.sh`):** the one claim that genuinely cannot be tested
without external infrastructure this project doesn't control and never will — a real router, a
real public IP, real public DNS. Run it yourself after completing the runbook above; see that
script's own header for exactly what it does and does not prove, including why an unreachable
result from inside your own LAN is expected (NAT hairpin), not a failure, and what an off-network
vantage buys you that this script alone cannot.

## New assumptions this introduces

A public IP (static, or kept current by `capabilities/dyndns/`); router control; a materially
larger threat model than a LAN-only install, since the Gateway is now reachable by anyone.
Documented plainly, not minimized — see "Enabling this capability" above.

## CGNAT and no-router-control environments — not supported in v1

`docs/decisions/0014-public-ingress-edge-authority.md` decides this boundary explicitly, in the
open, rather than leaving it implied: the general answer for an operator who cannot forward a
router port is a tunnel — an outbound connection from inside your network to a public relay,
forwarding inbound traffic to the platform Gateway — but shipping one in v1 was rejected. Every
concrete choice is either a specific commercial provider (a third party inside the inbound trust
path, a materially different security posture than dyndns/public-tls's own vendor-neutral RFC2136
choice) or a self-hosted relay (presupposing a second public host most of this capability's
population doesn't have); no vendor-neutral standard exists to pick the way RFC2136 was chosen for
DNS updates.

What v1 offers this population instead is the same seam `docs/extensions/README.md` already
documents for every other place this project intentionally doesn't pick a single implementation:
any mechanism that delivers TCP 443 (and optionally 80) to the platform Gateway's own Service,
`traefik.traefik.svc.cluster.local`, **without terminating TLS itself** — the platform's own
wildcard certificate must still be what a client sees — satisfies the platform's side of the
contract. SCRAP neither promises a specific tunnel works nor tests one. A supported tunnel
capability may be added post-v1, only by its own recorded decision.
