#!/usr/bin/env python3
"""
Two checks over the repository-wide Flux Kustomization dependency graph:

  1. Acyclic -- no Kustomization transitively dependsOn itself.
  2. Issuer ordering -- a Kustomization that applies a `Certificate` naming
     an `issuerRef` must (transitively) dependsOn whichever Kustomization
     defines that ClusterIssuer, unless it defines it itself. The direct,
     structural fix for a real, easy-to-miss bug class: a Certificate
     applied before its issuer is guaranteed to exist, which fails only on
     a genuine from-zero bootstrap -- exactly when it's hardest to debug.

(The core-vs-capability-vs-app dependency DIRECTION rule lives in
check_core_boundary.py; this script is about ordering, not direction.)
"""
from __future__ import annotations

import sys
from pathlib import Path

from common import find_repo_root, iter_yaml_docs, iter_yaml_docs_repo, rel


def _load_kustomizations(root: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for path, doc in iter_yaml_docs_repo(root):
        if (
            str(doc.get("apiVersion", "")).startswith("kustomize.toolkit.fluxcd.io")
            and doc.get("kind") == "Kustomization"
        ):
            name = doc.get("metadata", {}).get("name")
            if name:
                out[name] = {"doc": doc, "file": path}
    return out


def _find_cycle(graph: dict[str, list[str]]) -> list[str] | None:
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {n: WHITE for n in graph}
    stack_path: list[str] = []

    def visit(n: str) -> list[str] | None:
        color[n] = GRAY
        stack_path.append(n)
        for m in graph.get(n, []):
            if m not in color:
                continue
            if color[m] == GRAY:
                return stack_path[stack_path.index(m):] + [m]
            if color[m] == WHITE:
                found = visit(m)
                if found:
                    return found
        stack_path.pop()
        color[n] = BLACK
        return None

    for n in list(graph):
        if color[n] == WHITE:
            found = visit(n)
            if found:
                return found
    return None


def _reachable(graph: dict[str, list[str]], start: str) -> set[str]:
    seen: set[str] = set()
    stack = list(graph.get(start, []))
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        stack.extend(graph.get(n, []))
    return seen


def _target_manifests(root: Path, kpath: str) -> list[dict]:
    target = root / kpath.lstrip("./")
    if not target.exists():
        return []
    try:
        rel_dir = str(target.relative_to(root))
    except ValueError:
        return []
    return [doc for _, doc in iter_yaml_docs(root, rel_dir)]


def run(root: Path) -> list[str]:
    violations: list[str] = []
    kustomizations = _load_kustomizations(root)
    graph = {
        name: [
            d.get("name")
            for d in (info["doc"].get("spec", {}).get("dependsOn") or [])
            if isinstance(d, dict) and d.get("name")
        ]
        for name, info in kustomizations.items()
    }

    cycle = _find_cycle(graph)
    if cycle:
        violations.append(f"dependency cycle among Kustomizations: {' -> '.join(cycle)}")

    issuer_owner: dict[str, str] = {}
    cert_refs: list[tuple[str, Path, str]] = []
    for name, info in kustomizations.items():
        kpath = info["doc"].get("spec", {}).get("path", "")
        for doc in _target_manifests(root, kpath):
            if doc.get("kind") == "ClusterIssuer":
                issuer_name = doc.get("metadata", {}).get("name", "")
                if issuer_name:
                    issuer_owner[issuer_name] = name
            if doc.get("kind") == "Certificate":
                issuer_name = doc.get("spec", {}).get("issuerRef", {}).get("name")
                if issuer_name:
                    cert_refs.append((name, info["file"], issuer_name))

    for kname, kfile, issuer_name in cert_refs:
        owner = issuer_owner.get(issuer_name)
        if owner is None or owner == kname:
            continue  # unknown issuer (out of this repo's scope) or self-contained -- fine
        if owner not in _reachable(graph, kname):
            violations.append(
                f"{rel(root, kfile)}: Kustomization {kname!r} applies a Certificate referencing "
                f"ClusterIssuer {issuer_name!r} (owned by {owner!r}) without (transitively) "
                f"dependsOn-ing it"
            )

    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_kustomization_dag")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_kustomization_dag")
