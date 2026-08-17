# components/forward-auth/

Gates an application behind `capabilities/identity/`'s forward-auth endpoint (pattern P3) with one
line in your `kustomization.yaml`. The application never learns who authenticated — it only learns
that a gateway-level check passed. Native OIDC (pattern P2) is a separate, stronger integration for
applications that support it directly; see `capabilities/identity/README.md` and
`docs/patterns/README.md` for the distinction.

## Usage

```yaml
# your app's kustomization.yaml
namespace: your-app-namespace   # required -- see "Why namespace: is required" below
resources:
  - deployment.yaml
  - service.yaml
  - httproute.yaml
components:
  - path/to/components/forward-auth
```

That's it. Your `HTTPRoute`'s first rule gains a Traefik `ExtensionRef` filter pointing at a
`Middleware` this component also adds, which forwards every request to authentik's embedded
outpost before Traefik ever reaches your backend.

## What this does NOT do

- Does not create the identity capability itself, an Application, or a Provider in authentik --
  those are `capabilities/identity/`'s declarative Blueprints. This component only wires the
  gateway-level check; something on the identity side has to actually exist to answer it.
- Does not tell your application who authenticated. If your app needs that, it's pattern P2 (native
  OIDC), not this.
- Only patches the **first** rule of every `HTTPRoute` in your build. An app with more than one
  `HTTPRoute` rule needing this needs its own additional patch for the others.

## Why `namespace:` is required

Gateway API's `HTTPRoute` filter `extensionRef` can only reference an object in the **same
namespace** as the `HTTPRoute` itself -- there's no namespace field on it at all, unlike
`backendRefs`. This component's `Middleware` therefore ships with no `metadata.namespace` of its
own; your `kustomization.yaml`'s top-level `namespace:` transformer is what places it (and
everything else in your build) in the right namespace. Every `apps/examples/` app so far hardcodes
`namespace:` per-resource instead of using this transformer -- a P3 example needs to add it, since
this is the first component that actually requires it.

## Mechanism, no SCRAP invention

A Traefik `Middleware` (`forwardAuth`, pointed at
`http://authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik` --
authentik's own embedded outpost, plain HTTP, pod-to-pod, never through the Gateway or the
platform's TLS at all) and a JSON6902 patch adding one `ExtensionRef` filter. Both are native
Traefik/Gateway API mechanisms; see `docs.goauthentik.io`'s own Traefik forward-auth integration
guide for the `Middleware` shape this mirrors exactly.
