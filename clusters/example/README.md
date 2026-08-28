# clusters/example/

The reference SCRAP instance. Currently the `minimal` profile: `capabilities/` is empty, so no
optional capability is enabled — only `platform/` (once implemented) reconciles.

To start a real installation: copy this entire directory, rename it, and replace every value in
`instance-config.yaml` with your own. To move to the `standard` profile, copy in the
`Kustomization` files for `grafana`, `logs`, and any others you want from `capabilities/*/` into
`capabilities/` here — see `docs/core/configuration-model.md`.

New to SCRAP? [`docs/getting-started.md`](../../docs/getting-started.md) walks through this step
in context, and [`docs/choosing-capabilities.md`](../../docs/choosing-capabilities.md) is a
checklist for deciding what to enable before you run the installer.
