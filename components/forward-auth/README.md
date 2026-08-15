# components/forward-auth/

Not yet implemented.

Will provide: a single `HTTPRoute` filter (`ExtensionRef` to a Traefik `Middleware`) that gates an
application behind `capabilities/identity/`'s forward-auth endpoint (pattern P3). The application
never learns who authenticated — it only learns that a gateway-level check passed. Native OIDC
(pattern P2) is a separate, stronger integration for applications that support it directly; see
`capabilities/identity/README.md` and `docs/patterns/README.md` for the distinction.
