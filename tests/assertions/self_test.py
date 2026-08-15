#!/usr/bin/env python3
"""
Proves the structural assertions actually catch what they claim to catch.

Runs each check against a deliberately-violating fixture under
tests/fixtures/violations/ and expects a failure, then runs every
root-scannable check against the real repository tree and expects a pass.

This is what "encode the architecture's boundaries so they can't be
casually violated" means in practice: a check nobody has proven to fire on
a real violation is not a guardrail, it's a comment that happens to be
executable.

Run: python3 tests/assertions/self_test.py
"""
from __future__ import annotations

import sys

from common import find_repo_root

import check_core_boundary
import check_app_addition_boundary
import check_image_pinning
import check_no_cert_in_apps
import check_reserved_ports
import check_instance_literals
import check_kustomization_dag
import check_helm_strict

REPO_ROOT = find_repo_root()
FIXTURES = REPO_ROOT / "tests" / "fixtures" / "violations"

# (fixture directory name, module expected to catch it)
FIXTURE_CASES = [
    ("core-boundary", check_core_boundary),
    ("floating-tag", check_image_pinning),
    ("cert-in-apps", check_no_cert_in_apps),
    ("unreserved-port", check_reserved_ports),
    ("undefined-var", check_instance_literals),
    ("ip-literal", check_instance_literals),
    ("cyclic-dag", check_kustomization_dag),
    ("issuer-ordering", check_kustomization_dag),
]

# Every check with a real `run(root)` -- excludes check_app_addition_boundary,
# which is diff-based and tested separately via its pure `check()` function.
ROOT_SCANNABLE = (
    check_core_boundary,
    check_image_pinning,
    check_no_cert_in_apps,
    check_reserved_ports,
    check_instance_literals,
    check_kustomization_dag,
    check_helm_strict,
)

failures: list[str] = []


def report(ok: bool, description: str) -> None:
    print(("  ok   " if ok else "  FAIL ") + description)
    if not ok:
        failures.append(description)


print("=== each check must CATCH its dedicated violation fixture ===")
for fixture_name, module in FIXTURE_CASES:
    fixture_root = FIXTURES / fixture_name
    if not fixture_root.exists():
        report(False, f"{module.__name__}: fixture directory missing: {fixture_root}")
        continue
    violations = module.run(fixture_root)
    report(len(violations) > 0, f"{module.__name__} catches tests/fixtures/violations/{fixture_name}/")

print()
print("=== the app-addition-boundary diff rule (unit tested directly, no git needed) ===")
report(
    len(check_app_addition_boundary.check(["apps/examples/foo/deployment.yaml"])) == 0,
    "an apps/-only change is allowed",
)
report(
    len(check_app_addition_boundary.check(
        ["apps/examples/foo/deployment.yaml", "platform/ingress/gateway.yaml"]
    )) > 0,
    "an apps/ change alongside a platform/ change is rejected",
)
report(
    len(check_app_addition_boundary.check(
        ["clusters/example/apps-foo.yaml", "apps/examples/foo/deployment.yaml"]
    )) == 0,
    "an apps/ change alongside a NEW clusters/ enabling file is allowed",
)
report(
    len(check_app_addition_boundary.check(["platform/ingress/gateway.yaml"])) == 0,
    "a platform/-only change (no apps/ touched) is not this rule's concern",
)

print()
print("=== every root-scannable check must stay QUIET on the real repository tree ===")
for module in ROOT_SCANNABLE:
    violations = module.run(REPO_ROOT)
    if violations:
        for v in violations:
            print(f"      unexpected: {v}")
    report(len(violations) == 0, f"{module.__name__} finds nothing wrong in the real repository")

print()
if failures:
    print(f"SELF-TEST FAILED: {len(failures)} case(s) did not behave as expected.")
    sys.exit(1)
print(
    "SELF-TEST PASSED: every structural assertion is proven to catch its target "
    "violation, and stays quiet on the real repository."
)
