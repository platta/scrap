# capabilities/public-tls/

**FULLY SUPPORTED.** Depends on `platform/cert-manager/` only.

Adds two `ClusterIssuer`s that get a real, publicly-trusted certificate from Let's Encrypt via
**ACME DNS-01** — the same wildcard shape `platform/cert-manager-config/`'s private CA already
produces (`*.${BASE_DOMAIN}` + `${BASE_DOMAIN}`), issued a different way. See
`docs/decisions/0006-tls-wildcard-and-issuer-independence.md` for why the wildcard shape is
identical either way, and `docs/core/recovery-model.md` for what this does and does not change
about recovery (nothing — TLS trust distribution has no recovery-model implications at all).

## What each real, upstream piece contributes

No SCRAP abstraction sits between you and any of this — `acme-issuers.yaml`'s own comment explains
each concept in place, but summarized here for a reader deciding whether to enable it:

- **cert-manager** — already installed by `platform/cert-manager/`. This capability adds objects
  for it to watch, not a second controller.
- **ACME** — the protocol Let's Encrypt speaks: prove you control a name, receive a certificate.
  cert-manager's `acme` issuer type is a native ACME client; nothing here re-implements it.
- **DNS-01** — the ACME challenge type that proves control by publishing a DNS `TXT` record, not by
  serving a file over HTTP. It's the only challenge type that can prove control of a **wildcard**
  name, which is why SCRAP uses it exclusively — HTTP-01 cannot issue wildcards at all.
- **The DNS provider** — whatever actually publishes that `TXT` record. cert-manager ships built-in
  integrations for roughly a dozen commercial providers plus a webhook extension point for the
  rest. This capability is wired for **RFC2136** (the generic DNS `UPDATE` protocol) instead of any
  one vendor's API — see `acme-issuers.yaml`'s own comment for why: it's the same "any
  S3-compatible endpoint, not AWS specifically" choice this project already makes for backup
  destinations, applied to DNS. Any RFC2136-capable authoritative nameserver works (BIND, PowerDNS,
  Knot, and several providers' own dynamic-DNS zone-update features) — swap the `solvers:` block
  for cert-manager's own provider-specific one if yours doesn't speak RFC2136; nothing else in this
  capability changes.
- **`ClusterIssuer`** — a cert-manager CRD, cluster-scoped so any namespace's `Certificate` can
  reference it. Exactly the same kind of object the private CA already is; this capability adds two
  more (`scrap-acme-staging`, `scrap-acme`), it doesn't introduce a new concept.
- **The wildcard `Certificate`** — `platform/ingress/wildcard-certificate.yaml`, the one Certificate
  object SCRAP ever issues for HTTP(S) apps. Enabling this capability does not create a second one;
  it gives that existing object a `ClusterIssuer` it *could* reference, selected by `${TLS_ISSUER}`.

## The issuer-independence contract, preserved exactly

`platform/ingress/wildcard-certificate.yaml`'s `issuerRef.name` is `${TLS_ISSUER}` — an
instance-config scalar, defaulting to `scrap-ca` in every checked-in instance. Enabling this
capability means setting it to `scrap-acme-staging` (validate DNS-01 first, against Let's Encrypt's
staging environment — untrusted certs, no meaningful rate limit) and then `scrap-acme` (production,
trusted, rate-limited) in your own `clusters/<name>/instance-config.yaml`. **That is the entire
change.** No file under `apps/` ever references an issuer at all
(`tests/assertions/check_no_cert_in_apps.py`), and `${TLS_ISSUER}` itself may never appear under
`apps/` either (`tests/assertions/check_tls_issuer_not_in_apps.py`) — together they're the executed
form of the frozen architecture's own CI obligation: swapping the issuer produces zero diff under
`apps/`.

**Design correction, found implementing this:** the original design language described this as "the
`scrap-ca` `ClusterIssuer` changes what it points to, same name, different backing implementation."
Building it that way would mean two separate Flux Kustomizations — the always-present
`platform-cert-manager-config` and this optional one — both continually reconciling an object with
the same name but different `spec`, fighting every reconcile interval. cert-manager has no problem
with multiple `ClusterIssuer`s coexisting under different names; that's the native mechanism, and
it's what `${TLS_ISSUER}` selects between instead.

## Enabling this capability — two files, not one

Same shape as `capabilities/identity/`'s: the credential lives under `clusters/<name>/secrets/`,
never under `capabilities/`. Copy both into `clusters/<name>/capabilities/`:

- `cluster-kustomization.yaml` → rename to `public-tls.yaml`. Installs the two `ClusterIssuer`s.
- `cluster-secrets-kustomization.yaml` → rename to `public-tls-secrets.yaml`. Installs
  `clusters/<name>/secrets/public-tls/` — the `public-tls-credentials` `Secret` (your RFC2136 TSIG
  key) into the existing `cert-manager` namespace.

Then, in your own `instance-config.yaml`:

- `TLS_ISSUER`: `scrap-acme-staging`, then `scrap-acme` once staging issuance is confirmed working.
- `ACME_EMAIL`: your real address — Let's Encrypt uses this for expiry/problem notifications.
- `ACME_DNS01_NAMESERVER`: your authoritative nameserver's address, `host:53`.
- `ACME_DNS01_TSIG_KEY_NAME`: the TSIG key name configured on that nameserver.

And replace the placeholder `TSIG_SECRET` value in `public-tls-credentials.sops.yaml` with your
real key's base64 secret (`cd clusters/<name>/secrets/public-tls && sops public-tls-credentials.sops.yaml`
— see `clusters/example/secrets/README.md` for the general pattern).

