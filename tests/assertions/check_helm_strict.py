#!/usr/bin/env python3
"""
For every Flux HelmRelease found repository-wide, render its chart with its
own inline values and lint it with warnings-as-errors.

REAL FINDING, from actually running this against Helm 3.17: `helm template`
has no `--strict` flag at all -- it was removed/never existed on that
subcommand; `--strict` only exists on `helm lint`. This script originally
assumed otherwise. Worse, verified directly: `helm template` with a
deliberately wrong values path one level deep (`service.type` instead of
the traefik chart's actual `service.spec.type`) renders successfully with
exit 0 and the override silently dropped -- reproducing the exact historical
bug (docs/decisions/, the reference implementation's real incident) on a
current chart, today. A chart's values.schema.json only rejects an unknown
key at the specific nesting level its authors annotated
`additionalProperties: false` -- proven here to reject a bogus top-level
key but NOT a misplaced key one level into an existing object.

What this script actually does, honestly:
  1. `helm template` -- must render without error (catches missing
     required values, malformed values, broken chart references).
  2. `helm lint --strict` -- catches whatever schema-level violations the
     chart itself defines (real, but partial -- see above).

What this script does NOT do, and cannot do generically: prove that a
specific override value actually reached the specific manifest field SCRAP
intended. That guarantee comes from live, post-deploy verification against
a running cluster (e.g. `kubectl get svc -n traefik traefik -o
jsonpath='{.spec.type}'`) -- the dynamic acceptance profiles in
tests/profiles/ are where that check belongs, not a static, offline one.

No-ops cleanly, without network access, when no HelmRelease exists yet.
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

            template = subprocess.run(
                ["helm", "template", chart, "--repo", repo_url, "--version", version, "-f", str(values_file)],
                capture_output=True, text=True,
            )
            if template.returncode != 0:
                violations.append(f"{rel(root, path)}: `helm template` failed:\n{template.stderr.strip()}")
                continue  # linting a chart that doesn't even render isn't useful

            # `helm lint` -- unlike template/pull/install -- takes a local chart
            # PATH, not a --repo/--version reference. Pull it first.
            pull = subprocess.run(
                ["helm", "pull", chart, "--repo", repo_url, "--version", version, "--untar", "--destination", tmp],
                capture_output=True, text=True,
            )
            if pull.returncode != 0:
                violations.append(f"{rel(root, path)}: `helm pull` failed:\n{pull.stderr.strip()}")
                continue
            chart_dir = Path(tmp) / chart

            lint = subprocess.run(
                ["helm", "lint", "--strict", str(chart_dir), "-f", str(values_file)],
                capture_output=True, text=True,
            )
            if lint.returncode != 0:
                violations.append(f"{rel(root, path)}: `helm lint --strict` failed:\n{lint.stdout.strip()}")

    return violations


if __name__ == "__main__":
    root = find_repo_root()
    n = len(_find_helmreleases(root))
    violations = run(root)
    if violations:
        print("FAIL: check_helm_strict")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    suffix = f"validated {n} HelmRelease(s)" if n else "no HelmReleases exist yet"
    print(f"PASS: check_helm_strict ({suffix})")
