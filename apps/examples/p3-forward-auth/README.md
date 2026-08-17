# P3 -- HTTP application behind gateway forward-auth

`docs/patterns/README.md#p3`. Reuses P1's `whoami` deployment unchanged — the entire point of this
pattern is that the application needs no OIDC library, no client Secret, no awareness that
authentication exists at all. `components/forward-auth/` is the only thing that differs from P1:
one component include, one Traefik `Middleware`, one `ExtensionRef` filter on the `HTTPRoute`.

## What it proves

- **Forward-auth genuinely gates the request**, not just theoretically: an unauthenticated request
  never reaches this pod at all — Traefik's `Middleware` redirects to authentik's login flow first.
- **The application stays completely unaware**: `whoami`'s own response contains no identity
  information the *application* generated — any `X-authentik-*` headers present were added by
  Traefik after the `Middleware` approved the request, never by this pod. This is precisely why
  forward-auth is never "SSO into the app" — the app never learns who authenticated.
- **The declarative Blueprint contract**, same as P2: the Proxy Provider, its Application, and its
  attachment to authentik's embedded outpost all exist purely from
  `capabilities/identity/blueprints-configmap.yaml`.

## Verify

Visit `https://p3.<your BASE_DOMAIN>/` in a browser with the platform CA trusted. Expect a redirect
to authentik's login page before ever seeing `whoami`'s response; after authenticating, `whoami`'s
echoed request headers include `X-Authentik-Username` and friends — added by the `Middleware`, not
by any code in this Deployment.
