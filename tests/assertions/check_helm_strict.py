#!/usr/bin/env python3
"""
For every Flux HelmRelease found repository-wide, render its chart with
`helm template --strict` using the release's own inline values. `--strict`
fails on values that don't match the chart's schema -- the direct fix for a
real bug where a wrong values path (`service.type` instead of the chart's
actual `service.spec.type`) was silently accepted by Helm and never took
effect, while the upgrade itself reported success.

No-ops cleanly, and without needing network access, when no HelmRelease
exists yet -- true for most of this repository's early implementation
milestones. Requires the `helm` binary once there's something to check.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

from common import find_repo_root, iter_yaml_docs_repo, rel


def _find_helmreleases(root: Path) -> list[tuple[Path, dict]]:
    out = []
    for path, doc in iter_yaml_docs_repo(root):
        if (
            str(doc.get("apiVersion", "")).startswith("helm.toolkit.fluxcd.io")
            and doc.get("kind") == "HelmRelease"
        ):
            out.append((path, doc))
    return out


def _find_helmrepository_url(root: Path, name: str, namespace: str) -> str | None:
    for _, doc in iter_yaml_docs_repo(root):
        if (
            doc.get("kind") == "HelmRepository"
            and doc.get("metadata", {}).get("name") == name
            and doc.get("metadata", {}).get("namespace", namespace) == namespace
        ):
            return doc.get("spec", {}).get("url")
    return None


def run(root: Path) -> list[str]:
    releases = _find_helmreleases(root)
    if not releases:
        return []
    if not shutil.which("helm"):
        return ["helm binary not found -- cannot validate the HelmRelease(s) present in this repository"]

    violations: list[str] = []
    for path, doc in releases:
        spec = doc.get("spec", {})
        chart_spec = spec.get("chart", {}).get("spec", {})
        chart = chart_spec.get("chart")
        version = chart_spec.get("version")
        source_ref = chart_spec.get("sourceRef", {})
        namespace = doc.get("metadata", {}).get("namespace", "default")
        repo_url = _find_helmrepository_url(root, source_ref.get("name", ""), namespace)
        values = spec.get("values")

        if not (chart and version and repo_url):
            violations.append(f"{rel(root, path)}: HelmRelease missing chart/version/sourceRef -- cannot validate")
            continue

        with tempfile.TemporaryDirectory() as tmp:
            values_file = Path(tmp) / "values.yaml"
            values_file.write_text(yaml.safe_dump(values or {}))
            result = subprocess.run(
                [
                    "helm", "template", chart,
                    "--repo", repo_url,
                    "--version", version,
                    "-f", str(values_file),
                    "--strict",
                ],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                violations.append(
                    f"{rel(root, path)}: `helm template --strict` failed:\n{result.stderr.strip()}"
                )
    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_helm_strict")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_helm_strict (nothing to check yet)")