## Configuration errors fail visibly — verified, not assumed

If `${TLS_ISSUER}` names an issuer that doesn't exist, or the DNS-01 solver's credentials are
wrong, cert-manager does not silently keep issuing under the private CA and does not silently
"fall back" to anything — there is no SCRAP-authored fallback logic anywhere in this path at all.
Two things happen, both native cert-manager behavior: the wildcard `Certificate`'s `Ready`
condition becomes `False` with a specific, real reason (visible via `kubectl describe certificate
scrap-wildcard -n traefik`), and cert-manager creates a real `Order`/`Challenge` object recording
the actual DNS-01 attempt and its failure — not a generic error, the real one. Separately,
cert-manager's own renewal behavior means an *already-issued* certificate is never discarded before
its replacement succeeds — that's upstream availability-preserving behavior, not something this
capability adds or could disable.

This is exercised live, deliberately with a broken credential (no real domain or working DNS
required — see the next section) rather than assumed from reading cert-manager's docs.

## Acceptance evidence

Three distinct evidence levels, kept honestly separate — a green check at one level is never
represented as proving the next:

**1. Static/structural issuer-independence — every push and PR, no external dependency:**

- `tests/assertions/check_no_cert_in_apps.py` — unchanged, still proves no app ever declares TLS.
- `tests/assertions/check_tls_issuer_not_in_apps.py` — new: `${TLS_ISSUER}` itself never appears
  under `apps/`. Given Flux's `postBuild.substituteFrom` is a repository-wide token substitution,
  this is the precise, mechanical proof that swapping `TLS_ISSUER`'s value cannot possibly change
  anything rendered under `apps/` — there's no occurrence of the token there to substitute.
- `tests/dr/authentik-postgres-restore.sh` and `tests/profiles/t-a-minimal.sh`/`t-b-standard.sh`
  remain green, unmodified — the private-CA/minimal path is unaffected by this capability's
  existence.

**2. A real cert-manager ACME/DNS-01 attempt — every push and PR, no external domain or working DNS
required (`tests/profiles/t-a-public-tls.sh`):** a from-zero bootstrap with `TLS_ISSUER` swapped to
`scrap-acme-staging` and this capability enabled with a real, valid-format ACME contact email but
**deliberately wrong** RFC2136 nameserver credentials, proving: the two `ClusterIssuer`s are
capability-owned, never referenced by any application; the wildcard `Certificate`'s `issuerRef`
genuinely resolves to the ACME issuer (not silently staying on the private CA); a real ACME account
registers and a real `Order` object is created recording a genuine DNS-01 attempt against the
(deliberately unreachable) nameserver; the resulting failure is visible via the `Certificate`'s own
`Ready` condition with a specific, real reason, never silent; and — reverting `TLS_ISSUER` back to
`scrap-ca` in the same run — the private path recovers cleanly. **Does not, and cannot, prove a
certificate actually issues** — that needs a real, reachable DNS-01 solver, which is level 3.

**3. Actual public certificate issuance — requires a real domain and working DNS-01 credentials,
not CI-executed, operator-run** (`capabilities/public-tls/verify-live.sh`): the one claim that
genuinely cannot be tested without external infrastructure this project doesn't control and never
will. Confirms a real Let's Encrypt staging certificate actually issues, by reading the served
certificate's own issuer field. See that script's own header for exactly what it does and does not
prove, and run it against your own domain before relying on the production issuer.

## New assumptions this introduces

A registered domain, a public DNS zone for it, an RFC2136-capable authoritative nameserver (or a
swapped-in provider-specific solver) with a scoped TSIG credential, and internet access at
issuance/renewal time — roughly every 60 days. No inbound port, and **enabling this does not expose
anything to the internet** — that's the separate, later choice, `capabilities/public-ingress/`.
