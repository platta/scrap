#!/bin/sh
# The other install.sh steps assume curl, git, age-keygen, and sops exist.
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

# sops has no Debian/Ubuntu apt package as of bookworm -- point at the
# upstream release instead of a package name check_bin can't offer.
if command -v sops >/dev/null 2>&1; then
    echo "ok    check-prerequisites: 'sops' found"
else
    echo "FAIL  check-prerequisites: 'sops' not found -- install a pinned release from"
    echo "      https://github.com/getsops/sops/releases (e.g. the .deb for Debian/Ubuntu)"
    status=1
fi

# REAL GAP, found via an independent review: install.sh's own D5 minimum
# path (REPO_URL unset) bootstraps Flux against
# ssh://<user>@<host>/var/lib/scrap/repo.git -- Flux's OWN ongoing
# reconciliation, not just this script's one-time seeding, depends on an
# actual SSH server accepting connections on this host, every single
# reconcile. Nothing here checked for that: a genuinely bare host with no
# sshd installed would sail through every preflight check, through k3s
# install (step 2), age keys (step 4), and the local git seeding itself
# (step 5, a plain filesystem clone -- no SSH involved yet) -- only to
# fail at `flux bootstrap` (step 6), the exact "fail loud, before
# anything invasive" guarantee every other check here exists to provide.
# Checked the same way check-ports.sh already checks port reachability
# (`ss`, not just a binary's presence -- a stopped/disabled sshd service
# still has the binary on disk). Skipped entirely when REPO_URL is
# already set: that path bootstraps Flux against an external Git host,
# where this host's own sshd is genuinely irrelevant.
if [ -z "${REPO_URL:-}" ]; then
    if command -v ss >/dev/null 2>&1; then
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '[:.]22$'; then
            echo "ok    check-prerequisites: sshd is listening on port 22 (required for the local-git D5 minimum path)"
        else
            echo "FAIL  check-prerequisites: nothing is listening on port 22 -- REPO_URL is unset, so"
            echo "      install.sh's D5 minimum path bootstraps Flux over ssh://localhost, and Flux's"
            echo "      own ongoing reconciliation depends on it. Install and start an SSH server (e.g."
            echo "      'sudo apt install openssh-server'), or set REPO_URL to an externally-hosted"
            echo "      repository instead."
            status=1
        fi
    else
        echo "WARN  check-prerequisites: 'ss' not found, cannot verify sshd is listening on port 22"
    fi
fi

exit $status
