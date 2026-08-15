# components/

Small, optional, reusable [Kustomize
components](https://kubectl.docs.kubernetes.io/guides/config_management/components/) that an
application includes to opt into a platform or capability contract. Each is a handful of lines of
plain Kustomize — no SCRAP-specific tooling, no code generation, nothing to learn beyond Kustomize
itself, consistent with the transparency principle in `docs/understanding-scrap.md`.

| Component | Adds | Depends on |
|---|---|---|
| [`backup/`](backup/) | The label + CronJob shape that opts a PVC into `platform/backup/`'s engine | `platform/backup/` |
| [`forward-auth/`](forward-auth/) | One `HTTPRoute` filter wiring an app to the gateway forward-auth endpoint | `capabilities/identity/`, when enabled |
| [`metrics/`](metrics/) | The pod label + port-name convention the core `PodMonitor` scrapes | `platform/observability/` |
| [`ca-trust/`](ca-trust/) | Injects the platform's private CA into a workload's own trust store, for apps making TLS calls *to* SCRAP endpoints | `platform/cert-manager/`, private-CA path only |

None of these are required. An application that needs none of them is still a complete, valid
application — see `apps/README.md`.
