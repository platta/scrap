# 0014 — Public ingress is edge configuration: the exposure decision lives at the operator's router, never in a manifest

**Decision:** SCRAP v1's supported public-ingress mechanism is **router/NAT port-forwarding** of
TCP 443 (and optionally 80) from the operator's public address to the node's own LAN address
(`NODE_ADDRESS`), together with the split-horizon DNS arrangement the capability's design already
names. The capability is **operator/edge configuration end to end**: nothing in the cluster differs
between an exposed and an unexposed install — `platform/ingress/`'s Gateway answers identically
either way — so the capability's implemented form deliberately ships **no Kubernetes manifest at
all**. What makes it genuinely implemented, rather than a README placeholder, is executable and
testable product surface of a different shape:

1. **A complete, concrete enablement procedure** in `capabilities/public-ingress/`: the
   reserved-ports review (`platform/ingress/reserved-ports.yaml`, already CI-enforced on every pull
   request), the exact forwarding rules, and the split-horizon DNS contract — written as a runbook
   an operator executes today, not design prose about a future mechanism.
2. **An operator-run verification script**, in the shape `capabilities/public-tls/verify-live.sh`
   established: executable, deterministic where determinism is possible (the Gateway genuinely
   listening on `NODE_ADDRESS`'s forwarded ports; public DNS genuinely answering with the current
   public address; and, when the public address is reachable, the served certificate being *this
   platform's own* wildcard certificate — proof that the thing answering publicly is this cluster's
   Gateway, not merely that "something answered") — and honest where it is not: from inside the
   LAN, reaching your own public IP depends on NAT hairpin, the exact dependency split-horizon DNS
   exists to avoid, so conclusive end-to-end confirmation is documented as requiring an off-network
   vantage.
3. **CI proof that the verification oracle is sound.** CI owns no router and this repository
   controls no public edge, so CI cannot prove *an exposure* — but it can and must prove the tool
   the operator relies on: green against the platform's genuinely-served wildcard certificate, red
   under a deliberate violation. A shipped verifier that has never been shown to turn red would be
   aspirational prose with a shebang.

Two corollaries are decided explicitly at the same time, because this is the first capability that
forced them into the open:

1. **No inert manifest, ever.** No SCRAP-shipped object may claim an enforcement it does not
   perform on the default platform. The concrete case: SCRAP ships no NetworkPolicy enforcement
   layer (`docs/out-of-scope/README.md`), so a NetworkPolicy "restricting" public exposure would be
   structurally inert on the default CNI — shipping one to satisfy ADR-0012's letter would be a
   misrepresentation of exactly the class `tests/assertions/check_capability_status_honesty.py`
   exists to catch, not an implementation. This generalizes: an artifact's existence never counts
   toward ADR-0012 unless the artifact genuinely does what it claims where SCRAP ships it.
