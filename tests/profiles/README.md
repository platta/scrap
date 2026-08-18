# tests/profiles/

Dynamic, cluster-backed acceptance profiles — deliberately never testing only the fully-loaded
configuration, since the minimum is what most users start from and what's most likely to silently
rot.

| Profile | Trigger | Asserts | Status |
|---|---|---|---|
| **T-A — Minimal** | every push/PR to `main` | From-zero bootstrap; every `Kustomization` Ready; private CA issues a certificate; P1 reachable over TLS; P4's raw TCP byte stream round-trips through the LoadBalancer Service; P6 proxies through to a real external backend's actual content; backup to local path; a destructive restore verified by a specific, named value; a test alert reaches the observability surface | **Implemented** — [`t-a-minimal.sh`](t-a-minimal.sh), run by [`.github/workflows/t-a-minimal.yml`](../../.github/workflows/t-a-minimal.yml) |
| **T-B — Standard** | every PR | Identity enabled; P2 (native OIDC) proven with a real, scripted login through authentik's own flow-executor API, ending on the app's own redirect_uri with real ID token claims; P3 (forward-auth) proven both ways — an unauthenticated request never reaches the app (adversarial), and after a real login the app is reachable with `X-Authentik-*` headers visible, added by the Middleware, never by the app | **Partially implemented** — [`t-b-standard.sh`](t-b-standard.sh), run by [`.github/workflows/t-b-standard.yml`](../../.github/workflows/t-b-standard.yml). Covers identity + P2 + P3 + the adversarial check only; Grafana, logs, and a recovery-flow-abuse test (the original design's other T-B claims) are still open |
| **T-C — Connected** | nightly | Off-site backup; ACME issuance via DNS-01 against a real test zone; heartbeat delivery | Not yet implemented |
| **T-D — arm64 minimal** | nightly | T-A, on arm64 | Not yet implemented |
| **T-E — Host-loss rehearsal (R3)** | pre-release | Blank machine + only the artifacts the recovery model says survive → platform and data restored. Runs on plain QEMU/libvirt or a generic cloud VM — **never** a private cloud, so the procedure can't quietly depend on infrastructure most users don't have | Not yet implemented |
| **T-F — Upgrade** | pre-release | Previous release → current; data intact; rollback works | Not yet implemented |

The rest of T-B (Grafana, logs, a recovery-flow-abuse test) and T-C through T-F are tracked in the
repository root `README.md` roadmap.

## `tests/profiles/lib.sh` -- what's actually shared

`ok`/`fail`/`log` output shape, the instance-config reader, prerequisite installation, a
`kubectl`-under-`sudo` shorthand, and the create-Job/poll-for-terminal-state pattern -- genuinely
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
