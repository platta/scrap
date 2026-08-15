"""Shared helpers for SCRAP's structural CI assertions.

Deliberately dependency-light: Python standard library plus PyYAML, nothing
else. These scripts are meant to be readable by anyone who already knows
Kubernetes YAML, not something you have to learn a testing framework to
follow -- see docs/decisions/0008-abstract-decisions-not-technologies.md.
"""
from __future__ import annotations

from pathlib import Path
from typing import Iterator

import yaml


def find_repo_root(start: Path | None = None) -> Path:
    """Walk upward from `start` (default: this file) until a .git directory is found."""
    p = (start or Path(__file__)).resolve()
    for candidate in (p, *p.parents):
        if (candidate / ".git").exists():
            return candidate
    raise RuntimeError("could not locate repository root (no .git directory found)")


def iter_yaml_files(root: Path, subdir: str = "") -> Iterator[Path]:
    """Yield every .yaml/.yml file under root/subdir, in a stable order."""
    base = (root / subdir) if subdir else root
    if not base.exists():
        return
    for path in sorted(base.rglob("*.yaml")) + sorted(base.rglob("*.yml")):
        if path.is_file():
            yield path


def iter_yaml_docs(root: Path, subdir: str = "") -> Iterator[tuple[Path, dict]]:
    """Yield (file, document) for every non-empty mapping-typed YAML document
    under root/subdir. Multi-document files (separated by `---`) are expanded.
    Files that aren't valid YAML are silently skipped -- catching malformed
    YAML is not this module's job.
    """
    for path in iter_yaml_files(root, subdir):
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        try:
            for doc in yaml.safe_load_all(text):
                if isinstance(doc, dict):
                    yield path, doc
        except yaml.YAMLError:
            continue


def rel(root: Path, path: Path) -> str:
    """A path relative to the repo root, for stable, readable violation messages."""
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


# The directories that actually make up the reconciled tree -- platform/,
# capabilities/, apps/, clusters/, components/, bootstrap/. Deliberately
# excludes tests/ (whose fixtures/ subtree contains YAML that is
# *deliberately* broken and must never be mistaken for real repository
# content) and docs/ (prose, not manifests).
MANIFEST_DIRS = ("platform", "capabilities", "apps", "clusters", "components", "bootstrap")


def iter_yaml_docs_repo(root: Path) -> Iterator[tuple[Path, dict]]:
    """Like iter_yaml_docs(root), but scoped to MANIFEST_DIRS only. Use this
    whenever a check needs a repo-wide view of actual Kubernetes/Flux
    manifests -- e.g. finding every Kustomization or HelmRelease -- rather
    than the unscoped iter_yaml_docs(root), which would also pick up
    tests/fixtures/violations/*.
    """
    for d in MANIFEST_DIRS:
        yield from iter_yaml_docs(root, d)