2. **The capability-enablement rule gains its second recorded exception.** The rule in
   `docs/core/configuration-model.md` — enabled by the presence of Flux `Kustomization` file(s),
   disabled by deleting them — remains the rule for everything that runs in the cluster. Public
   ingress is **enabled by performing its documented edge procedure** (reserved-ports review, then
   the router forwards, then split-horizon DNS) **and disabled by removing the forwards**; the
   platform requires no reconfiguration in either direction, and verification is re-runnable at any
   time. This exception is licensed here, once, for network-edge exposure — what it manages (the
   operator's router NAT table) exists outside anything Flux reconciles, and outside the host
   itself. It is not a precedent for routing around Flux when Flux-managed delivery is possible.

**Recorded 2026-08-25, resolving the architecture gap PLAT-36 stopped on (PLAT-61).** This gives
PLAT-36 a licensed mechanism to implement against. Per ADR-0012, it designs no runbook text, no
script internals, and no test profile — the specifics belong to the implementation work item.

## The question this resolves

ADR-0012 requires public ingress — a mandatory-v1 capability — to be implemented before `rc.1`,
and defines implemented by established practice: "real manifests exist and the documented enabling
mechanism actually enables it — never a README alone." Investigating the implementation directly
(PLAT-36) found that public ingress cannot honestly take that shape: the in-cluster half of public
reachability already exists as CORE (`platform/ingress/`'s Gateway and Service), and the half that
actually decides reachability — edge NAT — has no Kubernetes object to represent it. The only path
to a genuine in-cluster manifest, a tunnel client, requires choosing a specific tunnel
software/protocol that no accepted architecture licenses. The producing agent stopped rather than
inventing a manifest or picking a tunnel inline; this record makes the decision it stopped for.

## Why the edge is the right control point

**It is where the capability actually is.** Whether the platform is reachable from the internet is
decided by the operator's router, and nowhere else. Representing that decision as a Kubernetes
object would be exactly the concealment ADR-0008 forbids: a SCRAP-specific artifact standing
between the operator and the real mechanism, obscuring rather than expressing where the control
lives.

**A Git commit cannot expose the platform.** Because the exposure decision is out-of-band, nothing
that flows through Flux — no commit, no reconciliation, no compromised manifest — can make a
private install publicly reachable. This is the same property ADR-0013 preserved for host power
("a bad commit's worst case is a broken reconciliation"), now stated for network exposure: the
GitOps pipeline is not part of the exposure decision's attack surface. A tunnel workload, had one
been invented to satisfy ADR-0012's letter, would have destroyed exactly this property — enabling
it *would* be a commit that exposes the platform.

**The ADR-0008 test.** Router port-forwarding, `dig`, and a TLS handshake inspected with standard
tooling are exactly the "understandable, standards-based" pieces that survive SCRAP disappearing.
The operator's own router UI, their own DNS, their own eyes on the served certificate — no wrapper,
no SCRAP control plane.

**Established practice already includes this shape.** `capabilities/offsite-backup/` is accepted,
implemented, and live-tested while shipping no manifest of its own (the wiring lives in
`platform/backup/`); ADR-0013's host half is enabled by a script, not a Kustomization. "Implemented"
has never actually meant "manifests in this directory" — it means the capability's real artifacts
exist and its documented enabling mechanism genuinely enables it.

## What this means for ADR-0012's "implemented"

ADR-0012's substantive rule is existence before candidacy: nothing mandatory for v1 may still
require implementation work when `rc.1` is cut. For public ingress that reads: the runbook, the
verification script, and the CI proof of that script's oracle must all exist and be green before
`rc.1`. After they land, nothing further needs building — an operator holding the repository can
genuinely enable, verify, and disable public exposure.

The evidence boundary follows the discipline the accepted capabilities already established, split
honestly into its two classes:

- **CI-provable, every push/PR:** the reserved-ports structural assertion (already exists), and the
  verification script's own oracle proven live — green against the platform's genuinely-served
  wildcard certificate, red under a deliberate violation (a wrong certificate or wrong endpoint).
- **Operator-run, permanently:** live public reachability of a real install from an off-network
  vantage. CI will never own a router or a public edge; this is a permanent evidence boundary of
  the same class as real-domain certificate issuance
  (`capabilities/public-tls/verify-live.sh`, `docs/release-readiness.md`'s "by design, not a gap to
  close" row), not a temporary gap. Status language must use the same honest form the accepted
  capabilities use: implemented and live-tested, with the operator-verified boundary named in the
  same breath.

ADR-0012 itself is not amended. Its "real manifests" sentence describes what implemented "has meant
for every capability accepted so far" — and accepted practice, per the offsite-backup and ADR-0013
precedents above, already includes capabilities whose real artifacts are not manifests. This record
instantiates ADR-0012 for an operator/edge capability the same way ADR-0013 instantiated it for a
host-daemon capability, leaving its existence-before-candidacy rule at full strength.

## The v1 support boundary, including CGNAT

**Supported in v1:** deployments where the operator controls edge NAT and holds a public IP —
static, or kept current by `capabilities/dyndns/` (the two capabilities remain independently
enableable: public ingress does not require dyndns, and a static-IP install needs no dyndns at
all).

**Not supported in v1: CGNAT and no-router-control environments.** The general answer for that
population is a tunnel — an outbound connection to a public relay forwarding inbound traffic to
the Gateway — but shipping one requires choosing specific tunnel software, and there is no
vendor-neutral standard to choose the way RFC2136 was chosen for DNS updates. Every concrete
candidate is either a specific commercial provider, which places a third party inside the inbound
trust path (a materially different security posture than dyndns/public-tls, whose RFC2136 choice
was made precisely for vendor-neutrality), or a self-hosted relay, which presupposes the operator
already administers a second, public host — a larger assumption than the capability's primary
population has. Picking one anyway, for a security-sensitive inbound-exposure mechanism, would be
the convenience choice this project's rules reject; mandating one would grow mandatory-v1 scope
that the primary documented environment (a home deployment with router control) does not need.

What v1 ships for that population instead is the **extension contract**, in exactly
`docs/extensions/`' established sense (a documented seam, nothing tested, nothing promised): any
mechanism that delivers TCP 443 (and optionally 80) to the platform Gateway's own Service without
terminating TLS itself — the platform's own wildcard certificate must be what the client sees —
satisfies the platform's side of the contract. A supported tunnel capability may be added post-v1
only by its own recorded decision here.

This is a decided boundary, not a silent downgrade: the capability's frozen design sketch named
"router port-forwarding, or a tunnel provider for users behind CGNAT" as mechanism options without
deciding a support boundary between them. This record decides it, in the open. Public ingress
itself remains mandatory before `rc.1`, implemented per this record.

## Invariants that must survive implementation

- **Private by default.** A fresh install is not publicly reachable; enabling
  `capabilities/public-tls/` does not expose anything (its own README already states this);
  exposure happens only through the deliberate, out-of-band edge procedure this record defines.
- **TLS terminates at the Gateway with the platform wildcard certificate** — in the supported path
  and in any extension-contract tunnel path alike. Nothing about exposure changes issuers,
  certificate shape, or ADR-0006's issuer-independence.
- **Authentication boundaries are untouched.** Exposure makes the Gateway reachable; it changes
  nothing about which routes require forward-auth or OIDC.
- **The reserved-ports review precedes forwarding.** The runbook's first step, backed by the
  existing CI assertion — forwarding a port nobody reviewed is the live-incident class
  `reserved-ports.yaml` exists to prevent.
- **The threat model is stated plainly.** SCRAP provides no in-cluster segmentation
  (`docs/out-of-scope/README.md`); an internet-reachable Gateway can reach whatever the
  application contract routes. The runbook says so before the forwarding step, not after.

## What PLAT-36 must deliver against this record

The boundary sketch — specifics belong to the implementation work item: the runbook as the
capability's README (its three steps and threat-model statement per this record); the operator-run
verification script with the deterministic checks and hairpin-honesty above; a CI acceptance
profile (or extension of an existing one) proving that script's oracle red and green; status/truth
updates across the repository's tables in the established honest form (implemented and
live-tested, operator-verified boundary named alongside); and the CGNAT extension contract
documented in `docs/extensions/`' sense. Explicitly out: any NetworkPolicy, any tunnel software,
any new manifest.

## Rejected alternatives

- **An inert placeholder manifest** (a NetworkPolicy, or any object shipped so that "manifests
  exist"): rejected, and outlawed by corollary 1. It would satisfy ADR-0012's letter by defeating
  its purpose — documentation masquerading as implementation is exactly what that record exists to
  prevent, and a manifest that does not do what it claims is worse than a README, because it
  carries false authority.
- **A tunnel mechanism in mandatory v1** (or shipped-but-optional in v1): rejected for the reasons
  in the support-boundary section — no vendor-neutral standard exists to pick, a provider pick puts
  a third party in the inbound trust path, a self-hosted relay presupposes infrastructure the
  primary population lacks, and the primary supported environment needs none of it. Deferring the
  pick costs v1 nothing; making it carelessly costs trust in the platform's most security-sensitive
  seam. Even the optional form would ship untested-or-tested-against-one-provider inbound exposure
  machinery this project would then own.
- **Reclassifying public ingress as post-v1**: rejected without needing new argument — ADR-0012
  explicitly forbids removing surfaces from the v1 envelope as an RC convenience, and this record
  has no grounds to re-scope the envelope: the capability is implementable, as defined above.
- **README-alone** ("the documentation is the implementation"): rejected. ADR-0012's "never a
  README alone" holds with full force here — what changes is the shape of the non-README artifacts
  (executable verification with a CI-proven oracle, plus the CI-gated reserved-ports review), not
  whether they must exist.

## Consistent with

`0012-rc-implementation-envelope.md` (public ingress remains mandatory pre-`rc.1`, its promise
unweakened — this record makes it implementable, not smaller; the existence-before-candidacy rule
is instantiated, not amended); `0013-ups-shutdown-authority.md` (the second recorded
enablement-rule exception, licensed as narrowly as the first, for a control point that — unlike
UPS's — lies outside even the host); `0011-release-candidate-policy.md` (the operator-run exposure
boundary is a permanent evidence class, stated honestly in release documentation, never claimed as
CI-proven); `0008-abstract-decisions-not-technologies.md` (router, DNS, and TLS inspected with
standard tools; no wrapper, no concealment); `0006-tls-wildcard-and-issuer-independence.md` (the
wildcard-certificate contract is an invariant of every exposure path, including the extension
contract); `0009-repository-topology.md` (the runbook and verification script are upstream product
surface, identical in both topologies; instance values arrive via `instance-config.yaml` scalars
as always); `docs/core/configuration-model.md` (its rule now carries a second recorded,
narrowly-scoped exception, stated there and licensed here); `docs/out-of-scope/README.md` (the
no-NetworkPolicy reality is load-bearing in corollary 1, unchanged); `capabilities/README.md` (the
tier rule is untouched; no new dependency direction exists at all).
