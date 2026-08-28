# Adding an application

*You've got the platform running (see [Getting started](getting-started.md)). This is the one
obvious path for adding your first ordinary application to it — a normal stateless HTTP app, the
simplest and most common case. Everything else your application might need is a small, named
extension of this same path — see [What if my app needs more](#what-if-my-app-needs-more) below.*

## Where your app's files go

Everything lives under `apps/<your-app-name>/` — nowhere else. Nothing under `platform/` or
`capabilities/` should ever need to change to add a normal application; that's not a guideline,
it's a rule this repository's own CI enforces on every pull request (T2 — see the root
[README's repository structure section](../README.md#repository-structure) if you want the
reasoning).

## The minimal set of resources

A plain HTTP application needs exactly three Kubernetes manifests:

- A `Deployment` — your container, pinned to a specific image tag (no floating `latest`; CI checks
  this).
- A `Service` — the normal `ClusterIP` selector pointing at your `Deployment`'s pods.
- An `HTTPRoute` — the Gateway API object that gets traffic to your `Service` over your hostname.

```yaml
# apps/<your-app-name>/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <your-app-name>
spec:
  parentRefs:
    - name: scrap-gateway
      namespace: traefik
      sectionName: websecure
  hostnames:
    - "<your-app-name>.${BASE_DOMAIN}"
  rules:
    - backendRefs:
        - name: <your-app-name>
          port: 80
```

Then a `kustomization.yaml` under `apps/<your-app-name>/` listing all three files as `resources`.
For a complete, working, minimal reference, read
[`apps/examples/p1-internal-http/`](../apps/examples/p1-internal-http/) — three short files, one
purpose-built demo container that echoes back its own pod name so you can confirm a real request
reached it.

## How routing and TLS work without your app knowing anything about certificates

Notice the `HTTPRoute` above never mentions TLS, a certificate, or an issuer. That's not an
omission — **applications are not allowed to declare either one** (CI checks this: no
`Certificate` object and no `ClusterIssuer` reference is permitted anywhere under `apps/`). The
platform's Gateway already terminates HTTPS using one wildcard certificate covering
`*.${BASE_DOMAIN}`, provisioned by whichever certificate authority the instance is configured to
use — a private CA by default, or a publicly-trusted one if you've enabled
`capabilities/public-tls/`. Either way, your `HTTPRoute` reaching `Accepted` is the entire TLS
story from your application's point of view.

## The one file that turns your app on

Adding files under `apps/<your-app-name>/` alone does nothing yet — Flux only reconciles
directories it's told about. Add **exactly one** Flux `Kustomization` file under
`clusters/<your-instance-name>/`, pointing at your app's directory:

```yaml
# clusters/<your-instance-name>/apps-<your-app-name>.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps-<your-app-name>
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./apps/<your-app-name>
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: platform-ingress
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: instance-config
  wait: true
  timeout: 5m0s
```

The `dependsOn: platform-ingress` matters: your `HTTPRoute` needs the shared Gateway to already
exist to reach `Accepted`, and `wait: true` is what makes that ordering real instead of a race.
`clusters/<your-instance-name>/apps-examples.yaml` (already in your instance directory) is a
working, live example of exactly this shape — its `path:` just happens to point at the built-in
`apps/examples/` directory instead of your own app's.

## Reconcile and verify

Commit both additions (your `apps/<your-app-name>/` directory and the one enabling file under
`clusters/<your-instance-name>/`), then either wait for Flux's normal reconcile interval or force
it:

```sh
flux reconcile kustomization apps-<your-app-name> --with-source
```

Confirm it worked:

```sh
flux get kustomizations apps-<your-app-name>
curl --cacert <the exported CA> https://<your-app-name>.<your BASE_DOMAIN>/
```

A `Ready` Kustomization and a real response from your container confirm the whole path — Git,
Flux, routing, and TLS — is genuinely working, not just that the objects exist.

## What you explicitly do *not* need to touch

Nothing under `platform/` or `capabilities/`. No certificate, no issuer reference, no ingress
controller configuration, no DNS record beyond what your instance already has (a wildcard
`*.${BASE_DOMAIN}` already resolves anywhere your instance's other apps do). If you find yourself
about to edit either of those directories for what feels like an ordinary application, stop —
that's a sign your app needs something outside the normal contract, worth naming explicitly rather
than working around (see [`docs/core/application-contract.md`](core/application-contract.md)).

## What if my app needs more?

Ask these questions about your specific application, in this order, and each "yes" tells you which
established pattern to reach for next — the full technical definition of each is in
[`docs/patterns/README.md`](patterns/README.md), but you don't need to read pattern names to decide
what you need:

| Does your app... | Then you want | What that adds |
|---|---|---|
| need users to log in, and can it speak OIDC itself? | **P2 — native OIDC** | An OIDC issuer URL and a client secret from `capabilities/identity/`. Requires identity to be enabled. |
| need users to log in, but has no OIDC support of its own? | **P3 — gateway forward-auth** | One `HTTPRoute` filter (`components/forward-auth/`) that gates access before the request ever reaches your app — your app never learns who authenticated. Requires identity to be enabled. |
| need a non-HTTP port (a game server, a database you expose directly, a custom TCP/UDP protocol)? | **P4 — raw TCP/UDP** | A `LoadBalancer` `Service` whose port is declared in the reserved-ports allowlist — never `hostNetwork`, never an ad hoc host port. |
| keep data that needs to survive a restart, and does it need a *consistent* backup (a database, not just static files)? | **P5 — stateful with a declared consistency method** | A labelled `PersistentVolumeClaim` plus, if it's a database, a declared dump/quiesce command via `components/backup/`. `platform/backup/` discovers and backs it up automatically — you never write your own `CronJob`. |
| proxy to something that isn't even a Kubernetes workload — a NAS, a router admin UI, a hypervisor console? | **P6 — external LAN backend** | A selectorless `Service` + `EndpointSlice` pointing at the real address, plus an `HTTPRoute` like any other app. No pod, no image, at all. |

Real applications are usually more than one pattern at once — a typical login-gated app with a
database is P2 (or P3) **and** P5, composed together, not a separate seventh category.

## Where to go next

- **The full pattern reference**, including exactly what CI checks for each one —
  [`docs/patterns/README.md`](patterns/README.md).
- **The complete list of what an application may consume and what it never needs to know** —
  [`docs/core/application-contract.md`](core/application-contract.md).
- **A working, purpose-built example of every pattern**, isolated from any real application's
  unrelated complexity — [`apps/examples/`](../apps/examples/) and
  [`apps/examples/README.md`](../apps/examples/README.md).
- **Turn on a capability your app needs** (identity, for P2/P3) —
  [Choosing your capabilities](choosing-capabilities.md).
