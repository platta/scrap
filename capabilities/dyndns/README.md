# capabilities/dyndns/

**FULLY SUPPORTED.** No dependency on other capabilities; relevant alongside
`capabilities/public-tls/` and `capabilities/public-ingress/` when the host's public IP is not
static.

A generic dynamic-DNS updater contract: any provider with an API can back it, not one specific
vendor. Purely outbound — keeps a DNS record pointed at the current public IP.

## New assumptions this introduces

A dynamic-DNS-capable domain/provider and internet access. No inbound exposure by itself.
