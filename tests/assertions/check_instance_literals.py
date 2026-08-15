#!/usr/bin/env python3
"""
Two checks, both encoding "instance values live in exactly one place"
(docs/core/configuration-model.md):

  1. Every ${VAR_NAME} referenced anywhere resolves to a key defined in some
     instance's clusters/*/instance-config.yaml.
  2. No literal IPv4 address appears outside clusters/, excluding loopback,
     0.0.0.0, and CIDR notation (which describes a range/convention, not an
     instance-specific value).

That alone would have caught most of a real reference implementation's
platform/application coupling -- a hardcoded ClusterIP in a platform
ConfigMap being the concrete example this check exists to prevent.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from common import find_repo_root, iter_yaml_files, iter_yaml_docs, rel

VAR_RE = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
IPV4_RE = re.compile(r"(?<![\w.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?!/)(?![\w.])")
EXEMPT_IPS = {"127.0.0.1", "0.0.0.0"}
SCAN_DIRS = ("platform", "capabilities", "apps", "components", "bootstrap")


def _defined_vars(root: Path) -> set[str]:
    names: set[str] = set()
    for _, doc in iter_yaml_docs(root, "clusters"):
        if doc.get("kind") in ("ConfigMap", "Secret"):
            names.update((doc.get("data") or {}).keys())
    return names


def run(root: Path) -> list[str]:
    violations: list[str] = []
    defined = _defined_vars(root)

    for subdir in SCAN_DIRS:
        for path in iter_yaml_files(root, subdir):
            for lineno, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
                for var in VAR_RE.findall(line):
                    if var not in defined:
                        violations.append(
                            f"{rel(root, path)}:{lineno}: ${{{var}}} is not defined in any "
                            f"clusters/*/instance-config.yaml"
                        )
                for ip in IPV4_RE.findall(line):
                    if ip in EXEMPT_IPS:
                        continue
                    violations.append(
                        f"{rel(root, path)}:{lineno}: literal IP address {ip!r} outside "
                        f"clusters/ -- use ${{VAR}} and define it in an instance-config.yaml"
                    )
    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_instance_literals")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_instance_literals")
