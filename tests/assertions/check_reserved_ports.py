#!/usr/bin/env python3
"""
Every LoadBalancer Service port, and every container hostPort, must be
declared reserved -- reviewably and diffably, in the same pull request that
adds the manifest claiming it. The direct, structural fix for a real
incident: an ingress controller's default LoadBalancer Service silently
claimed a host's real production ports via k3s's ServiceLB, for roughly 49
minutes before it was noticed.

Two kinds of declaration, per docs/decisions/0017-p4-port-reservation-ownership.md:

  - Platform-owned ports (the ingress Gateway's own 80/443) stay declared in
    ALLOWLIST_PATH, `platform/ingress/reserved-ports.yaml`. Only a platform/
    change can edit this file, which is fine -- a platform-only pull request
    never touches apps/, so T2 (check_app_addition_boundary.py) has nothing
    to say about it.
  - Application-owned ports (pattern P4, docs/patterns/) are declared in a
    `reserved-ports.yaml` file colocated with the application itself, under
    `apps/<name>/`. This is what makes adding a P4 app satisfy T2: the
    app's own pull request touches only apps/, never platform/.

Both kinds share the same file schema (a `reservedPorts:` list of
`{port, protocol, owner, note}`) and are merged into one namespace here.
A port declared in more than one place -- two apps, or an app colliding
with a platform-owned port -- is itself a violation: the whole point of a
diffable declaration is that a reviewer can see every claim on a given
port in one place, and two conflicting claims mean at least one of them is
wrong.

Topology B (docs/decisions/0009-repository-topology.md) is why this can't
just be "always trust ALLOWLIST_PATH": an operator's own repository never
contains platform/ at all -- it's the pinned upstream Flux source, never
checked out alongside the operator's apps/. When ALLOWLIST_PATH is absent,
PLATFORM_FIXED_PORTS stands in for it: the two ports Traefik's Gateway
always binds, true in every install regardless of topology or which SCRAP
release is pinned (platform/ingress/README.md), so an operator's own P4 app
can never accidentally claim one.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

from common import find_repo_root, iter_yaml_docs, rel

ALLOWLIST_PATH = "platform/ingress/reserved-ports.yaml"
APP_ALLOWLIST_FILENAME = "reserved-ports.yaml"
SCAN_DIRS = ("platform", "capabilities", "apps")
CONTAINER_BEARING_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "Job")

# Traefik's Gateway always binds these two ports (platform/ingress/README.md)
# -- true in every install, every topology. In Topology A this is also
# spelled out explicitly in ALLOWLIST_PATH; in Topology B that file isn't
# part of the operator's own repository at all, so this constant is the only
# source for them there. Either way, an application must never claim one.
PLATFORM_FIXED_PORTS: tuple[tuple[int, str], ...] = ((80, "TCP"), (443, "TCP"))
PLATFORM_FIXED_SOURCE = "<fixed: platform/ingress, every topology>"


def _entries_of(path: Path) -> list[tuple[int, str]]:
    data = yaml.safe_load(path.read_text()) or {}
    return [
        (int(e["port"]), str(e.get("protocol", "TCP")).upper())
        for e in data.get("reservedPorts", [])
    ]


def _collect_declarations(root: Path) -> dict[tuple[int, str], list[str]]:
    """Every declared (port, protocol) -> the source(s) that declared it.
    More than one source for the same key is a collision, caught by run()."""
    declared: dict[tuple[int, str], list[str]] = {}

    def add(port: int, proto: str, source: str) -> None:
        declared.setdefault((port, proto), []).append(source)

    platform_path = root / ALLOWLIST_PATH
    if platform_path.exists():
        for port, proto in _entries_of(platform_path):
            add(port, proto, ALLOWLIST_PATH)
    else:
        for port, proto in PLATFORM_FIXED_PORTS:
            add(port, proto, PLATFORM_FIXED_SOURCE)

    apps_dir = root / "apps"
    if apps_dir.exists():
        for app_file in sorted(apps_dir.rglob(APP_ALLOWLIST_FILENAME)):
            for port, proto in _entries_of(app_file):
                add(port, proto, rel(root, app_file))

    return declared


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
    declared = _collect_declarations(root)
    violations: list[str] = []

    for (port, proto), sources in declared.items():
        if len(sources) > 1:
            violations.append(
                f"port {port}/{proto} is declared reserved in more than one place: "
                f"{', '.join(sources)} -- a port may have exactly one owner"
            )

    allowed = set(declared.keys())

    for subdir in SCAN_DIRS:
        for path, doc in iter_yaml_docs(root, subdir):
            if doc.get("kind") == "Service" and doc.get("spec", {}).get("type") == "LoadBalancer":
                for port_spec in doc.get("spec", {}).get("ports", []) or []:
                    port = port_spec.get("port")
                    proto = str(port_spec.get("protocol", "TCP")).upper()
                    if port is not None and (int(port), proto) not in allowed:
                        violations.append(
                            f"{rel(root, path)}: LoadBalancer Service claims port {port}/{proto}, "
                            f"not declared reserved anywhere (see docs/decisions/0017)"
                        )

            for c in _containers_of(doc):
                for cp in c.get("ports", []) or []:
                    hp = cp.get("hostPort")
                    proto = str(cp.get("protocol", "TCP")).upper()
                    if hp is not None and (int(hp), proto) not in allowed:
                        violations.append(
                            f"{rel(root, path)}: container {c.get('name')!r} declares hostPort "
                            f"{hp}/{proto}, not declared reserved anywhere (see docs/decisions/0017)"
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
