# 0008 — SCRAP abstracts decisions, not technologies

**Decision:** SCRAP is deliberately not an attempt to hide Kubernetes, or any of the tools it
composes, from the operator. It removes the burden of *deciding*, *composing*, *validating*, and
*proving recoverable* — never the burden of *understanding*.

## What this rules out, explicitly

- **No plugin system.** Kubernetes and Flux already provide every extension boundary this project
  needs (`docs/extensions/`). Building a SCRAP-specific plugin API on top would add indirection
  purely to make a diagram look extensible.
- **No proprietary application manifest.** Applications are ordinary Kubernetes manifests under
  `apps/`. There is no SCRAP CRD standing between an operator and their own workload.
- **No SCRAP control plane to reverse-engineer.** Troubleshooting is `kubectl`, `flux`, and each
  upstream project's own tooling and documentation. If a SCRAP-specific abstraction would ever
  obscure a real failure, that's the wrong abstraction, full stop — not a tradeoff to accept.
- **No re-wrapping of a native contract that already expresses the intent.** A `ClusterIssuer`, a
  `StorageClass`, a `PodMonitor`, an `HTTPRoute` — these *are* SCRAP's contracts. They are not
  wrapped in a SCRAP-specific equivalent anywhere in this repository.

## What this project provides instead

Opinionated defaults, a paved path, composition of real tools, validation (CI structural
assertions, `tests/assertions/`), automation (`bootstrap/`), tested recovery guarantees
(`docs/core/recovery-model.md`), documentation that names the real component behind every
capability and links to its own docs, and clearly marked extension boundaries
(`docs/extensions/`) for when the paved path isn't the right fit.

## The test

*If SCRAP disappeared tomorrow, would the operator still hold an understandable, standards-based
Kubernetes platform made of maintained upstream components?*

The answer must be yes. Ease comes from good defaults, guidance, validation, and automation —
**never from concealment.** This is why `components/` are a handful of lines of plain Kustomize
instead of a generator, why `docs/understanding-scrap.md` exists and is meant to be read early
rather than skipped, and why every capability's documentation names the real upstream project
behind it before saying anything else.
