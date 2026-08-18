#!/usr/bin/env python3
"""
bootstrap/install.sh's Git-source seeding step (Step 5, the D5 local-bare-
repo minimum path) must never blindly copy this checkout's own .git
directory into the fresh working directory it prepares as the new
instance's "initial commit". A real, root-caused bootstrap flake --
intermittent "rm: cannot remove '.../.git': Directory not empty" --
traced back to exactly the blind whole-directory-contents copy idiom
(`cp -a "$X/." "$Y/"`), which silently includes .git along with everything
else: this repo's own checkout has 654 files / 253 directories under
.git, verified live, all of it copied in on top of the small git-clone-
created .git already there, then immediately deleted again by the next
line -- a large, unnecessary copy-then-delete that was the only directory
tree in that whole step big/complex enough to give a rare filesystem-level
race real surface area to occur on.

The fix (this check guards against regressing) excludes .git from the
copy in the first place, via a `find ... ! -name .git -exec cp -a ...`
per-top-level-entry copy -- a shape this regex does not match. Reverting
to the blind `cp -a "$X/." "$Y/"` idiom anywhere in this file re-opens
exactly that hazard, even if the specific variable names change.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from common import find_repo_root, rel

INSTALL_SH = "bootstrap/install.sh"

# The whole-directory-contents copy idiom: a trailing "/." on the quoted
# source path is what makes cp copy the directory's CONTENTS (including
# dotfiles/dotdirs like .git) into the destination, as opposed to e.g.
# `cp -a "$X" "$Y"` (copies X itself as one entry, a different, unrelated
# shape this check has no opinion on).
BLIND_COPY_RE = re.compile(r'cp\s+-a\s+"[^"]+/\."\s+"[^"]+/"')


def run(root: Path) -> list[str]:
    path = root / INSTALL_SH
    if not path.exists():
        return []
    violations: list[str] = []
    for lineno, line in enumerate(path.read_text().splitlines(), start=1):
        # Skip comment lines -- this file's own Step 5 documents the exact
        # historical broken pattern verbatim, in prose, as part of
        # explaining why the current code is shaped the way it is. That's
        # documentation, not a live command; only an actual, executable
        # line matters here.
        if line.strip().startswith("#"):
            continue
        if BLIND_COPY_RE.search(line):
            violations.append(
                f"{rel(root, path)}:{lineno}: blind whole-directory-contents copy "
                f"({line.strip()!r}) -- this silently includes .git (this repo's own "
                "checkout: 654 files / 253 dirs), which a real, root-caused bootstrap "
                "flake traced back to. Use a find-based per-entry copy that excludes "
                ".git instead (see the existing Step 5 code and its own comment)."
            )
    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_bootstrap_git_snapshot")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_bootstrap_git_snapshot")
