#!/bin/sh
# k3s requires the unified cgroup v2 hierarchy. The standard, portable test:
# the filesystem type mounted at /sys/fs/cgroup is cgroup2fs under v2, and
# tmpfs (with cgroup1 controllers mounted below it) otherwise.
set -eu

echo "--- check-cgroups ---"

if [ ! -d /sys/fs/cgroup ]; then
    echo "FAIL  check-cgroups: /sys/fs/cgroup does not exist"
    exit 1
fi

fstype=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo "unknown")
if [ "$fstype" = "cgroup2fs" ]; then
    echo "ok    check-cgroups: unified cgroup v2 hierarchy active"
    exit 0
fi

echo "FAIL  check-cgroups: /sys/fs/cgroup is '$fstype', not cgroup2fs -- cgroup v2 is not active"
echo "      k3s requires cgroup v2. On Debian/Ubuntu this is the default on recent kernels;"
echo "      check for a 'systemd.unified_cgroup_hierarchy=0' kernel parameter overriding it."
exit 1
