# P4 -- raw TCP/UDP exposure

`docs/patterns/README.md#p4`. A dedicated `Service` of type `LoadBalancer`, port declared in
`platform/ingress/reserved-ports.yaml`. No `HTTPRoute`, no Gateway involvement at all -- this
pattern bypasses the shared Gateway entirely, which is the point: some protocols aren't HTTP.

## What it proves

That a raw TCP port reaches a pod through k3s's ServiceLB, and that the reserved-ports allowlist
mechanism -- the direct fix for a real incident where an ingress controller's default
`LoadBalancer` Service silently claimed a host's real production ports -- is a normal, expected,
one-line-per-app touch to `platform/ingress/reserved-ports.yaml`, not a platform behavior change.

## Verify

```
echo "hello" | nc <NODE_ADDRESS> 9000
```

Expect `hello` echoed straight back -- confirms the byte stream round-tripped through the
`LoadBalancer` Service into the pod and back, unmodified.
