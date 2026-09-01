# Application integration patterns

**CORE documentation — this is the application contract, restated as decision points.** Every
application in `apps/` should be classifiable into one or more of these six patterns. If something
doesn't fit any of them, that's useful information: it's outside T2 (adding a normal application
requires no platform change), and should say so rather than forcing a fit.

The question this answers is: *"how do I deploy application X?"* — classify X, then compose the
capabilities the pattern calls for. You are not designing infrastructure.

## P1 — Internal HTTP application

A `Deployment` + `Service` + `HTTPRoute`. No authentication, no persistence. TLS and routing come
free from `platform/ingress/` and `platform/cert-manager/` — the application declares neither.
**The floor every other pattern builds on.**

## P2 — HTTP application with native OIDC

P1 plus an OIDC client. The application itself knows who the user is — it validates tokens, reads
claims, and can make its own authorization decisions (e.g. mapping an identity-provider group to an
admin role). Requires `capabilities/identity/`. The application declares an issuer URL and consumes
a client-secret `Secret`; it does not know or care which product is answering as that issuer.

## P3 — HTTP application behind gateway forward-auth

P1 plus one `HTTPRoute` filter (`components/forward-auth/`) pointing at the identity capability's
shared auth endpoint. The application does **not** learn who authenticated — it only knows a
gateway-level check passed before the request reached it. This is the fallback for applications
with no OIDC support of their own, and it should never be described as "SSO into the app," because
it isn't one.

## P4 — Raw TCP/UDP exposure

A dedicated `Service` of type `LoadBalancer`, never `hostNetwork`, never an ad hoc host port. Its
port must be declared reserved in a `reserved-ports.yaml` colocated with the application itself,
under `apps/<name>/` — not a `platform/` file, so adding a P4 app stays within T2 — and CI checks
that on every pull request (`docs/decisions/0017-p4-port-reservation-ownership.md`) — the direct,
structural fix for an ingress controller silently claiming a host's real production ports.

## P5 — Stateful application with a declared consistency method

Any of the above, plus persistence and an explicit answer to "how do we back this up
consistently?" — a database logical dump, a quiesce-then-copy sequence, or plain file copy when
that's honestly sufficient. The application labels its `PersistentVolumeClaim`; `platform/backup/`
discovers it and does the rest. See `components/backup/`.

## P6 — Reverse proxy to an external backend

No pod, no image at all: a selectorless `Service` + `EndpointSlice` pointing at a real address
outside the cluster (a NAS, a router's admin UI, a hypervisor), plus an `HTTPRoute` and, if the
backend does its own TLS, a `BackendTLSPolicy`. This is one of the most broadly useful patterns for
a homelab — anything with a web UI but no identity or TLS of its own becomes reachable through the
same routing, TLS, and (optionally) forward-auth as everything else, with zero code running for it.

## Composing patterns

Real applications are usually more than one pattern at once — a typical stateful web app is P2 (or
P3) **and** P5. The patterns are decision axes, not mutually exclusive categories.
