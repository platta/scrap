# Bootstrap lifecycle

**CORE.** Implemented (`bootstrap/`) — this is the documented sequence the implementation follows,
exercised end-to-end (steps 1–7) by every `tests/profiles/` from-zero run, every push/PR; see
`docs/release-readiness.md`. One honest exception, in step 7 below: `bootstrap/postflight.sh`
itself does not verify a restore — see the note under step 7 for what actually discharges that
line of the frozen spec, and where.

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

   **Deliberate deviation from the frozen wording, found implementing `bootstrap/postflight.sh`:**
   a fresh install has no application data yet, so postflight cannot verify *a restore* without
   restoring something real — there is nothing backed up to restore. `postflight.sh` proves only
   that the backup *engine* runs (it triggers an immediate job and waits for it to succeed) and
   says so plainly, under its own "HONEST LIMIT" heading, rather than implying more. The frozen
   requirement is still discharged, just not by this script: `tests/profiles/t-a-minimal.sh`
   destructively deletes real data (application-level delete *and* the on-disk file, so the
   destroy step can't be a no-op) and restores it via restic, verified through the original
   application pod by the exact value that was destroyed — every push/PR, not merely attempted.
   The same procedure is documented for a real operator's first backed-up application in
   `docs/runbooks/README.md`. `bootstrap/install.sh` also discards `postflight.sh`'s own exit
   status (`|| true`, `bootstrap/install.sh:382`) by design — the postflight report is meant to
   inform the operator, not gate the install; only CI machine-checks its postconditions, in
   `t-a-minimal.sh`.

## Additional steps introduced by supported capabilities

| Capability | Extra bootstrap step |
|---|---|
| Public TLS (ACME) | DNS provider credential; issuer selection; staging issuer first, then production |
| Public ingress | Split-horizon DNS setup; router/tunnel configuration; reserved-ports review |
| Dyndns | TSIG key provisioned on your authoritative nameserver; hostname/nameserver/IP-lookup URL set in `instance-config.yaml` |
| Off-site backup | Endpoint + credentials; `restic init`; restic password escrowed and verified **separately** from the age key |
| Identity | Enable the capability; one interactive enrollment; export the declarative Blueprint config |
| Heartbeat | Register the check; confirm a test ping arrives |
| External Git | Add the remote; migrate; confirm Flux follows |

Escrow verification is deliberate and appears twice (age key, restic password) — both are
fatal-if-lost secrets, and "written down somewhere" is not the same claim as "verified readable."
