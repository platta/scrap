#!/usr/bin/env python3
"""
No `Certificate` resource, and no `ClusterIssuer` resource or `issuerRef`
reference, exists anywhere under apps/. Applications never know which TLS
issuer is active -- the platform's one wildcard certificate covers every
HTTP(S) application unconditionally.

See docs/decisions/0006-tls-wildcard-and-issuer-independence.md. Checked
statically so the claim is proven, not merely asserted in documentation.
"""
from __future__ import annotations

import sys
from pathlib import Path

from common import find_repo_root, iter_yaml_docs, rel


def run(root: Path) -> list[str]:
    violations: list[str] = []
    for path, doc in iter_yaml_docs(root, "apps"):
        kind = doc.get("kind")
        if kind == "Certificate":
            violations.append(f"{rel(root, path)}: a Certificate resource exists under apps/")
        if kind == "ClusterIssuer":
            violations.append(f"{rel(root, path)}: a ClusterIssuer resource exists under apps/")
        spec = doc.get("spec")
        if isinstance(spec, dict) and "issuerRef" in spec:
            violations.append(f"{rel(root, path)}: an issuerRef exists under apps/ (kind={kind})")
    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_no_cert_in_apps")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_no_cert_in_apps")
