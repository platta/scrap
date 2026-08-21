#!/usr/bin/env python3
"""
Every capabilities/<name>/ directory must honestly self-declare its own
current implementation status in its own README.md, via one of exactly
two literal markers -- not inferred from how many files happen to live in
the directory (offsite-backup is fully implemented and live-tested yet
legitimately ships no manifest of its own; the actual wiring lives in
platform/backup/ -- see capabilities/offsite-backup/README.md's own
"Enabling this capability" section for why. A file-count heuristic would
misclassify exactly this real, legitimate exception).

The real defect this catches: a capability's README written in
present-tense, unqualified "FULLY SUPPORTED" language, indistinguishable
from a genuinely-implemented capability's README, while the directory
ships zero manifests -- no Kustomization, no HelmRelease, nothing to
enable. An operator following capabilities/README.md's own "enabling a
capability is copying its file(s)" instruction would find nothing there.
Found live across five directories (logs, heartbeat, dyndns, ups,
public-ingress) during the RC-truth reconciliation that added this check
-- see docs/release-readiness.md for the full account.

Whitespace (including a markdown soft line-break) is normalized before
searching, so prose can wrap for readability without breaking the check.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from common import find_repo_root, rel

IMPLEMENTED_MARKER = "IMPLEMENTED, LIVE-TESTED"
PENDING_MARKER = "DESIGNED, NOT YET IMPLEMENTED"


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def run(root: Path) -> list[str]:
    violations: list[str] = []
    capabilities_dir = root / "capabilities"
    if not capabilities_dir.exists():
        return violations
    for entry in sorted(capabilities_dir.iterdir()):
        if not entry.is_dir():
            continue
        readme = entry / "README.md"
        if not readme.exists():
            continue
        try:
            text = _normalize(readme.read_text())
        except (UnicodeDecodeError, OSError):
            continue
        has_implemented = IMPLEMENTED_MARKER in text
        has_pending = PENDING_MARKER in text
        if has_implemented and has_pending:
            violations.append(
                f"{rel(root, readme)}: carries BOTH '{IMPLEMENTED_MARKER}' and "
                f"'{PENDING_MARKER}' -- pick one"
            )
        elif not has_implemented and not has_pending:
            violations.append(
                f"{rel(root, readme)}: doesn't self-declare its status -- must contain either "
                f"'{IMPLEMENTED_MARKER}' or '{PENDING_MARKER}'"
            )
    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_capability_status_honesty")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_capability_status_honesty")
