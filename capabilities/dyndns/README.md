# capabilities/dyndns/

**Architectural classification: FULLY SUPPORTED. Current implementation status: IMPLEMENTED,
LIVE-TESTED** — see `docs/release-readiness.md` and `tests/profiles/t-a-dyndns.sh`'s own
`T-A-dyndns/*` checks.

Has no dependency on any other capability or platform-tier namespace, exactly as designed — this is
the one capability in the envelope that ships its own `Namespace` (`namespace.yaml`) rather than
landing in a CORE one, because there's no always-present namespace it would otherwise make sense to
reuse. Purely outbound: this capability never opens an inbound port and makes no Kubernetes API call
of its own.

## The real mechanism

One `CronJob` (`cronjob.yaml`), every 10 minutes: look up this host's current public IP, and — only
if it genuinely changed since the record was last checked — send a real **RFC 2136** DNS `UPDATE`
pointing `DYNDNS_HOSTNAME`'s `A` record at it. This is the same generic DNS-update protocol
`capabilities/public-tls/` already uses for its own ACME DNS-01 solver — see that capability's own
README for why RFC2136 rather than one commercial provider's API: any RFC2136-capable authoritative
nameserver works (BIND, PowerDNS, Knot, or several providers' own dynamic-DNS zone-update features),
self-hosted or not. This capability's own TSIG credential is entirely independent of
`capabilities/public-tls/`'s — enabling one never requires the other, even though both happen to
speak the same wire protocol to (possibly) the same nameserver.

The IP-lookup step has its own, equally generic contract: `DYNDNS_IP_LOOKUP_URL` names any HTTP(S)
endpoint whose entire response body is a bare IPv4 address, nothing else — the same
"any endpoint satisfying the contract, not one vendor" genericity `capabilities/alert-delivery/README.md`
already establishes for its own webhook receiver, applied here to IP discovery. The default value
points at [ipify](https://www.ipify.org) (a free, dedicated, no-account-needed service built for
exactly this); any other endpoint returning the same bare-IPv4 shape (`icanhazip.com`,
`ifconfig.me/ip`, a self-hosted equivalent) is a drop-in swap, no other part of this capability
changes.

## Why the update is verified, not merely sent

`nsupdate` is not reliably non-zero on every failure mode a real deployment can hit — a `REFUSED`
response from a nameserver rejecting the TSIG key, in particular, is a case where some versions
print the failure but do not reliably propagate it to the process exit code. Trusting `nsupdate`'s
own exit status alone would risk exactly the class of silent-no-op this project has already found and
closed elsewhere (`capabilities/logs/`'s never-emitted-marker check, `capabilities/heartbeat/`'s
withheld-push negative control). Instead, `cronjob.yaml`'s own script re-queries the nameserver
directly, fresh, after sending the update, and only reports success if the authoritative answer it
gets back genuinely now matches the IP it just tried to set — the same "verified, not assumed"
standard `capabilities/public-tls/README.md`'s own "Configuration errors fail visibly" section holds
its own path to.

## Enabling this capability — two files, not one

Same shape as `capabilities/heartbeat/`'s and `capabilities/alert-delivery/`'s: the credential (the
TSIG key's own secret value) lives under `clusters/<name>/secrets/`, never under `capabilities/`.
Copy **both** into `clusters/<name>/capabilities/`:

- `cluster-kustomization.yaml` → rename to `dyndns.yaml`. Installs the `dyndns` namespace and the
  `scrap-dyndns` `CronJob`.
- `cluster-secrets-kustomization.yaml` → rename to `dyndns-secrets.yaml`. Installs
  `clusters/<name>/secrets/dyndns/` — the `dyndns-credentials` `Secret` (your `TSIG_SECRET`) into the
  `dyndns` namespace this capability's own main Kustomization creates. **The dependency between the
  two runs opposite to heartbeat's own pair** — see `cluster-secrets-kustomization.yaml`'s own
  comment for why: heartbeat's Secret lands in a namespace that already exists no matter what;
  this one doesn't.

Then, in your own `instance-config.yaml`:

- `DYNDNS_HOSTNAME`: the hostname whose `A` record should track your changing public IP. The common
  case is `${BASE_DOMAIN}` itself (the same name `capabilities/public-tls/` and
  `capabilities/public-ingress/` care about), but any hostname on a zone your nameserver serves works
  — this is a separate value, not derived from `BASE_DOMAIN`, exactly because scalars here are literal
  values, not templating (`docs/core/configuration-model.md`).
- `DYNDNS_NAMESERVER`: your authoritative nameserver's address, `host:53` — same shape as
  `ACME_DNS01_NAMESERVER`.
- `DYNDNS_TSIG_KEY_NAME`: the TSIG key name configured on that nameserver, authorized to update
  `DYNDNS_HOSTNAME`'s zone. Deliberately a **separate** key from `ACME_DNS01_TSIG_KEY_NAME` even if
  you point both capabilities at the same physical nameserver — narrower blast radius if one key
  needs to be rotated or revoked, and this capability's own "no dependency on `public-tls`" holds at
  the credential level too, not just the Kubernetes-object level.
- `DYNDNS_IP_LOOKUP_URL`: the default (ipify) works with no changes for most installs; override it if
  you'd rather self-host the lookup or use a different provider.

And replace the placeholder `TSIG_SECRET` value in `dyndns-credentials.sops.yaml` with your real key's
base64 secret (`cd clusters/<name>/secrets/dyndns && sops dyndns-credentials.sops.yaml` — see
`clusters/example/secrets/README.md` for the general re-encrypt-on-save pattern).

## Configuration errors fail visibly — verified, not assumed

A malformed `DYNDNS_IP_LOOKUP_URL` response, a wrong TSIG key/secret, or an unreachable nameserver all
produce a genuinely failing `Job` (`kubectl get jobs -n dyndns`) — never a silent no-op. There is no
SCRAP-authored fallback or retry-and-ignore logic in this path; the confirmation query described
above is what makes "the Job succeeded" and "the record actually changed" the same claim.

## Acceptance evidence

Two distinct evidence levels, kept honestly separate:

**1. Static/structural — every push and PR, no external dependency:** the `CronJob` and its own
`dyndns` `Namespace` render, owned by this capability's own Kustomization (T1: absent from a
`minimal`-profile cluster), and the job makes no Kubernetes API call of its own
(`automountServiceAccountToken: false`, verified structurally).

**2. A real RFC2136 update, against an ephemeral authoritative nameserver this project stands up
itself — every push and PR, no external domain or provider account
(`tests/profiles/t-a-dyndns.sh`):** a from-zero bootstrap with this capability enabled,
`DYNDNS_NAMESERVER` and `DYNDNS_TSIG_KEY_NAME` pointed at a real, disposable BIND9 instance the test
script runs on the same runner (reached in-cluster the same way `t-a-alert-heartbeat.sh`'s own
ephemeral receiver already is), and `DYNDNS_IP_LOOKUP_URL` pointed at a real, disposable HTTP
listener the test script also runs itself, returning a controlled IP. Unlike
`capabilities/public-tls/`'s own live test — which is structurally bounded to the `Order` stage
because reaching a real DNS-01 `Challenge` needs a real public domain — this capability's entire
mechanism is provable in CI without any external service at all, because RFC2136 update traffic never
needs to reach a specific, mandatory third party the way ACME needs Let's Encrypt: **both directions
are proven, not just the happy path:**

- **Positive:** a manually triggered run of the `CronJob`, with the ephemeral nameserver correctly
  configured, genuinely updates the `A` record — confirmed by an independent `dig` query the test
  script issues itself against the nameserver directly, not inferred from the `Job`'s own exit status
  alone.
- **Negative control:** a fresh triggered run with a deliberately wrong TSIG secret produces a
  genuinely failing `Job`, and the record is confirmed **unchanged** at the nameserver — proving the
  failure is real and visible, not silently swallowed.
- **Unchanged-IP path:** a second triggered run with nothing changed since the previous successful
  update makes no update attempt at all (confirmed via the nameserver's own serial/answer being
  untouched), proving the "only send an update if the IP actually changed" logic is genuine, not
  merely documented.

**Honest limit of this level:** it proves the RFC2136 mechanism itself against a real nameserver
using the real wire protocol; it does not and cannot prove that any one specific commercial DNS
provider's own dynamic-update feature is compatible in practice, nor that public DNS resolvers
elsewhere on the internet have picked up a change (ordinary DNS propagation, governed by the
record's own TTL, not something this capability controls or needs to prove).

## New assumptions this introduces

A dynamic-DNS-capable domain/provider (or a self-hosted RFC2136-capable nameserver) and internet
access. No cloud spend required, no meaningful memory footprint — one `CronJob`, no persistent
workload. No inbound exposure by itself.
