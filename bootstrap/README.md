# bootstrap/

**Tier 0.** Everything here runs *outside* the cluster, before Flux exists to reconcile anything.
Not yet implemented — this milestone establishes the skeleton and its documented contract; the
scripts themselves are the next implementation milestone.

## `preflight/`

Fail-loud checks that run before anything is installed: required ports free, the node's own DNS
resolver is not itself cluster-hosted (a direct fix for a real incident where stopping an in-cluster
DNS service broke the Git access needed to fix it), a roughly correct clock, cgroup v2, sufficient
disk, and a supported architecture. A failing preflight check blocks installation — it does not
warn and continue.

## `host/`

Host-level provisioning as data, not manual steps: the pinned k3s install (with `--disable=traefik`,
so Flux is the only reconciler for platform infrastructure — see `platform/ingress/`), node
labeling, and the minimum package/OS expectations. This directory is what makes "rebuild from Git
alone" actually true — a gap the reference implementation never closed.

## `install.sh`

The orchestration: preflight → k3s install → age key generation and **verified** escrow → seed the
Flux SOPS decryption secret (the one genuinely irreducible manual step — Flux cannot decrypt the key
that lets it decrypt anything) → `flux bootstrap` → postflight (every `Kustomization` Ready, a
backup ran, a restore was verified, and the alerting-receiver status is reported explicitly rather
than silently defaulting to nothing).

See `docs/core/bootstrap-lifecycle.md` for the full sequence, including what changes when optional,
connected capabilities are enabled at install time.
