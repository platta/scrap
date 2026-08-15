# 0007 — Secrets mechanism: SOPS + age; Sealed Secrets rejected

**Decision:** secrets are SOPS-encrypted with **age** keys, committed to Git, decrypted by Flux at
reconcile time. **Sealed Secrets is explicitly rejected** — worth stating outright, since it's the
most common choice in comparable homelab setups, and it is the wrong one for a recovery-first
design.

## The requirement

Secrets must be decryptable **outside a running cluster**, during recovery — this is the clause
that eliminates otherwise-reasonable alternatives.

## Why Sealed Secrets fails this requirement

Sealed Secrets' private key exists **only inside the cluster** that encrypted the secrets. If that
cluster is what you lost — the exact scenario a recovery-first platform must handle — you cannot
read your own secrets to rebuild it. This is actively hostile to recovery, not merely
inconvenient: it works perfectly until the one day it matters most.

## Why not External Secrets Operator + a cloud secret manager

Considered and rejected for a different reason: it introduces a bootstrap circularity (a running
operator, network access, and cloud credentials are all needed before anything can decrypt) and a
permanent cloud dependency for something the minimum profile is supposed to work without at all.

## Why SOPS + age

age keygen is a local, offline operation with no server and no account. SOPS encrypts only the
sensitive fields of a document, so `git diff` on a changed secret still shows *what* changed, not
just that it did. Flux decrypts natively per-`Kustomization` at reconcile time — no separate
decrypt-and-apply script that could leave plaintext on disk.

**Two age recipients from the first commit** — an operational key and an offline escrow copy — so
losing the operational key is a recoverable event, not a terminal one; the escrow key decrypts the
same repository. Both are verified-readable during bootstrap, not merely written down somewhere
(`docs/core/bootstrap-lifecycle.md`).
