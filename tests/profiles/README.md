# tests/profiles/

Dynamic, cluster-backed acceptance profiles — deliberately never testing only the fully-loaded
configuration, since the minimum is what most users start from and what's most likely to silently
rot.

| Profile | Trigger | Asserts | Status |
|---|---|---|---|
| **T-A — Minimal** | every push/PR to `main` | From-zero bootstrap; every `Kustomization` Ready; private CA issues a certificate; P1 reachable over TLS; P4's raw TCP byte stream round-trips through the LoadBalancer Service; P6 proxies through to a real external backend's actual content; backup to local path; a destructive restore of P5's Redis -- the canary is genuinely deleted (app-level `DEL` *and* the on-disk RDB file removed) and both confirmed gone before `restic restore` runs, closing a real gap this project's own DR-acceptance audit found: earlier runs never destroyed anything before "restoring", so a silently no-op restore could have passed; a test alert reaches the observability surface | **Implemented** — [`t-a-minimal.sh`](t-a-minimal.sh), run by [`.github/workflows/t-a-minimal.yml`](../../.github/workflows/t-a-minimal.yml) |
| **T-B — Standard** | every PR | Identity enabled via the exact documented capability-file copy (a genuinely separate from-zero bootstrap from T-A's, never a mutation of it -- T-A's own cluster stays identity-free throughout); every Kustomization Ready, including identity's and Grafana's; `components/ca-trust/`'s wiring checked directly and attributably for both P2 and Grafana (`SSL_CERT_FILE` + the platform's real CA genuinely present in the mounted bundle); P2 (native OIDC) proven with a real, scripted login through authentik's own flow-executor API -- identification, password, and a genuine authorization-code exchange the app itself performs, ending with real ID token claims tied to the exact user logged in (`preferred_username=akadmin`, not just "some claims present"); P3 (forward-auth) proven both ways -- an unauthenticated request is confirmed redirected specifically to `auth.${BASE_DOMAIN}` AND confirmed never to leak the protected app's own response body (not inferred from status/redirect alone), and after a real login the app is reachable with `X-Authentik-*` headers visible, added by the Middleware, never by the app; **Grafana** proven both as a capability (T1 -- owned by its own Kustomization, absent from T-A) and behaviorally: its Prometheus datasource genuinely returns live time series through Grafana's own query API (not just that the datasource object exists), a real OIDC login through the SAME flow-executor mechanism ends with Grafana's own `/api/user`/`/api/user/orgs` recognizing the exact user AND applying the expected `Admin` role via the `scrap-admins` group's declarative `groups` claim, and an unauthenticated request to a real API endpoint is rejected (401), not silently served | **Implemented** for identity + P2 + P3 + Grafana + the adversarial checks — [`t-b-standard.sh`](t-b-standard.sh), run by [`.github/workflows/t-b-standard.yml`](../../.github/workflows/t-b-standard.yml). Logs and a recovery-flow-abuse test (the original design's other T-B claims) are still open -- logs is an unimplemented *capability*, not a T-B gap; the recovery-flow-abuse test is identity's own still-open obligation |
| **T-A-public-tls** | every push/PR to `main` | `capabilities/public-tls/` enabled live against an already-bootstrapped cluster (a genuinely separate from-zero bootstrap of its own, not a mutation of T-A's); the two ACME `ClusterIssuer`s are capability-owned; the wildcard `Certificate`'s `issuerRef` genuinely swaps to the new issuer via `${TLS_ISSUER}`; with deliberately-wrong DNS-01 credentials (no real domain needed), a real ACME account registers and cert-manager reaches the real `Order` stage — a genuine network round-trip to Let's Encrypt's own server, confirmed by reading the `Order` object itself — then fails visibly, `Ready=False` with a real reason, never silently; the already-served certificate is preserved (cert-manager's own upstream behavior); reverting `TLS_ISSUER` recovers cleanly | **Implemented** — [`t-a-public-tls.sh`](t-a-public-tls.sh), run by [`.github/workflows/t-a-public-tls.yml`](../../.github/workflows/t-a-public-tls.yml). Reaching the DNS-01 solver itself (not just the `Order` stage) and a certificate genuinely issuing both need a real public domain — `capabilities/public-tls/verify-live.sh`, operator-run, not CI-executed |
| **T-C — Connected** | nightly | Off-site backup; ACME issuance via DNS-01 against a real test zone; heartbeat delivery | Not yet implemented |
| **T-D — arm64 minimal** | nightly | T-A, on arm64 | Not yet implemented |
| **T-E — Host-loss rehearsal (R3)** | pre-release | Blank machine + only the artifacts the recovery model says survive → platform and data restored. Runs on plain QEMU/libvirt or a generic cloud VM — **never** a private cloud, so the procedure can't quietly depend on infrastructure most users don't have | Not yet implemented |
| **T-F — Upgrade** | pre-release | Previous release → current; data intact; rollback works | Not yet implemented |

The rest of T-B (Grafana, logs, a recovery-flow-abuse test) and T-C through T-F are tracked in the
repository root `README.md` roadmap.

## `tests/profiles/lib.sh` -- what's actually shared

`ok`/`fail`/`log` output shape, the instance-config reader, prerequisite installation, an
unprivileged `kubectl` shorthand (`setup_kubeconfig()` + `kc()` -- deliberately not run as root; see
`kc()`'s own comment in `lib.sh` for the investigation that found running it under `sudo` was itself
the cause of a real, previously-flaky T-A postcondition), and the create-Job/poll-for-terminal-state
pattern -- genuinely
needed by more than one profile script, so factored out once. What each profile is actually
proving stays in that profile's own script: `t-b-standard.sh`'s `authentik_login()` helper, for
example, is shared between its own P2 and P3 checks but deliberately isn't in `lib.sh` -- no other
profile touches identity, and promoting it would mean every profile's author has to understand
Authentik's flow-executor JSON contract to read the shared library.

**One deliberate wording change from the original design, found implementing T-A:** the destructive
restore is verified via `kubectl exec` into the original application pod (P5's Redis,
`docs/runbooks/README.md`'s own proven procedure), not "through the real ingress path" as first
written here. No pattern this project ships exposes stateful application data over HTTP for a
restore check to read through the Gateway — inventing one just to satisfy that phrasing would test
something no real application does. Verifying through the application's own interface, the same way
every manual restore this project has ever performed did, is the more honest check.

## A gap this design already found, before T-A existed -- now checked by it

Validating `platform/ingress/`, `tests/assertions/check_helm_strict.py` was found to genuinely be
unable to catch the reference implementation's own historical bug — a HelmRelease value set at the
wrong path (`service.type` instead of the chart's actual `service.spec.type`), silently ignored,
`helm template` exiting 0. Reproduced directly against a current chart version, not assumed.

Static Helm validation cannot generically prove an override reached the field it was meant to.
`t-a-minimal.sh` includes exactly the live check this called for:
`kubectl get svc -n traefik traefik -o jsonpath='{.spec.type}'` actually equals `LoadBalancer`, not
merely that Helm accepted the values without error.
