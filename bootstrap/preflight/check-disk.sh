#!/bin/sh
# Enough free disk for k3s, container images, and the platform core's own
# state (Prometheus/Alertmanager PVCs). The minimum viable platform's
# documented floor is 32GB total; this checks for at least 10GB free on
# whichever filesystem /var/lib will actually live on -- generous headroom
# below the documented minimum, not a hard cliff at it, since preflight
# runs before anything has been written yet.
set -eu

MIN_FREE_GB=10

echo "--- check-disk ---"

target=/var/lib
[ -d "$target" ] || target=/

avail_kb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -z "$avail_kb" ]; then
    echo "WARN  check-disk: could not determine free space on $target"
    exit 0
fi

avail_gb=$((avail_kb / 1024 / 1024))
if [ "$avail_gb" -lt "$MIN_FREE_GB" ]; then
    echo "FAIL  check-disk: ${avail_gb}GB free on $target, need at least ${MIN_FREE_GB}GB"
    exit 1
fi
echo "ok    check-disk: ${avail_gb}GB free on $target (>= ${MIN_FREE_GB}GB)"
