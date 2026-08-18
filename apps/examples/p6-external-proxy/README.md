# P6 -- reverse proxy to an external LAN backend

`docs/patterns/README.md#p6`. No pod, no image, no SCRAP-managed code at all: a selectorless
`Service` + `EndpointSlice` naming a real address outside the cluster, plus an ordinary
`HTTPRoute`. One of the most broadly useful patterns for a homelab -- a NAS, a router's admin UI,
a hypervisor console, anything with a web UI but no identity or TLS of its own becomes reachable
through the same routing and TLS as every other application, with zero code running for it.

## Configuring a real backend

`endpointslice.yaml` points at `${EXAMPLE_P6_BACKEND_ADDRESS}` and `${EXAMPLE_P6_BACKEND_PORT}`,
which ship in `clusters/example/instance-config.yaml` as an RFC 5737 documentation address (a
placeholder, never a real one, exactly like that file's `NODE_ADDRESS`) and `"80"` respectively. Set
the address to your device's real LAN address, and the port too if it isn't 80, to make this
pattern actually route traffic; until then, this example demonstrates the shape of the pattern, not
a working proxy. `tests/profiles/t-a-minimal.sh` overrides both to point at a real, ephemeral
backend it stands up itself, and reads real content back through the proxy -- see that script for
why the port specifically has to be configurable to make that possible.

`endpointslice.yaml` also sets `conditions: {ready: true, ...}` on its one endpoint explicitly --
found live, not theoretical: a hand-written `EndpointSlice` has no controller reconciling
readiness for it the way a normal Service's generated one does, and Traefik's Gateway provider
treats an endpoint with no explicit `ready: true` as unhealthy (`no available server`). Any
hand-maintained `EndpointSlice` needs this, not just this example.

## What it proves

That P1's TLS/routing story -- the application declares nothing about TLS, and it works -- holds
identically for a backend that isn't a Kubernetes workload at all.

## Verify

```
curl --cacert <exported CA, or -k on the private-CA path> https://p6.<your BASE_DOMAIN>/
```

Expect whatever the real backend serves at `/`, terminated with the platform's TLS the same way
P1's response was.
