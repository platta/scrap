# Choosing your capabilities

*Read this before you run the installer if you want anything beyond the bare minimum — off-site
backup, single sign-on, publicly-trusted certificates, and so on. If you're happy with the minimum
for now, skip straight to [Getting started](getting-started.md); every capability here stays
addable later without touching anything you've already deployed.*

## The always-on core, in one sentence

Every SCRAP install includes Kubernetes itself, GitOps reconciliation, encrypted secrets, storage,
routing and TLS (via a private certificate authority SCRAP generates for you — no domain needed),
a backup engine, and metrics/alerting. That's it running with **nothing** optional enabled: no
public IP, no domain, no cloud account, no S3, no identity provider, no SMTP. See
[Understanding SCRAP](understanding-scrap.md) if you want the full layer-by-layer reasoning for why
each of those is mandatory rather than optional.

Everything below this line is opt-in. **T1**, one of the two rules that hold everywhere in this
repository, means exactly that: delete every optional capability and every application, and a
complete, useful platform remains.

## What's optional, what it costs, what it needs from you

| Capability | What you get | What it needs from you | Depends on / pairs with | Status |
|---|---|---|---|---|
| **Grafana** | Dashboards over the built-in metrics | Nothing beyond core (~250–400 MB RAM) | Standalone | ✅ Enable today |
| **Identity** (Authentik) | Single sign-on: native OIDC for apps that support it, a gateway-level check for the ones that don't | ~1 GB RAM; a database it owns and backs up | Standalone. Unlocks the P2/P3 application patterns for other apps | ✅ Enable today |
| **Public TLS** (ACME/DNS-01) | Certificates every browser and phone already trusts, with no CA to install on client devices | A domain you control, a DNS zone, and a DNS provider that supports programmatic updates | Standalone. Commonly paired with public ingress once that exists | ✅ Enable today |
| **Off-site backup** | Recovery artifacts stored somewhere whose failure is independent of this machine — one of the two ingredients host-loss recovery needs | An S3-compatible endpoint and its credential | Standalone. Pairs with external Git hosting (see below) for the *other* ingredient | ✅ Enable today |
| **External Git hosting** | Moves your source of truth off this machine too — the other host-loss-recovery ingredient | A Git host account (GitHub, GitLab, your own server) | No capability file needed — it's a setting on the installer itself (`REPO_URL`) | ✅ Enable today |
| **Logs** (Loki + Alloy) | Centralized, searchable pod logs, correlated with metrics | ~300 MB RAM once built | Standalone | 🧭 Designed, not yet implemented |
| **Alert delivery** | Alerts that actually reach you, instead of only being visible if you go look | A reachable SMTP server, ntfy endpoint, or webhook | Uses the core alerting surface, which already exists and evaluates rules — this just adds where alerts go | 🧭 Designed, not yet implemented |
| **Public ingress** | Reachable from the public internet, not just your LAN | A public IP with router control, or a tunnel provider account; a materially larger threat model | Commonly paired with public TLS (not required by it) | 🧭 Designed, not yet implemented |
| **External heartbeat** | Told when the *cluster itself* is unreachable — the one failure no in-cluster alert can ever report | A free third-party dead-man's-switch account | Standalone | 🧭 Designed, not yet implemented |
| **Dynamic DNS** | Keeps a DNS record pointed at your address even if it changes | A dynamic-DNS-capable domain/provider | Commonly paired with public ingress | 🧭 Designed, not yet implemented |
| **UPS integration** (NUT) | Graceful shutdown on power loss — real corruption protection for a single-disk machine | A UPS with a USB or network data connection to the host | Standalone | 🧭 Designed, not yet implemented |

✅ means there's a real, tested mechanism you can enable today. 🧭 means the design and documentation
exist but there's no manifest to enable yet — see each capability's own README under
`capabilities/<name>/` for exactly what "not yet implemented" covers, and
[`docs/release-readiness.md`](release-readiness.md) for the authoritative, current snapshot behind
this table (costs, evidence, and status can change between releases; this page won't be kept in
sync line-by-line — that document is).

## Profiles are presets, not a hidden switch

You'll see three names used elsewhere in these docs — `minimal`, `standard`, `connected`. Each one
is nothing more than a **suggested, named bundle** of the capabilities above:

- **`minimal`** — nothing optional enabled. What `clusters/example/` ships as, and what this
  repository's own CI tests as the floor every install must work from.
