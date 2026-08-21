#!/usr/bin/env python3
"""
Every container image reference under platform/, capabilities/, apps/, and
components/ is pinned: no floating `:latest` tag, and no bare image
reference with no tag at all (which resolves to `:latest` regardless).
A digest reference (`@sha256:...`) counts as pinned.

Reproducible rebuilds over time depend on this -- an unpinned tag silently
performing a breaking major-version upgrade on restore is a real, previously
observed failure mode, not a hypothetical one.

Two independent passes, deliberately not just one:

  1. A line-based regex over `image: <ref>` -- the common case, cheap, and
     reports an exact line number.
  2. A real YAML-AST walk over every parsed document, looking for any
     `image:` key whose value is a MAPPING (Helm's own split
     `repository:`/`tag:`/`digest:` form, e.g. a sub-chart's
     `image: {repository: foo, tag: bar}` values override) rather than a
     single string.

REAL BUG, found live via an independent review: pass 1 alone is blind to
pass 2's shape entirely -- a bare `image:` line (the key, with its value on
following lines as a nested mapping) does not match the line regex at all,
and the `repository:`/`tag:` lines underneath it don't either. Confirmed by
testing the old regex directly: `image:` and `  repository: foo` both
matched nothing. Any HelmRelease values overriding a sub-chart's image via
this split form -- a real, common Helm convention, used by kube-prometheus-
stack's own sub-charts among others -- could carry an unpinned or
`latest`-tagged image with zero warning from this check. Confirmed against
the real repository: no HelmRelease here currently uses this form, so this
gap was not (as of this fix) hiding an already-unpinned image in this
repository -- but the checker itself could not have told you either way.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from common import find_repo_root, iter_yaml_docs, iter_yaml_files, rel

IMAGE_LINE_RE = re.compile(r'^\s*image:\s*["\']?([^"\'\s#]+)["\']?\s*(#.*)?$')
SCAN_DIRS = ("platform", "capabilities", "apps", "components")


def _is_pinned(image_ref: str) -> bool:
    if "@sha256:" in image_ref:
        return True
    last_slash = image_ref.rfind("/")
    last_colon = image_ref.rfind(":")
    if last_colon <= last_slash:
        return False  # no tag at all -- an implicit :latest
    tag = image_ref[last_colon + 1:]
    return tag not in ("latest", "")


def _walk_for_split_image(node, path_label: str) -> list[str]:
    violations: list[str] = []
    if isinstance(node, dict):
        image = node.get("image")
        if isinstance(image, dict):
            repo = image.get("repository")
            tag = image.get("tag")
            digest = image.get("digest")
            if repo is not None and not digest and (tag is None or str(tag) in ("", "latest")):
                violations.append(
                    f"{path_label}: unpinned Helm-style image (repository={repo!r}, tag={tag!r})"
                )
        for value in node.values():
            violations.extend(_walk_for_split_image(value, path_label))
    elif isinstance(node, list):
        for item in node:
            violations.extend(_walk_for_split_image(item, path_label))
    return violations


def run(root: Path) -> list[str]:
    violations: list[str] = []

    # Pass 1: line-based, the common single-line `image: ref` form.
    for subdir in SCAN_DIRS:
        for path in iter_yaml_files(root, subdir):
            for lineno, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
                m = IMAGE_LINE_RE.match(line)
                if not m:
                    continue
                ref = m.group(1)
                if not _is_pinned(ref):
                    violations.append(f"{rel(root, path)}:{lineno}: unpinned image reference {ref!r}")

    # Pass 2: real YAML AST, Helm's split repository:/tag:/digest: form.
    for subdir in SCAN_DIRS:
        for path, doc in iter_yaml_docs(root, subdir):
            violations.extend(_walk_for_split_image(doc, rel(root, path)))

    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_image_pinning")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_image_pinning")
