# Identity — extension point

**EXTENSION POINT.** The supported implementation is Authentik (`capabilities/identity/`). This
page is for anyone substituting a different one — Authelia, Keycloak, an external IdP (Google,
Entra, Auth0) — a legitimate, documented choice SCRAP simply doesn't test.

## The contract an alternative must satisfy

1. **OIDC issuer** — `/.well-known/openid-configuration`, JWKS, authorization/token/userinfo
   endpoints, reachable at a platform-routed hostname. Consumed by pattern P2 applications.
2. **Forward-auth endpoint** — accepts a subrequest, returns 2xx / 401 / a redirect, and emits
   identity headers. Consumed by pattern P3 applications via `components/forward-auth/`.
3. **A group/role claim** exposed to both of the above, for authorization mapping.

SCRAP provides, to any implementation satisfying this: a hostname and TLS via the shared Gateway, a
namespace, PVC storage, SOPS-managed secrets, backup of declared state, and the
`components/forward-auth/` component that applications include. **Nothing in `platform/` may
depend on identity** — the integration glue lives entirely in `capabilities/identity/`, and that
directory may depend on `platform/`, never the reverse.

## Where the contract's edges actually break — verified, not speculative

Real, measured differences found while evaluating Authelia against this exact contract
(`docs/decisions/0002-identity-implementation.md`):

- **Claim placement differs.** Some providers ship a minimal ID token by default —
  `groups`/`email`/`name` may exist only at the `/userinfo` endpoint until explicitly promoted.
  Applications reading authorization from the ID token can silently get nothing. Check both.
- **Token endpoint auth method defaults differ**, and a mismatch surfaces on the *application*
  side as an opaque `invalid_client` — the real cause is usually only in the identity provider's
  own log.
- **Consent behavior differs** — some providers require per-client consent by default.
- **State model differs**, which changes the backup contract: some spread identity state across
  more than one store with different lifecycles (a user file plus a database plus secrets); verify
  what a complete restore actually requires.
- **Self-service capability differs**, which changes operator burden — this was the axis that
  decided SCRAP's own supported choice. If password reset or MFA enrollment depends on SMTP being
  configured, verify what happens when it isn't, rather than assuming a graceful failure.

## Authelia specifically

The best-documented alternative, precisely because SCRAP measured it while evaluating this
contract: a single pod, roughly 165 MB, no PostgreSQL, no Redis required — a genuinely good fit for
a smaller install willing to accept its lifecycle tradeoffs. Passkey/WebAuthn support was left
explicitly untested during that evaluation — not confirmed, not refuted. Full evidence, including
the specific configuration issues hit and their fixes, in
`docs/decisions/0002-identity-implementation.md`.
