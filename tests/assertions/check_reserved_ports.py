#!/usr/bin/env python3
"""
Every LoadBalancer Service port, and every container hostPort, must be
declared in platform/ingress/reserved-ports.yaml.

The direct, structural fix for a real incident: an ingress controller's
default LoadBalancer Service silently claimed a host's real production
ports via k3s's ServiceLB, for roughly 49 minutes before it was noticed.
Adding a raw TCP/UDP application (pattern P4) means adding its port to the
allowlist in the same pull request -- reviewable, diffable, and checked here.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

from common import find_repo_root, iter_yaml_docs, rel

ALLOWLIST_PATH = "platform/ingress/reserved-ports.yaml"
SCAN_DIRS = ("platform", "capabilities", "apps")
CONTAINER_BEARING_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "Job")


def _load_allowlist(root: Path) -> set[tuple[int, str]]:
    path = root / ALLOWLIST_PATH
    if not path.exists():
        return set()
    data = yaml.safe_load(path.read_text()) or {}
    return {
        (int(e["port"]), str(e.get("protocol", "TCP")).upper())
        for e in data.get("reservedPorts", [])
    }


def _containers_of(doc: dict) -> list[dict]:
    kind = doc.get("kind")
    if kind in CONTAINER_BEARING_KINDS:
        return doc.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []) or []
    if kind == "CronJob":
        return (
            doc.get("spec", {})
            .get("jobTemplate", {})
            .get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("containers", [])
            or []
        )
    return []


def run(root: Path) -> list[str]:
    allowed = _load_allowlist(root)
    violations: list[str] = []

    for subdir in SCAN_DIRS:
        for path, doc in iter_yaml_docs(root, subdir):
            if doc.get("kind") == "Service" and doc.get("spec", {}).get("type") == "LoadBalancer":
                for port_spec in doc.get("spec", {}).get("ports", []) or []:
                    port = port_spec.get("port")
                    proto = str(port_spec.get("protocol", "TCP")).upper()
                    if port is not None and (int(port), proto) not in allowed:
                        violations.append(
                            f"{rel(root, path)}: LoadBalancer Service claims port {port}/{proto}, "
                            f"not declared in {ALLOWLIST_PATH}"
                        )

            for c in _containers_of(doc):
                for cp in c.get("ports", []) or []:
                    hp = cp.get("hostPort")
                    proto = str(cp.get("protocol", "TCP")).upper()
                    if hp is not None and (int(hp), proto) not in allowed:
                        violations.append(
                            f"{rel(root, path)}: container {c.get('name')!r} declares hostPort "
                            f"{hp}/{proto}, not declared in {ALLOWLIST_PATH}"
                        )
    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_reserved_ports")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_reserved_ports")
