# capabilities/public-ingress/

**FULLY SUPPORTED.** Depends on `platform/ingress/`. Strongly recommended alongside
`capabilities/public-tls/`, though not required by it (see that directory's README — public trust
and public exposure are independent choices).

Makes the platform Gateway reachable from the public internet: router port-forwarding, or a tunnel
provider for users behind CGNAT or without router control. Includes split-horizon DNS guidance so
that LAN clients and internet clients resolving the same hostname do not depend on router NAT
hairpin behavior working correctly — a real, previously undiagnosed dependency in the reference
implementation.

## New assumptions this introduces

A public IP or a tunnel provider account; router control, or a tunnel; a materially larger threat
model than a LAN-only install, since the Gateway is now reachable by anyone. Documented plainly, not
minimized — this is the capability with the most consequential new assumptions in the entire
envelope.
