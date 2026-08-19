#!/usr/bin/env python3
"""
tests/dr/authentik-postgres-restore.sh must always scale the COMPLETE
DB-connected tier -- Postgres itself AND every Deployment in the authentik
namespace (server, worker) -- to zero, and confirm gone, before it ever
applies the restic restore Job. This is docs/runbooks/README.md's own
documented lesson, found live restoring this exact application: leaving
server/worker running while Postgres was reloaded let their own startup/
migration logic race the manual reload and corrupt Django's migration
bookkeeping (`relation "..." already exists`, worker CrashLoopBackOff).

This check exists so that lesson stays enforced without re-running the
expensive live corruption cycle on every commit. The live cycle WAS run
once, deliberately, as a negative-control experiment proving the DR
acceptance oracle actually turns red and names corrupt/unusable recovery
rather than accepting superficial Kubernetes health -- see the commit
history around this file's own introduction for that run's evidence --
and was then reverted, leaving this textual-ordering check as the
permanent, cheap regression guard against silently reintroducing the same
class of ordering bug (even under a refactor that changes variable names,
since this matches by *shape*: a statefulset scale-to-zero and a
deployment scale-to-zero, each preceding the restore invocation, not by
literal variable names).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from common import find_repo_root, rel

DR_SCRIPT = "tests/dr/authentik-postgres-restore.sh"

STS_SCALE_ZERO_RE = re.compile(r"kc\s+scale\b.*statefulset.*--replicas=0", re.IGNORECASE)
DEPLOY_SCALE_ZERO_RE = re.compile(r"kc\s+scale\b.*deployment.*--replicas=0", re.IGNORECASE)
RESTORE_INVOCATION_RE = re.compile(r"restic restore latest")


def run(root: Path) -> list[str]:
    path = root / DR_SCRIPT
    if not path.exists():
        return []

    lines = path.read_text().splitlines()

    def first_match_lineno(pattern: re.Pattern[str]) -> int | None:
        for lineno, line in enumerate(lines, start=1):
            if line.strip().startswith("#"):
                continue
            if pattern.search(line):
                return lineno
        return None

    sts_zero_at = first_match_lineno(STS_SCALE_ZERO_RE)
    deploy_zero_at = first_match_lineno(DEPLOY_SCALE_ZERO_RE)
    restore_at = first_match_lineno(RESTORE_INVOCATION_RE)

    if restore_at is None:
        # Nothing here restores anything -- not this check's concern (some
        # other check, or a human, will notice a DR script that no longer
        # restores at all).
        return []

    violations: list[str] = []
    if sts_zero_at is None:
        violations.append(
            f"{rel(root, path)}: found a restic restore invocation (line {restore_at}) but no "
            "`kc scale ... statefulset ... --replicas=0` anywhere before it -- Postgres itself "
            "must be quiesced before restore, not just the application tier."
        )
    elif sts_zero_at > restore_at:
        violations.append(
            f"{rel(root, path)}: the statefulset scale-to-zero (line {sts_zero_at}) comes AFTER "
            f"the restic restore invocation (line {restore_at}) -- Postgres must be confirmed "
            "stopped before restore runs, not after."
        )

    if deploy_zero_at is None:
        violations.append(
            f"{rel(root, path)}: found a restic restore invocation (line {restore_at}) but no "
            "`kc scale ... deployment ... --replicas=0` anywhere before it -- the application "
            "tier (server, worker) must be quiesced before restore, not just Postgres. This is "
            "exactly the ordering bug docs/runbooks/README.md documents finding live: leaving "
            "server/worker running while Postgres was reloaded corrupted Django's migration "
            "bookkeeping."
        )
    elif deploy_zero_at > restore_at:
        violations.append(
            f"{rel(root, path)}: the deployment scale-to-zero (line {deploy_zero_at}) comes AFTER "
            f"the restic restore invocation (line {restore_at}) -- the application tier must be "
            "confirmed stopped before restore runs, not after. This is exactly the ordering bug "
            "docs/runbooks/README.md documents finding live."
        )

    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_dr_quiesce_ordering")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_dr_quiesce_ordering")
