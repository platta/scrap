# tests/profiles/

Dynamic, cluster-backed acceptance profiles — deliberately never testing only the fully-loaded
configuration, since the minimum is what most users start from and what's most likely to silently
rot.

| Profile | Trigger | Asserts | Status |
|---|---|---|---|
| **T-A — Minimal** | every push/PR to `main` | From-zero bootstrap; every `Kustomization` Ready; private CA issues a certificate; an example P1 application reachable over TLS; backup to local path; a destructive restore verified by a specific, named value; a test alert reaches the observability surface | **Implemented** — [`t-a-minimal.sh`](t-a-minimal.sh), run by [`.github/workflows/t-a-minimal.yml`](../../.github/workflows/t-a-minimal.yml) |
| **T-B — Standard** | every PR | T-A plus Grafana, logs, identity; P2/P3 auth flows; an adversarial auth test — an unauthenticated request must not reach a protected app, and any account-recovery flow must require real verification | Not yet implemented |
| **T-C — Connected** | nightly | Off-site backup; ACME issuance via DNS-01 against a real test zone; heartbeat delivery | Not yet implemented |
| **T-D — arm64 minimal** | nightly | T-A, on arm64 | Not yet implemented |
| **T-E — Host-loss rehearsal (R3)** | pre-release | Blank machine + only the artifacts the recovery model says survive → platform and data restored. Runs on plain QEMU/libvirt or a generic cloud VM — **never** a private cloud, so the procedure can't quietly depend on infrastructure most users don't have | Not yet implemented |
| **T-F — Upgrade** | pre-release | Previous release → current; data intact; rollback works | Not yet implemented |

T-B through T-F implementation tracked in the repository root `README.md` roadmap.

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
