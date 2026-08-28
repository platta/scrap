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

Every capability below is implemented and live-tested. Two are enabled a different way than the
rest, noted in the Enabling column — everything else is a plain Kustomization-file copy (see
[How enabling a capability actually works](#how-enabling-a-capability-actually-works) below).

| Capability | What you get | What it needs from you | Depends on / pairs with | Enabling |
|---|---|---|---|---|
| **Grafana** | Dashboards over the built-in metrics | Nothing beyond core (~250–400 MB RAM) | Standalone | Normal copy |
| **Identity** (Authentik) | Single sign-on: native OIDC for apps that support it, a gateway-level check for the ones that don't | ~1 GB RAM; a database it owns and backs up | Standalone. Unlocks the P2/P3 application patterns for other apps | Normal copy (2 files) |
| **Public TLS** (ACME/DNS-01) | Certificates every browser and phone already trusts, with no CA to install on client devices | A domain you control, a DNS zone, and a DNS provider that supports RFC2136 updates | Standalone. Commonly paired with public ingress | Normal copy (2 files) |
| **Off-site backup** | Recovery artifacts stored somewhere whose failure is independent of this machine — one of the two ingredients host-loss recovery needs | An S3-compatible endpoint and its credential | Standalone. Pairs with external Git hosting (below) for the *other* ingredient | Normal copy |
| **External Git hosting** | Moves your source of truth off this machine too — the other host-loss-recovery ingredient | A Git host account (GitHub, GitLab, your own server) | No capability file needed — it's a setting on the installer itself (`REPO_URL`) | Installer setting |
| **Logs** (Loki + Alloy) | Centralized, searchable pod logs, correlated with metrics | ~200–700 MB RAM | Standalone | Normal copy |
| **Alert delivery** | Alerts that actually reach you (webhook — ntfy, or anything Alertmanager itself supports), instead of only being visible if you go look | A reachable webhook receiver | Uses the core alerting surface, which already exists and evaluates rules — this just adds where alerts go | Normal copy (2 files) |
| **External heartbeat** | Told when the *cluster itself* is unreachable — the one failure no in-cluster alert can ever report | A free third-party dead-man's-switch account | Standalone | Normal copy (2 files) |
| **Dynamic DNS** | Keeps a DNS record pointed at your address even if it changes | A dynamic-DNS-capable domain/provider supporting RFC2136 | Commonly paired with public ingress, for installs without a static IP | Normal copy (2 files) |
| **Public ingress** | Reachable from the public internet, not just your LAN | A public IP with router control; a materially larger threat model — the most consequential new assumption in the whole envelope | Commonly paired with public TLS and dyndns (not required by either) | **Operator runbook — ships no manifest at all, by design** |
| **UPS integration** (NUT) | Graceful shutdown on power loss — real corruption protection for a single-disk machine | A UPS with a USB or network data connection to the host | Standalone | **Two halves: host script + normal in-cluster copy** |

See each capability's own README under `capabilities/<name>/` for the exact mechanics, and
[`docs/release-readiness.md`](release-readiness.md) for the authoritative, current evidence
snapshot behind this table (costs and evidence detail can change between releases; this page
won't be kept in sync line-by-line — that document is).

## Two capabilities that don't use a plain file copy

**Public ingress ships no Kustomization at all.** What actually makes the platform reachable from
the internet is entirely outside Kubernetes — your router's own NAT table — so there's no cluster
object to copy in. "Enabling" it means: review
`platform/ingress/reserved-ports.yaml`, forward TCP 443 (and optionally 80) from your router to
your node, and set up split-horizon DNS so LAN and internet clients resolving the same hostname
both reach the right address. "Disabling" it means removing the forwards. Nothing in the cluster
changes either way. Full runbook: `capabilities/public-ingress/README.md`.

**UPS integration has two independently-enabled halves.** The in-cluster half (a small exporter
that reads your UPS's status and wires it into the existing alerting surface) is a normal
Kustomization copy. The half that actually protects your data — the host daemon with authority to
shut the machine down — is a separate, operator-run script
(`bootstrap/host/install-nut.sh`) run directly on the host, because it manages a systemd service
outside anything Flux reconciles. Enabling the in-cluster half alone is meaningful (you get a
dashboard and alerts) but doesn't protect anything by itself — run both for a real install. Full
detail: `capabilities/ups/README.md`.

## Profiles are presets, not a hidden switch

You'll see three names used elsewhere in these docs — `minimal`, `standard`, `connected`. Each one
is nothing more than a **suggested, named bundle** of the capabilities above:

- **`minimal`** — nothing optional enabled. What `clusters/example/` ships as, and what this
  repository's own CI tests as the floor every install must work from.
- **`standard`** — adds Grafana, logs, and alert delivery. What most installs will actually run.
- **`connected`** — adds off-site backup, public TLS, and external heartbeat, plus external Git
  hosting (an installer setting, no capability file needed). What most installs converge to over
  time.

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

For every capability except the two called out above, enabling it means **copying its Flux
`Kustomization` file(s)** into `clusters/<your-instance>/capabilities/`. Disabling it is deleting
them. No flags, no templating language, no SCRAP-specific configuration format. Every enabled file
is a normal, reviewable Git diff.

Most capabilities are **one file**. A capability that needs its own credential (identity, public
TLS, alert delivery, heartbeat, dyndns, and UPS's in-cluster half) is **two files**: the
capability's own `Kustomization`, plus a second one that installs the credential's own
namespace/`Secret` from `clusters/<your-instance>/secrets/` — never from `capabilities/` itself, so
a real credential never ends up somewhere a separate pinned-version topology would treat as shared,
upstream content. Each capability's own README states exactly which files to copy and what to
rename them to — see `capabilities/identity/README.md`'s "Enabling this capability" section for the
concrete, fully worked example.

Full mechanical detail, including the two recorded exceptions above:
[`docs/core/configuration-model.md`](core/configuration-model.md).

## The configure-before-install checklist

If you want anything beyond the bare minimum, do this **before** running `bootstrap/install.sh`:

1. **Copy and rename your instance directory**, if you haven't already:
   `cp -r clusters/example clusters/<your-instance-name>`.
2. **Populate `instance-config.yaml`** with your real values — domain, node address, timezone,
   backup retention, and (only for the capabilities you're enabling) ACME/DNS-01, dyndns, or UPS
   settings. Every field is commented with what it's for.
3. **Copy in the Kustomization file(s)** for each capability you're enabling, from that
   capability's own directory into `clusters/<your-instance-name>/capabilities/` — see the table
   above for what's available, and that capability's own README for the exact filenames. Skip this
   step entirely for public ingress (no file exists to copy) and for UPS's host half (a script, not
   a file copy — see below).
4. **Create any required secret/config files** the enabled capabilities need, under
   `clusters/<your-instance-name>/secrets/` — for example, off-site backup's endpoint credential,
   or public TLS's DNS-01 TSIG key. Never put real credential material anywhere under
   `capabilities/` itself.
5. **Handle operator-run steps that live outside the cluster entirely**, at the point each
   capability's own documentation names — DNS provider setup for public TLS/dyndns, connecting a
   UPS and running `bootstrap/host/install-nut.sh` on the host, or the router/DNS runbook for
   public ingress. These are genuinely separate from steps 3–4 above: they change something outside
   Git, not a file inside it.
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
(**Topology B**) — no merging against upstream changes just to add an application, and a generator
(`bootstrap/generate-topology-b.sh`) that produces one for you, pinned to a specific SCRAP commit
or released tag. See [`docs/decisions/0009-repository-topology.md`](decisions/0009-repository-topology.md)
for the full mechanism.

## Where to go next

- **Install** — [Getting started](getting-started.md).
- **Add your first application** — [Adding an application](adding-an-application.md).
- **The full technical detail behind this table** — [`capabilities/README.md`](../capabilities/README.md)
  (contributor-facing) and [`docs/supported/README.md`](supported/README.md) (the same information,
  reader-facing).
