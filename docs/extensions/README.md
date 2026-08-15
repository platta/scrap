# docs/extensions/

**EXTENSION POINT.** A deliberate boundary where an advanced user can substitute or add something
without redesigning the platform. SCRAP documents the *contract* an alternative must satisfy and
where the seam is. It does not promise the alternative works, and does not test it. This is not a
plugin system — every seam below is an ordinary Kubernetes or Flux object SCRAP already uses.

| Subsystem | Extension point | Contract an alternative must satisfy | What changes |
|---|---|---|---|
| Storage | `StorageClass` | Provide `ReadWriteOnce` PVCs | Node-pinning assumptions and the restore path change; backup still works, since it mounts PVCs, never a provisioner's private host path. A snapshot-capable CSI driver unlocks a restore strategy SCRAP doesn't implement. |
| TLS issuance | `ClusterIssuer`, platform naming convention | Issue **one wildcard certificate** for `*.<domain>` + `<domain>` | Applications are unaffected — swapping the issuer is a one-line change (`docs/decisions/0006-tls-wildcard-and-issuer-independence.md`). Trust distribution becomes the user's problem. |
| Ingress controller | `GatewayClass` + `Gateway` | Implement Gateway API; provide an auth filter mechanism | **Honest caveat:** forward-auth uses a Traefik `Middleware` via `ExtensionRef`, because Gateway API has no standard auth primitive. Routing is portable; auth is not. |
| Identity | see [`identity.md`](identity.md) | OIDC issuer + forward-auth endpoint + group claim | Self-service recovery and passkey support may be lost — verify explicitly, don't assume |
| Backup engine | the per-app backup job contract | Read a mounted PVC or consume a dump; write to a configured destination | The platform's retention/prune/integrity-check policy no longer applies |
| Backup destination | a restic repository URL | Any restic backend | Recovery profile changes — see `docs/core/recovery-model.md` |
| Alert delivery | an Alertmanager receiver | Standard Alertmanager configuration | Anything Alertmanager itself supports |
| Secrets | the Flux `decryption` provider | Decrypt at reconcile time **and** be decryptable without a running cluster | The second clause disqualifies Sealed Secrets outright — see `docs/decisions/0007-reject-sealed-secrets.md` |
| Host OS / distribution | `bootstrap/host/` | Meet k3s's prerequisites; satisfy `bootstrap/preflight/` | An immutable-OS approach (e.g. Talos) would replace this layer entirely — a real future direction, not attempted in v1 |
| Kubernetes distribution | the cluster itself | Conformant, with a default RWO `StorageClass` and a `LoadBalancer` mechanism | k0s, RKE2, kubeadm — SCRAP's bootstrap and preflight are k3s-shaped today |

## What extension is not

No SCRAP-specific plugin API, no proprietary manifest format, no abstraction invented merely so a
box in a diagram looks extensible. Every seam above is exactly what you'd use to extend a plain
Kubernetes/Flux install with no SCRAP present at all — see
[Understanding SCRAP](../understanding-scrap.md) for why that's the point.
