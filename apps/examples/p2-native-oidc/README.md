# P2 -- HTTP application with native OIDC

`docs/patterns/README.md#p2`. `traefik/whoami`-style simplicity isn't possible here — native OIDC
means the application itself is an OIDC client, so it needs to actually be one.
`leplusorg/openid-connect-provider-debugger` is purpose-built for exactly this: a minimal relying
party configured entirely by environment variables, which redirects to the issuer, exchanges the
authorization code, and prints the resulting ID token claims as its response — proof that *the
application*, not a gateway, validated the token.

## What it proves

- **The identity contract**: this app declares only an issuer URL (via its discovery endpoint) and
  a client Secret — nothing about which product answers as that issuer.
- **`components/ca-trust/` actually closes the P2 gap it exists for**: this app's own backend calls
  (discovery + token exchange) go to `https://auth.${BASE_DOMAIN}` directly, over the platform's
  private CA. Without the CA-trust component, those calls fail with a TLS verification error; with
  it, they succeed. `SSL_CERT_FILE`, set by that component, is the only reason this works.
- **The declarative Blueprint contract**: the OAuth2 Provider and Application this app authenticates
  against exist purely from `capabilities/identity/blueprints-configmap.yaml` — nothing was clicked
  into existence.
- **In-cluster hostname resolution actually works**: this app's backend calls resolve
  `auth.${BASE_DOMAIN}` from *inside* the cluster — the first pattern in this repository to ever
  need that. Found live in the process: no prior pattern had ever exercised it, and
  `platform/ingress/`'s own claim that it worked was untested prose until this app proved
  (and briefly disproved, then fixed) it — see `platform/ingress/coredns-wildcard.yaml`.

**A real, pre-existing limitation of the demo image itself, unrelated to SCRAP**: this specific
image hardcodes `resolver 127.0.0.11` (Docker's own embedded DNS) into its `nginx.conf`, with no
env var to override it — meaningless inside a Kubernetes pod, and the reason `deployment.yaml`
carries an `initContainer` patching that one line before the main container starts. Worth knowing
if you reuse this image elsewhere.

## Verify

`https://p2.<your BASE_DOMAIN>/` serves a manual form (client ID/secret/discovery/redirect URI,
prefilled from nothing — this image doesn't auto-start from its own env vars). The actual proof:
`GET /debug` with those four values as query parameters — a real login link, not a raw form
submission, would normally do this. Either way, expect a `302` to
`https://auth.<your BASE_DOMAIN>/application/o/authorize/?...` with the correct `client_id` and
`redirect_uri` — confirming discovery, over the platform's private CA, from inside the cluster,
succeeded. Completing the redirect in a real browser (with the platform CA trusted) finishes the
round trip: authenticate, and the app's response is the ID token's claims as JSON.
