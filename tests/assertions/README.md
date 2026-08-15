# tests/assertions/

Fast, static, structural CI checks — run on every pull request, no cluster required. Each is a
small, single-purpose, dependency-light Python script (standard library + PyYAML only) that reads
manifests as text/YAML and reports violations. No pytest, no framework — readable by anyone who
already knows Kubernetes YAML, consistent with
[`docs/decisions/0008-abstract-decisions-not-technologies.md`](../../docs/decisions/0008-abstract-decisions-not-technologies.md).

## Running locally

```
python3 -m pip install pyyaml
bash tests/assertions/run_all.sh          # every check against the real repository
python3 tests/assertions/self_test.py     # proves each check catches its fixture violation
```

## What each check encodes

| Script | Encodes |
|---|---|
| `check_core_boundary.py` | `platform/` never references `capabilities/` or `apps/`; `capabilities/` never references `apps/`; no Flux `Kustomization` `dependsOn` points from a lower tier to a higher one |
| `check_app_addition_boundary.py` | T2 as a diff rule — a pull request touching `apps/` may not also touch `platform/` or `capabilities/` |
| `check_image_pinning.py` | No floating `:latest` tags, no bare (implicitly-latest) image references |
| `check_no_cert_in_apps.py` | No `Certificate` or `ClusterIssuer` object, and no `issuerRef`, exists under `apps/` |
| `check_reserved_ports.py` | Every `LoadBalancer` port and container `hostPort` is declared in `platform/ingress/reserved-ports.yaml` |
| `check_instance_literals.py` | Every `${VAR}` resolves to a defined `clusters/*/instance-config.yaml` key; no literal IPv4 address appears outside `clusters/` |
| `check_kustomization_dag.py` | The Flux `Kustomization` dependency graph is acyclic; no `Certificate` names an `issuerRef` that isn't guaranteed to exist by the dependency graph |
| `check_helm_strict.py` | Every `HelmRelease`'s inline values render cleanly under `helm template --strict` |

## Why each check has a fixture

`tests/fixtures/violations/` holds a minimal, deliberately-broken repository tree per check.
`self_test.py` runs each check against its fixture and asserts it *fails*, then against the real
repository and asserts it *passes*. A check that has never been proven to fire on a real violation
isn't a guardrail — it's an assertion nobody has verified asserts anything. Every check added here
should ship with a fixture in the same pull request.

## Adding a new structural assertion

1. Write `check_<name>.py` with a `run(root: Path) -> list[str]` function (violations, empty =
   pass) and a `__main__` block that runs it against `find_repo_root()` and exits non-zero on
   failure — copy the shape of an existing check.
2. Add a fixture under `tests/fixtures/violations/<name>/` that deliberately violates the rule.
3. Register both in `run_all.sh` and `self_test.py`.
4. Update this table.
