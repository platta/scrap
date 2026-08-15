# 0004 — Instance configuration mechanism

**Decision:** instance values are resolved via Flux's built-in **`postBuild.substituteFrom`**, not
Kustomize overlays and not a new templating layer.

## Reasoning

`substituteFrom` is Flux-native — no new tooling to learn, no additional build step, and it keeps
the "instance values live in exactly one place" property (`docs/core/configuration-model.md`)
trivially true: a value is a `${VAR}` reference resolved from a `ConfigMap`/`Secret` under
`clusters/<name>/`, full stop.

Kustomize overlays were considered and rejected for this specific purpose: they're the right tool
for structural variation between environments, not for scalar value substitution, and using them
for both would blur a distinction worth keeping — this repository doesn't have "dev vs prod"
variants of `platform/`, it has one platform and many instance value sets.

## The cost, and how it's covered

`substituteFrom`'s failure mode is silent: an undefined `${VAR}` is left as a literal string in the
applied manifest rather than causing an error a human notices immediately. This is why
`tests/assertions/` includes a static check that every `${VAR}` referenced anywhere resolves to a
defined instance-config key — the cost is real, and it's covered by CI, not by operator discipline.
