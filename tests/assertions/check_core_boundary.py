#!/usr/bin/env python3
"""
Core boundary: platform/ must not reference capabilities/ or apps/.
capabilities/ must not reference apps/.

Encodes the architecture's one-directional dependency rule
(docs/core/repository-structure.md): a lower tier may never depend on a
higher one. Integration glue for an optional capability lives in that
capability's own directory, never in platform/.

Checked two ways:
  1. Textual path references -- a Kustomize `resources:`/`components:`/
     `bases:` entry, or any other YAML line under the wrong tier, containing
     a forbidden directory name.
  2. Flux Kustomization dependsOn -- a Kustomization whose own `spec.path` is
     under platform/ must not (even transitively is out of scope for this
     direct check; direct dependsOn only) reference a Kustomization whose
     `spec.path` is under a higher tier.

This is the direct, structural fix for a real defect: a platform monitoring
Kustomization that `dependsOn` an identity application, so deleting the
application broke the entire observability stack.
"""
from __future__ import annotations

import sys
from pathlib import Path

from common import find_repo_root, iter_yaml_files, iter_yaml_docs_repo, rel

FORBIDDEN_TOKENS = {
    "platform": ("apps/", "capabilities/"),
    "capabilities": ("apps/",),
}

TIER_RANK = {"platform": 0, "capabilities": 1, "apps": 2}


def _tier_of(path_value: str) -> str | None:
    p = path_value.lstrip("./")
    for tier in TIER_RANK:
        if p == tier or p.startswith(tier + "/"):
            return tier
    return None


def run(root: Path) -> list[str]:
    violations: list[str] = []

    # --- 1. Textual path references ---
    for tier, tokens in FORBIDDEN_TOKENS.items():
        for path in iter_yaml_files(root, tier):
            for lineno, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                for token in tokens:
                    if token in line:
                        violations.append(
                            f"{rel(root, path)}:{lineno}: {tier}/ references {token!r}: {stripped!r}"
                        )

    # --- 2. Flux Kustomization dependsOn direction ---
    kustomizations: dict[str, dict] = {}
    for path, doc in iter_yaml_docs_repo(root):
        if (
            str(doc.get("apiVersion", "")).startswith("kustomize.toolkit.fluxcd.io")
            and doc.get("kind") == "Kustomization"
        ):
            name = doc.get("metadata", {}).get("name")
            if name:
                kustomizations[name] = {"doc": doc, "file": path}

    for name, info in kustomizations.items():
        my_tier = _tier_of(info["doc"].get("spec", {}).get("path", ""))
        if my_tier is None:
            continue
        for dep in info["doc"].get("spec", {}).get("dependsOn") or []:
            dep_name = dep.get("name") if isinstance(dep, dict) else None
            if not dep_name or dep_name not in kustomizations:
                continue
            dep_tier = _tier_of(kustomizations[dep_name]["doc"].get("spec", {}).get("path", ""))
            if dep_tier is None:
                continue
            if TIER_RANK[dep_tier] > TIER_RANK[my_tier]:
                violations.append(
                    f"{rel(root, info['file'])}: Kustomization {name!r} (tier {my_tier}) "
                    f"dependsOn {dep_name!r} (tier {dep_tier}) -- a lower tier may not "
                    f"depend on a higher one"
                )

    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_core_boundary")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_core_boundary")
