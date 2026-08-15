# 0005 — Minimum Git remote requirement

**Decision:** a **local bare Git repository** (on the SCRAP host itself, or another LAN machine) is
sufficient for the minimum profile. External Git hosting (GitHub, GitLab, a self-hosted Forgejo
instance) is a fully supported, optional capability, not a requirement of the core.

## Reasoning

Requiring a hosted Git account in the minimum profile would import an account, a network
dependency, and a third party into a platform whose entire pitch is running with as few external
prerequisites as honestly possible. GitOps needs *a* Git remote — it does not need *GitHub*
specifically. `git init --bare` on the same host, or a second LAN machine, satisfies Flux's
`GitRepository` source completely.

## The recovery cost of the minimum choice, stated plainly

A local bare repository does not survive host loss. **R3 (host-loss recovery) is explicitly not
claimed** until Git lives somewhere that survives the host dying — either external hosting or a
repository mirrored to a second machine (`docs/core/recovery-model.md`). This is the honest
trade-off the minimum profile makes, stated rather than glossed over: a smaller footprint of
external dependencies, in exchange for a recovery guarantee that only applies once you've added
one back.
