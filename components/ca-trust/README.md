# components/ca-trust/

Not yet implemented.

Will provide: an init container that concatenates the system CA bundle with the platform's private
CA certificate into an `emptyDir`, plus the environment variable an application's language runtime
needs to trust it (for example `SSL_CERT_FILE`). This is **workload trust**, distinct from client
(browser/device) trust — see `platform/cert-manager/README.md`.

Only meaningful on the private-CA path (`platform/cert-manager/`'s default issuer). An application
using `capabilities/public-tls/` needs nothing here — its stock trust store already trusts the
certificate, which is the actual point of that capability.

**Verified cost, not a guess:** an application making backend TLS calls to a SCRAP endpoint (for
example, an OIDC client validating the identity provider's certificate) fails without this
component and succeeds with it. Measured during the identity-implementation evaluation
(`docs/decisions/0002-identity-implementation.md`): a real OIDC integration required exactly this
shape of CA bundle injection to complete its token exchange.
