#!/usr/bin/env python3
"""
Every container image reference under platform/, capabilities/, apps/, and
components/ is pinned: no floating `:latest` tag, and no bare image
reference with no tag at all (which resolves to `:latest` regardless).
A digest reference (`@sha256:...`) counts as pinned.

Reproducible rebuilds over time depend on this -- an unpinned tag silently
performing a breaking major-version upgrade on restore is a real, previously
observed failure mode, not a hypothetical one.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from common import find_repo_root, iter_yaml_files, rel

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


def run(root: Path) -> list[str]:
    violations: list[str] = []
    for subdir in SCAN_DIRS:
        for path in iter_yaml_files(root, subdir):
            for lineno, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
                m = IMAGE_LINE_RE.match(line)
                if not m:
                    continue
                ref = m.group(1)
                if not _is_pinned(ref):
                    violations.append(f"{rel(root, path)}:{lineno}: unpinned image reference {ref!r}")
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
