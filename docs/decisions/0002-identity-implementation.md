# 0002 — Identity implementation

**Decision:** **Authentik is the FULLY SUPPORTED identity implementation. Authelia is documented as
an EXTENSION POINT** (`docs/extensions/identity.md`). Identity itself remains entirely OPTIONAL —
a SCRAP install is complete without it.

## How this was decided

Not by feature comparison. A full Authelia deployment was built — single pod, SQLite storage, file-
based users, OIDC provider enabled, one forward-auth application and one native-OIDC application
wired against it — and exercised through real user lifecycle flows, followed by a genuine
destructive-restore test (PVC and PV deleted and confirmed gone at the storage-backend level, then
restored and verified functionally, not just by row counts).

The deciding question, stated up front before any evidence was gathered: **does choosing the
lighter identity provider make the SCRAP operator a permanent identity helpdesk?**

## What the evidence actually showed

Authelia won on every quantitative axis measured:

| | Authelia (measured) | Authentik (reference deployment) |
|---|---|---|
| Pods | 1 | 4 (server, worker, PostgreSQL, Redis) |
| Memory | ~165 MB | ~1.1 GB |
| Storage | ~330 KB (SQLite) | a PostgreSQL PVC |
| Forward-auth | worked on first configuration attempt | required more integration work in the reference deployment this evidence is drawn from |
| Destructive restore | passed, functionally verified | passed |

Had footprint alone been decisive, Authelia would have won. It lost on the deciding question, for a
reason that turned out to be **structural, not configurational**:

**Password self-service is incompatible with a Git-managed, file-based user store.** A read-only
user file (the GitOps-correct choice — "configuration is recreated") makes password self-service
impossible; a writable one makes passwords work but removes users from Git entirely, turning them
into opaque backup state with no configuration half at all. Neither answer is good, and no amount
of SMTP configuration fixes it — the conflict is about *where the password lives*, not about
notification delivery.

Compounding this: without SMTP configured, both password reset and MFA/TOTP enrollment routed their
one-time codes to a file inside the container, reachable only via direct cluster access — while the
API returned a success response to the user. Every credential lifecycle event becomes an
operator-mediated helpdesk ticket, on a path that silently pretends to work rather than failing
visibly. *In fairness to Authelia: this specific failure mode is fixed by configuring SMTP — but
that makes SMTP a hard requirement of the identity capability, which is itself a new external
dependency SCRAP would have had to impose to make the lighter option viable.*

A secondary finding: identity state was split across three stores with different lifecycles (a
users file, a SQLite database, and a set of secrets), each needing its own backup treatment. A
complete restore requires all three. Authentik's model — everything except secrets in one
PostgreSQL database — is simpler to reason about and to restore.

**What was explicitly left untested, and is not inferred either way:** passkey/WebAuthn enrollment,
which requires a real browser and was out of scope for the API-driven evaluation. This is material
because passkey support was one of the two original reasons a fuller-featured identity provider was
considered in the first place. Anyone choosing the Authelia extension path should verify this
themselves rather than assume either outcome.

## What choosing Authentik obligates SCRAP to do

This decision is not free, and the obligation is now part of the architecture, not a nice-to-have:

**Authentik's configuration must be fully declarative.** Every Provider, Application, group, scope
mapping, and policy binding SCRAP's supported identity behavior needs must be expressed as an
Authentik Blueprint, stored in Git, reconciled by Flux — never created only by direct API call or
by clicking through the admin UI. An implementation that leaves any of this undeclared breaks T2 for
every OIDC application and breaks "configuration is recreated" for the whole identity capability.
This is the single largest piece of implementation work the identity capability creates — see
`capabilities/identity/README.md`.

**A ≥8 GB hardware tier** is published for any install enabling identity — see
`docs/supported/hardware-tiers.md`. The 4 GB minimum floor is unaffected, because identity is
optional.

**Authentik's own recovery flows need adversarial testing**, not just functional testing — a
lighter-provider evaluation like this one is exactly the kind of scrutiny an identity provider's
account-recovery paths deserve before being shipped as a default.

## Why this isn't a rout for Authelia

Authelia remains genuinely well suited to a smaller install willing to accept the tradeoffs above,
and is documented as a first-class extension, not a discouraged option — `docs/extensions/identity.md`
carries the concrete configuration issues found (and their fixes) so choosing it doesn't mean
repeating the same discovery process.
