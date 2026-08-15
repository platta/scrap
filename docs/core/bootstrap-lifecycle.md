# Bootstrap lifecycle

**CORE.** Not yet implemented (`bootstrap/`) — this is the documented sequence the implementation
must follow.

## Minimum / offline path

1. **Preflight** (`bootstrap/preflight/`) — fails loudly, never just warns: required ports free;
   the node's own DNS resolver is not itself cluster-hosted; clock sane; cgroup v2; sufficient
   disk; supported architecture.
2. **Host** (`bootstrap/host/`) — install pinned k3s with `--disable=traefik`.
3. **Keys** — generate two age keypairs (operational + offline escrow), both listed as SOPS
   recipients from the very first commit. **Verify escrow before continuing** — demonstrate the
   escrow copy is readable from somewhere that isn't this host, not merely that it was written
   somewhere.
4. **Git** — initialize the source of truth. A local bare repository is sufficient for the
   minimum profile; external Git hosting is what buys host-loss recovery of the source of truth
   itself (`capabilities/`-adjacent, documented in `docs/supported/`).
5. **Seed** — create the Flux SOPS decryption `Secret`. The one genuinely irreducible manual step:
   Flux cannot decrypt the key that lets it decrypt anything.
6. **Flux bootstrap** — tiers reconcile in order (`docs/core/repository-structure.md`).
7. **Postflight** — every `Kustomization` Ready; the private CA root exported with its trust
   instructions printed; a backup ran; **a restore was verified**, not merely attempted; the
   alerting-receiver state is reported explicitly — including, honestly, "no receiver configured,
   you will not be told if backups stop" when that's true.

## Additional steps introduced by supported capabilities

| Capability | Extra bootstrap step |
|---|---|
| Public TLS (ACME) | DNS provider credential; issuer selection; staging issuer first, then production |
| Public ingress | Split-horizon DNS setup; router/tunnel configuration; reserved-ports review |
| Off-site backup | Endpoint + credentials; `restic init`; restic password escrowed and verified **separately** from the age key |
| Identity | Enable the capability; one interactive enrollment; export the declarative Blueprint config |
| Heartbeat | Register the check; confirm a test ping arrives |
| External Git | Add the remote; migrate; confirm Flux follows |

Escrow verification is deliberate and appears twice (age key, restic password) — both are
fatal-if-lost secrets, and "written down somewhere" is not the same claim as "verified readable."