- **`standard`** — adds Grafana today (and, once built, logs and alert delivery). What most
  installs will actually run.
- **`connected`** — adds off-site backup, public TLS, and external Git hosting today (and, once
  built, external heartbeat). What most installs converge to over time.

**There is no `profile: standard` setting anywhere in this repository.** A profile is just
documentation for a combination people commonly choose. You are never limited to these three
combinations — see the worked example below.

## Yes, you can mix and match

Say you want the core, plus Grafana, plus off-site backup — but you specifically do **not** want
identity or public ingress. That's a completely ordinary, fully-supported configuration; nothing
about "standard" or "connected" as bundles applies here. You'd enable exactly two things (Grafana,
off-site backup) and leave everything else off. Enabling a capability never implies enabling any
other — the only real dependency to watch for is the P2/P3 application patterns, which need
identity specifically; capabilities themselves don't chain into each other beyond what's called out
in the "Depends on / pairs with" column above.

## How enabling a capability actually works

A capability is enabled by **copying its Flux `Kustomization` file(s)** into
`clusters/<your-instance>/capabilities/`. Disabling it is deleting them. That's the entire
mechanism — no flags, no templating language, no SCRAP-specific configuration format. Every
enabled file is a normal, reviewable Git diff.

Most capabilities are **one file**. A capability that needs its own credential (identity is the
concrete example today) is **two files**: the capability's own `Kustomization`, plus a second one
that installs the credential's own namespace/`Secret` from `clusters/<your-instance>/secrets/` —
never from `capabilities/` itself, so a real credential never ends up somewhere a separate
pinned-version topology would treat as shared, upstream content. Each capability's own README
states exactly which files to copy and what to rename them to — see
`capabilities/identity/README.md`'s "Enabling this capability" section for the concrete, fully
worked example.

Full mechanical detail: [`docs/core/configuration-model.md`](core/configuration-model.md).

## The configure-before-install checklist

If you want anything beyond the bare minimum, do this **before** running `bootstrap/install.sh`:

1. **Copy and rename your instance directory**, if you haven't already:
   `cp -r clusters/example clusters/<your-instance-name>`.
2. **Populate `instance-config.yaml`** with your real values — domain, node address, timezone,
   backup retention, and (only if the corresponding capability is enabled) ACME email and DNS-01
   nameserver/key name. Every field is commented with what it's for.
3. **Copy in the Kustomization file(s)** for each capability you're enabling, from that
   capability's own directory into `clusters/<your-instance-name>/capabilities/` — see the table
   above for which capabilities exist to enable, and that capability's own README for the exact
   filenames.
4. **Create any required secret/config files** the enabled capabilities need, under
   `clusters/<your-instance-name>/secrets/` — for example, off-site backup's endpoint credential,
   or public TLS's DNS-01 TSIG key. Never put real credential material anywhere under
   `capabilities/` itself.
5. **Handle operator-run steps that live outside the cluster entirely**, at the point each
   capability's own documentation names — for example, DNS provider setup for public TLS. A
   capability marked 🧭 "designed, not yet implemented" above has no such step yet, because there's
   nothing to configure until it ships; its README states this plainly.
6. **Re-check preflight** (`bootstrap/preflight/run-all.sh`, or just let `bootstrap/install.sh` run
   it for you) before installing — it validates your host, not your configuration values, so a
   passing preflight doesn't mean your `instance-config.yaml` values are correct, only that the
   machine itself is ready.

Once that's done, proceed to [Getting started, step 4](getting-started.md#4-install).

## One more option: a separate operator repository

Everything above assumes you're working inside a clone of this repository (**Topology A**) — the
simplest path, and what this repository's own tests exercise. If you'd rather not fork/clone the
whole thing, SCRAP also supports a **separate repository** containing only your `clusters/`,
`apps/`, and `secrets/`, pinned to a specific released version of everything else
(**Topology B**) — no merging against upstream changes just to add an application. See
[`docs/decisions/0009-repository-topology.md`](decisions/0009-repository-topology.md) for the full
mechanism; it's a one-line change per file (`sourceRef.name`), not a different configuration model.

## Where to go next

- **Install** — [Getting started](getting-started.md).
- **Add your first application** — [Adding an application](adding-an-application.md).
- **The full technical detail behind this table** — [`capabilities/README.md`](../capabilities/README.md)
  (contributor-facing) and [`docs/supported/README.md`](supported/README.md) (the same information,
  reader-facing).
