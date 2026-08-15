# capabilities/public-tls/

**FULLY SUPPORTED.** Depends on `platform/cert-manager/` only.

Swaps the `ClusterIssuer` that `platform/cert-manager/`'s wildcard `Certificate` references, from
the private CA to Let's Encrypt via **ACME DNS-01**. DNS-01 is used specifically because it can
issue **wildcard** certificates (HTTP-01 cannot) and needs no inbound port at all.

**This is the same certificate shape as the private-CA path** — one wildcard, `*.<domain>` +
`<domain>`. Enabling this capability changes *trust distribution* only: client devices and
in-cluster workloads that call SCRAP endpoints now trust the certificate automatically, with no CA
to install anywhere. It does **not** change a single application manifest — see
`docs/decisions/0006-tls-wildcard-and-issuer-independence.md`.

## Public certificates are independent of public exposure

A public DNS `A` record may legally point at a private (RFC1918) address, and DNS-01 validates
ownership via a `TXT` record — it never connects to your host. **Enabling this capability does not
expose anything to the internet.** That's a separate, later choice — `capabilities/public-ingress/`.
This is deliberately the sweet spot for most homelabs: publicly-trusted certificates, zero inbound
exposure.

## New assumptions this introduces

A registered domain, a public DNS zone for it, a DNS provider with an API and a scoped credential,
and internet access at issuance/renewal time (roughly every 60 days). No inbound port.
