# capabilities/identity/

**FULLY SUPPORTED implementation: Authentik. Identity itself is OPTIONAL** — a SCRAP install must
be complete and useful with this directory absent entirely (T1). Alternative identity providers
(Authelia, Keycloak, an external IdP) are documented **extension points**, not supported
implementations — see `docs/extensions/identity.md`.

## Why Authentik, specifically

Decided empirically, not by feature comparison: a full Authelia deployment was built, exercised
through real user lifecycle flows, and destructively restored, specifically to answer one question —
does the lighter option turn the operator into a permanent identity helpdesk? It does. Authelia's
file-based user store forces a choice between password self-service (impossible with a
Git-managed, read-only user file) and Git-managed configuration (impossible with a writable one) —
and without SMTP, both password reset and MFA enrollment silently appear to succeed while routing
their one-time codes to a location only the operator can reach. Authentik's PostgreSQL-backed user
store has no such structural conflict. Full reasoning and evidence:
`docs/decisions/0002-identity-implementation.md`.

**Measured cost, updated from that decision's own reference figure:** `docs/decisions/0002`
measured a *reference* Authentik deployment (server, worker, PostgreSQL, Redis — four pods,
~1.1 GB) against Authelia. This directory's actual implementation is lighter: current Authentik
(`ghcr.io/goauthentik/server:2026.5.6`, confirmed by inspecting this chart's real
`Chart.yaml` dependencies) has **no Redis dependency at all**. Measured live via `kubectl top` on
the `detest` scratch cluster, three pods only: ~150 Mi (PostgreSQL) + ~430 Mi (server) + ~265 Mi
(worker) ≈ **850 Mi** at idle. Still real money — identity remains optional and gates a higher
hardware tier (`docs/supported/hardware-tiers.md`) — just not as much as originally measured.

## Non-negotiable requirement for this directory

**Everything required for SCRAP's supported identity behavior — Providers, Applications, groups,
scope mappings, policy bindings, flows — must be expressed as Authentik Blueprints, stored in Git,
reconciled by Flux.** No object required for normal operation may exist only by direct API call.

| Belongs to | Contains | Lifecycle |
|---|---|---|
| Configuration (Git, Blueprints) | Providers, Applications, groups, scope mappings, policy bindings | *recreated* |
| State (PostgreSQL, restic) | User accounts, passwords, enrolled TOTP/WebAuthn devices, sessions | *restored* |

This is not a preference; it is required for T2 to hold for OIDC applications, and for the recovery
model's "configuration is recreated, data is restored" principle to remain true. The reference
implementation never solved this — its Providers, Applications, and policy bindings existed only in
a database, created by direct API call. That is exactly what this directory must not repeat.
`blueprints-configmap.yaml` is the proof this actually works, not just a claim: live-verified end to
end (see below), the entries there create a real `scrap-users` group, a Proxy Provider, an
Application, and the outpost assignment that makes forward-auth (P3) actually functional.

## The contract this hands to applications

- **Native OIDC** (pattern P2): an OIDC issuer URL and a per-application client Secret.
  `components/ca-trust/` (its own milestone, landed right after this one) solves the private-CA
  workload-trust problem this needs — see that directory's README. Not yet wired into an
  `apps/examples/` demo; that's the next piece of work.
- **Forward-auth** (pattern P3): a shared gateway-level auth endpoint, consumed via
  `components/forward-auth/` — one filter reference on an `HTTPRoute`, nothing more. **Implemented
  and live-verified** (see below) — no CA-trust dependency, since the `Middleware` calls
  authentik's embedded outpost pod-to-pod, plain HTTP, never through the Gateway.

Both are the general identity contract (`docs/core/application-contract.md`), not Authentik-specific
— an extension implementation must satisfy the same two.

## Enabling this capability -- two files, not one

`capabilities/README.md` says enabling a capability is copying one Flux `Kustomization` file. For
any capability needing its own credential, that's one file short: the credential lives under
`clusters/<name>/secrets/`, never under `capabilities/`, so it stays out of what Topology B treats
as pinned, shared upstream content (`docs/decisions/0009-repository-topology.md`). Copy **both**
into `clusters/<name>/capabilities/`:

- `cluster-kustomization.yaml` → rename to `identity.yaml`. Installs this whole directory (the
  Authentik `HelmRelease`, its Blueprints, its `HTTPRoute`).
- `cluster-secrets-kustomization.yaml` → rename to `identity-secrets.yaml`. Installs
  `clusters/<name>/secrets/identity/` — the `authentik` `Namespace` and the `identity-credentials`
  `Secret`.

**Dependency direction, found live, the opposite of `platform-backup`/`platform-secrets`:**
`identity` `dependsOn` `identity-secrets`, not the other way around. `platform-backup`'s CronJob
pods only resolve their `secretKeyRef` when a pod actually runs, long after apply time, so it's
safe for the namespace-creating Kustomization to come first. Authentik's server/worker are a
`HelmRelease`-managed `Deployment` that starts **immediately** on install — reversing this produced
a real, reproducible `CreateContainerConfigError: secret "identity-credentials" not found`. See
`cluster-kustomization.yaml` and `clusters/example/secrets/identity/namespace.yaml`'s own comments.

