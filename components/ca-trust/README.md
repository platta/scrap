# components/ca-trust/

Gives an application's own workload — not a browser — a trust store that includes the platform's
private CA, so its own backend TLS calls to a SCRAP endpoint (an OIDC client validating the
identity provider's certificate, most concretely — pattern P2) succeed. This is **workload trust**,
distinct from client (browser/device) trust — see `platform/cert-manager/README.md`.

Only meaningful on the private-CA path (`platform/cert-manager/`'s default issuer). An application
using `capabilities/public-tls/` needs nothing here — its stock trust store already trusts the
certificate, which is the actual point of that capability.

**Verified cost, not a guess:** an application making backend TLS calls to a SCRAP endpoint (for
example, an OIDC client validating the identity provider's certificate) fails without this
component and succeeds with it. Measured during the identity-implementation evaluation
(`docs/decisions/0002-identity-implementation.md`): a real OIDC integration required exactly this
shape of CA bundle injection to complete its token exchange.

## Usage

```yaml
# your app's kustomization.yaml
resources:
  - deployment.yaml
  - ...
components:
  - path/to/components/ca-trust
```

Your Deployment's `spec.template.spec` must already declare `volumes: []`, and its first
container `env: []` and `volumeMounts: []` (empty lists are fine) — see `kustomization.yaml`'s own
comment for exactly why this component appends rather than risks clobbering an app's existing
volumes or env.

## Mechanism — no init container, no SCRAP-authored concatenation

The architecture originally sketched an init container that concatenates the system CA bundle with
the platform's CA at Pod startup. Implemented differently, and simpler: `trust-manager`
(`platform/cert-manager-config/trust-bundle.yaml`, same upstream org as cert-manager) already does
that concatenation server-side and publishes the result as a ConfigMap (`scrap-ca-bundle`, key
`ca-bundle.crt`) in **every namespace**, unconditionally. This component's whole job is mounting
that already-complete ConfigMap and pointing `SSL_CERT_FILE` at it — no init container, no
per-namespace opt-in step on the platform side, nothing for this directory to build beyond the
patch itself.

## What this does NOT do

- Does not help client/browser trust — see `docs/core/` for the operator-facing CA export/install
  instructions (postflight).
- Does not set every language runtime's trust variable — `SSL_CERT_FILE` covers Python, most Go
  binaries via `SSL_CERT_FILE`/`GODEBUG`, and OpenSSL-linked runtimes generally. A JVM app needs its
  own truststore mechanism (`-Djavax.net.ssl.trustStore`) pointed at the same mounted file instead;
  not attempted here.
- Does not attach to `StatefulSet`s — only `Deployment`s. An app like `apps/examples/p5-stateful-backup/`
  needs its own manual wiring if it ever needs workload CA trust.
