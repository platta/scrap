#!/bin/sh
# Minimal fixture for check_bootstrap_git_snapshot.py -- deliberately
# reintroduces the blind whole-directory-contents copy idiom that silently
# includes .git, proving the check actually fires on it. Not a real,
# runnable install.sh; check_bootstrap_git_snapshot.py only reads this
# file's text, it never executes it.
set -eu
WORKDIR=$(mktemp -d)
cp -a "$REPO_ROOT/." "$WORKDIR/"
