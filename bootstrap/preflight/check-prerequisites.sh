#!/bin/sh
# The other install.sh steps assume curl, git, and age-keygen exist.
# Found live: a genuinely bare Debian cloud image does NOT ship git by
# default. Without this check, install.sh would install k3s (step 2) and
# only fail on the missing `git` binary at step 5 -- leaving a stray,
# half-bootstrapped k3s install behind. Checking every install.sh
# dependency here, before anything is installed, is what "fail loud"
# actually requires: failing loud AFTER already doing something invasive
# is not the same guarantee.
set -eu
status=0

echo "--- check-prerequisites ---"

check_bin() {
    bin="$1"
    pkg="$2"
    if command -v "$bin" >/dev/null 2>&1; then
        echo "ok    check-prerequisites: '$bin' found"
    else
        echo "FAIL  check-prerequisites: '$bin' not found -- install it first (e.g. 'sudo apt install $pkg')"
        status=1
    fi
}

check_bin curl curl
check_bin git git
check_bin age-keygen age

exit $status
