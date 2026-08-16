# Architecture decision records

The authoritative history of *why* SCRAP is shaped the way it is — including alternatives that were
considered and rejected. If a later contributor wants to revisit one of these, start by reading why
it was decided this way; a frozen decision is reopened only when empirical implementation evidence
demonstrates it's impossible or materially incorrect, not because another approach merely looks
attractive.

| # | Decision | Outcome |
|---|---|---|
| [0001](0001-name-license.md) | Project name and license | SCRAP · Apache-2.0 |
| [0002](0002-identity-implementation.md) | Identity implementation | Authentik fully supported, Authelia an extension |
| [0003](0003-backup-job-generation.md) | Backup job generation mechanism | A Kustomize component, not a controller |
| [0004](0004-instance-configuration.md) | Instance configuration mechanism | Flux `postBuild.substituteFrom` |
| [0005](0005-minimum-git-remote.md) | Minimum Git remote requirement | A local bare repository is sufficient |
| [0006](0006-tls-wildcard-and-issuer-independence.md) | TLS certificate model | One wildcard certificate, issuer-independent applications |
| [0007](0007-reject-sealed-secrets.md) | Secrets mechanism | SOPS + age; Sealed Secrets explicitly rejected |
| [0008](0008-abstract-decisions-not-technologies.md) | Transparency principle | No plugin system, no proprietary manifest, no hidden control plane |
| [0009](0009-repository-topology.md) | Repository topology | Fork/clone (monorepo) or a separate operator repo pinned to an upstream release — both native Flux multi-source, no fork required to configure an install |
| [0010](0010-backup-credential-isolation.md) | Backup credential isolation | An authorization boundary (`--host`, per-instance credentials), not a naming convention |

## Format

Each record states: the question, the decision, the evidence or reasoning, and — where relevant —
what was rejected and why. Not every record follows a rigid template; the goal is a reader
understanding the *why*, not filling in headings.
