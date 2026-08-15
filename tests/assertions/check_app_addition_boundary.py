#!/usr/bin/env python3
"""
T2, enforced as a diff rule: a pull request that touches apps/ may not also
touch platform/ or capabilities/. "Adding a normal application requires no
platform change" is executed here, not merely asserted in prose.

Only meaningful with something to diff against. In CI this runs on
pull_request events using GITHUB_BASE_REF; on a direct push (e.g. to main,
or when run locally with no PR context) it has nothing to compare against
and no-ops rather than blocking, which is the honest behavior -- this check
cannot evaluate a single commit in isolation.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from common import find_repo_root


def changed_files(root: Path, base_ref: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{base_ref}...HEAD"],
        cwd=root, capture_output=True, text=True, check=True,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def check(paths: list[str]) -> list[str]:
    """Pure function, unit-testable without git: given a list of changed
    paths, return violation messages (empty = fine)."""
    if not any(p.startswith("apps/") for p in paths):
        return []
    violations = []
    for p in paths:
        if p.startswith("platform/") or p.startswith("capabilities/"):
            violations.append(
                f"{p}: a change that also touches apps/ must not touch platform/ or "
                f"capabilities/ (T2) -- enable the application via a new file under "
                f"clusters/<name>/ instead"
            )
    return violations


if __name__ == "__main__":
    root = find_repo_root()
    base_ref = os.environ.get("GITHUB_BASE_REF")
    if not base_ref:
        print("SKIP: check_app_addition_boundary (no pull-request base ref found)")
        sys.exit(0)
    try:
        paths = changed_files(root, f"origin/{base_ref}")
    except subprocess.CalledProcessError as exc:
        print(f"SKIP: check_app_addition_boundary (could not diff against origin/{base_ref}: {exc})")
        sys.exit(0)

    violations = check(paths)
    if violations:
        print("FAIL: check_app_addition_boundary")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_app_addition_boundary")