## Non-interactive bootstrap

`AUTHENTIK_BOOTSTRAP_EMAIL` / `_PASSWORD` / `_TOKEN` (authentik's own documented mechanism, wired
here via `global.env` + `secretKeyRef` — see `helmrelease.yaml`) create the `akadmin` superuser on
first start with no setup wizard, no manual click-through. Verified live: authenticating against
`/api/v3/core/users/me/` with the bootstrap token returns `akadmin`, `is_superuser: true`,
immediately after a fresh install.

## Backup

The Postgres PVC is chart-generated (a Bitnami subchart, `postgresql.enabled: true`), not something
this repository authors directly — `components/backup/`'s label-patch mechanism only works inside a
Kustomize build, so the `backup.scrap.io/enabled` label and the two consistency annotations go
straight into `postgresql.primary.persistence.{labels,annotations}`, the extension point the chart
already exposes for exactly this (see `helmrelease.yaml`).

**Consistency method: `pg_dump`, not `pg_dumpall`, as the application's own database user, not
`postgres`.** Found live, in stages:

1. Bitnami's postgres image only ever exposes `POSTGRES_POSTGRES_PASSWORD_FILE` (a path to a
   mounted secret file) — never a plain `POSTGRES_POSTGRES_PASSWORD` env var, regardless of
   `existingSecret`. The first version of this command read the plain var (silently empty).
2. After fixing that: the `postgres` superuser's password still didn't authenticate over the
   network. Confirmed live that this image does not wire `postgres-password` into a
   network-authenticatable superuser login when a custom `auth.username` is configured — only the
   app user's own password (`POSTGRES_PASSWORD_FILE`) actually works.
3. Since this is a genuinely single-database deployment, a plain `pg_dump` as the `authentik` user
   against its own `authentik` database — which it fully owns — needs no superuser at all, and is
   the more correct scope besides. The dump is written to a sibling directory on the *same* PVC
   (`/bitnami/postgresql/scrap-backup/pg_dump.sql.gz`) so the single-PVC discovery model still
   captures it in the same `restic backup` as the raw (not restore-authoritative) data directory.

**Restoring a multi-tier application: quiesce the whole tier that talks to the database, not just
the database engine.** Found live, the hard way: restoring Postgres from a wiped state while
authentik's server and worker were still running let their own startup/migration logic race the
manual `psql` reload, corrupting Django's migration bookkeeping (`relation "..." already exists`,
worker `CrashLoopBackOff` afterward). Redone with server and worker *also* scaled to zero
throughout Postgres's restore, the reload completed cleanly (`psql -v ON_ERROR_STOP=1`, zero
errors) — full procedure and both attempts in `docs/runbooks/README.md`.

## Live validation, `detest` scratch cluster, 2026-08-17

- Fresh install (Helm chart + Blueprints ConfigMap) reaches all-Ready with no manual step.
- `akadmin` bootstrap confirmed via a real HTTPS API call through the platform's private CA (not
  `-k`).
- The declarative Blueprint applied successfully end to end: a real `scrap-users` group, a
  `scrap-forward-auth` Proxy Provider, its Application, and the outpost-provider assignment all
  exist as real database objects, created purely from the Git-committed YAML.
- `components/forward-auth/`'s `Middleware` target genuinely works: an unauthenticated request to
  the embedded outpost's forward-auth endpoint returns `302` to the real OAuth2 authorization
  endpoint — the correct "not logged in, redirect to sign in" behavior, not a 404 (the first
  attempt 404'd because a freshly-created Provider is not automatically attached to the embedded
  outpost — the Blueprint's `authentik_outposts.outpost` entry is what fixes that; see
  `blueprints-configmap.yaml`).
- A full destructive restore: a canary group created via the live API, backed up (`pg_dump`
  running as its consistency command), deleted via the API and confirmed gone, the Postgres PVC
  wiped, restored via `restic`, rebuilt from the dump with the whole app tier quiesced, and
  confirmed back — same name, same primary key — through the running application's own API.
- A real, previously-unknown bug in `platform/backup/`'s own discovery script, found by this
  milestone and fixed there (not worked around here): its field parser used a literal `|` as a
  delimiter, which broke the instant a real consistency command needed to *contain* a pipe
  (`pg_dump | gzip`). Fixed to use a tab, which no real shell command or label selector plausibly
  contains — see `platform/backup/scripts-configmap.yaml`.

## New assumptions this introduces

A PostgreSQL database to back up and restore (the same pattern already used for other stateful
applications, `platform/backup/`). ~850 Mi of additional memory, measured (see above) — the
identity hardware tier. No internet, no external account.

## What's not here yet

- **Native OIDC (P2)** and **forward-auth (P3)** wired into a real `apps/examples/` demo --
  `components/ca-trust/` (the P2 blocker) is done; both patterns are the next piece of work.
- **Adversarial auth-flow testing** (`docs/decisions/0002-identity-implementation.md`'s own stated
  obligation) — this milestone proved the declarative contract and the backup/restore contract;
  it did not attempt account-takeover or recovery-flow abuse scenarios.
- Metrics integration (`observability.scrap.io/scrape`) — not wired here; a reasonable, small
  follow-up, not attempted in this pass to keep scope bounded.
