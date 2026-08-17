# P1 -- internal HTTP application

`docs/patterns/README.md#p1`. A `Deployment` + `Service` + `HTTPRoute`. No authentication, no
persistence, no TLS declaration of any kind.

## What it proves

That a plain HTTP workload becomes reachable over HTTPS, through the platform's shared Gateway and
its one wildcard certificate, by declaring routing alone -- nothing about TLS, nothing about which
issuer is active.

## Verify

```
curl --cacert <exported CA, or -k on the private-CA path> https://p1.<your BASE_DOMAIN>/
```

`traefik/whoami` echoes the request it received, including its own pod name -- enough to confirm
the request actually reached this specific Deployment through TLS termination, not a cached or
misrouted response.
