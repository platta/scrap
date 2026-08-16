#!/bin/sh
# Runs every preflight check and reports all failures together, rather than
# stopping at the first one -- an operator fixing problems one at a time,
# re-running this after each, is a worse experience than seeing everything
# wrong up front. bootstrap/install.sh refuses to continue if this exits
# non-zero.
set -u
cd "$(dirname "$0")"

status=0
for check in check-prerequisites.sh check-arch.sh check-cgroups.sh check-disk.sh check-clock.sh check-ports.sh check-resolver.sh; do
    sh "./$check" || status=1
    echo
done

if [ "$status" -ne 0 ]; then
    echo "Preflight FAILED. Fix the FAIL items above before continuing -- installation refuses to start"
    echo "with an unresolved failure. WARN items are informational; review them, but they don't block."
    exit 1
fi
echo "Preflight PASSED."
