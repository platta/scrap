# capabilities/identity/

**FULLY SUPPORTED implementation: Authentik. Identity itself is OPTIONAL** — a SCRAP install must
be complete and useful with this directory absent entirely (T1). Alternative identity providers
(Authelia, Keycloak, an external IdP) are documented **extension points**, not supported
implementations — see `docs/extensions/identity.md`.

## Why Authentik, specifically

Decided empirically, not by feature comparison: a full Authelia deployment was built, exercised
through real user lifecycle flows, and destructively restored, specifically to answer one question —
does the lighter option turn the operator into a permanent identity helpdesk? It does. Authelia's
file-based user store forces a choice between password self-service (impossible with a
Git-managed, read-only user file) and Git-managed configuration (impossible with a writable one) —
and without SMTP, both password reset and MFA enrollment silently appear to succeed while routing
their one-time codes to a location only the operator can reach. Authentik's PostgreSQL-backed user
store has no such structural conflict. Full reasoning and evidence:
`docs/decisions/0002-identity-implementation.md`.

This cost real resources to earn: Authentik measures roughly 6–7× Authelia's footprint. That's why
identity remains optional and gates a higher hardware tier (`docs/supported/hardware-tiers.md`),
rather than being pulled into `platform/`.

## Non-negotiable requirement for this directory

**Everything required for SCRAP's supported identity behavior — Providers, Applications, groups,
scope mappings, policy bindings, flows — must be expressed as Authentik Blueprints, stored in Git,
reconciled by Flux.** No object required for normal operation may exist only by direct API call.

| Belongs to | Contains | Lifecycle |
|---|---|---|
| Configuration (Git, Blueprints) | Providers, Applications, groups, scope mappings, policy bindings | *recreated* |
| State (PostgreSQL, restic) | User accounts, passwords, enrolled TOTP/WebAuthn devices, sessions | *restored* |

This is not a preference; it is required for T2 to hold for OIDC applications, and for the recovery
model's "configuration is recreated, data is restored" principle to remain true. The reference
implementation never solved this — its Providers, Applications, and policy bindings existed only in
a database, created by direct API call. That is exactly what this directory must not repeat.

## The contract this hands to applications

- **Native OIDC** (pattern P2): an OIDC issuer URL and a per-application client Secret.
- **Forward-auth** (pattern P3): a shared gateway-level auth endpoint, consumed via
  `components/forward-auth/` — one filter reference on an `HTTPRoute`, nothing more.

Both are the general identity contract (`docs/core/application-contract.md`), not Authentik-specific
— an extension implementation must satisfy the same two.

## New assumptions this introduces

A PostgreSQL database to back up and restore (the same pattern already used for other stateful
applications, `platform/backup/`). Roughly 1 GB of additional memory — the identity hardware tier.
No internet, no external account.
