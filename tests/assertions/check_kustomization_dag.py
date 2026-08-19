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

     REAL GAP, found implementing capabilities/public-tls/: the wildcard
     Certificate's issuerRef became ${TLS_ISSUER} (an instance-config
     token selecting between scrap-ca, scrap-acme-staging, and scrap-acme
     -- see platform/ingress/wildcard-certificate.yaml), and a literal
     dict lookup on the unresolved token string obviously never matches
     any real ClusterIssuer's name -- silently degrading this rule to a
     no-op for the one Certificate it was written to protect. Fixed by
     checking an issuerRef that's still a ${VAR} token against EVERY
     ClusterIssuer this repository currently defines, not one literal
     name: since substitution could resolve to any of them, the applying
     Kustomization must (transitively) dependOn every one of their
     owners, not just whichever happens to be checked-in as the default.

(The core-vs-capability-vs-app dependency DIRECTION rule lives in
check_core_boundary.py; this script is about ordering, not direction.)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from common import find_repo_root, iter_yaml_docs, iter_yaml_docs_repo, rel

VAR_TOKEN_RE = re.compile(r"^\$\{[A-Z][A-Z0-9_]*\}$")

# Same tier concept check_core_boundary.py enforces (platform/ may never
# reference capabilities/ or apps/; capabilities/ may never reference
# apps/) -- replicated locally rather than cross-imported, matching this
# project's existing convention of each check module standing alone.
# Needed here for the SAME reason: a Kustomization whose issuerRef token
# could resolve to a ClusterIssuer owned by a strictly-more-downstream
# tier (e.g. platform/ingress's wildcard Certificate, and
# capabilities/public-tls/'s ACME issuers) must NOT be required to
# dependsOn that owner -- doing so would itself be the exact violation
# check_core_boundary.py exists to prevent. This is not a loophole: a
# named Kubernetes reference across that boundary is inherently
# eventually-consistent (cert-manager reports the Certificate as simply
# not-Ready until a matching ClusterIssuer appears, not a hard dry-run
# apply failure the way a missing CRD is) -- the hazard this rule exists
# to catch genuinely does not apply across a tier boundary that must stay
# loosely coupled by design.
TIER_RANK = {"platform": 0, "capabilities": 1, "apps": 2}


def _tier_of(path_value: str) -> str | None:
    p = path_value.lstrip("./")
    for tier in TIER_RANK:
        if p == tier or p.startswith(tier + "/"):
            return tier
    return None


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
    kustomization_path: dict[str, str] = {}
    cert_refs: list[tuple[str, Path, str]] = []
    for name, info in kustomizations.items():
        kpath = info["doc"].get("spec", {}).get("path", "")
        kustomization_path[name] = kpath
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
        # An unresolved ${VAR} token could resolve to ANY ClusterIssuer this
        # repository defines -- check ordering against every one of them,
        # not a literal (and therefore never-matching) name lookup.
        if VAR_TOKEN_RE.match(issuer_name):
            candidate_names = list(issuer_owner)
        else:
            candidate_names = [issuer_name]

        applier_tier = _tier_of(kustomization_path.get(kname, ""))
        for candidate in candidate_names:
            owner = issuer_owner.get(candidate)
            if owner is None or owner == kname:
                continue  # unknown issuer (out of this repo's scope) or self-contained -- fine
            owner_tier = _tier_of(kustomization_path.get(owner, ""))
            if (
                applier_tier is not None
                and owner_tier is not None
                and TIER_RANK[owner_tier] > TIER_RANK[applier_tier]
            ):
                # Requiring this dependsOn would itself violate the
                # platform/capabilities/apps tier-direction rule -- see
                # this file's own module-level comment.
                continue
            if owner not in _reachable(graph, kname):
                violations.append(
                    f"{rel(root, kfile)}: Kustomization {kname!r} applies a Certificate whose "
                    f"issuerRef ({issuer_name!r}) could resolve to ClusterIssuer {candidate!r} "
                    f"(owned by {owner!r}) without (transitively) dependsOn-ing it"
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
