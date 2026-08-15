# 0006 — TLS certificate model: one wildcard, issuer-independent applications

**Decision:** SCRAP issues **exactly one wildcard certificate** (`*.<domain>` + `<domain>`) on the
shared Gateway, in every configuration. Applications declare no `Certificate` and no issuer
reference, ever. The only thing that changes between the minimum and fully-supported TLS paths is
**which `ClusterIssuer` produces that one certificate.**

## The reframe this corrects

The obvious-seeming design is "private CA for the minimum path, per-application ACME certificates
for the public path." That's wrong on two counts. First, Let's Encrypt issues wildcard certificates
via **ACME DNS-01** — the same mechanism SCRAP already uses for its public-TLS capability — so the
wildcard shape isn't a private-CA-only convenience; it's available identically on both paths.
Second, per-application certificates would have reintroduced exactly the defect this design exists
to avoid: a platform file listing every application's hostname (the reference implementation's
seven-SAN certificate pattern), which is a platform change every time an application is added —
directly violating T2.

## The resulting model

```
TLS
├── CORE: certificate lifecycle management (cert-manager)
├── CORE, minimum path: private CA issuer — no domain, no DNS, no internet
├── SUPPORTED: ACME DNS-01 (Let's Encrypt) issuer — same wildcard shape
└── EXTENSION: other cert-manager issuers (Vault, step-ca, corporate PKI)
```

Both configurations produce the identical certificate shape on the identical Gateway listener. An
application's `HTTPRoute` is unaffected by which one is active — CI proves this statically: no
`Certificate` resource and no `ClusterIssuer` reference may exist anywhere under `apps/`.

## What actually differs between the two paths: trust distribution, and nothing else

| | Private CA (minimum) | ACME DNS-01 (supported) |
|---|---|---|
| Certificate lifecycle | wildcard, auto-renewed | identical |
| Application configuration | none | identical |
| Client devices | must be told to trust the root — easy on a laptop, genuinely painful on phones/TVs | nothing to do |
| In-cluster workload TLS calls | apps calling SCRAP endpoints (e.g. an OIDC backend call) need the CA injected — `components/ca-trust/` | nothing to do |
| External dependencies | none | domain, public DNS zone, DNS provider API token, internet |

Client trust and workload trust are the same underlying question — "does this caller already trust
our issuer?" — asked twice, once outside the cluster and once inside it. **Enabling ACME answers
both at once.** That's a cleaner way to frame the upgrade than "public certificates are nicer": it's
specifically what you stop having to do twice.

## A public domain does not mean public exposure

A public DNS `A` record may legally point at a private (RFC1918) address, and DNS-01 validates
ownership via a `TXT` record — it never connects to the host at all. So `capabilities/public-tls/`
can be enabled with **zero** inbound exposure, which is a distinct, later choice
(`capabilities/public-ingress/`). Many homelabs should stop at "certificates my devices already
trust, nothing reachable from the internet" — and the architecture makes that a clean intermediate
point rather than an all-or-nothing jump.

## Caveats, stated honestly

- A wildcard covers one label; `*.example.com` does not cover `a.b.example.com`.
- An application terminating its own TLS (pattern P4, e.g. a raw-TCP service doing its own
  handshake) needs certificate *material* in its own namespace — still issuer-independent, but not
  entirely free.
- DNS-01 needs a DNS-editing credential, scoped to exactly the zone it's used for.
- First ACME issuance can take minutes (DNS propagation) — an expectation to set, not a defect.
