#!/bin/sh
# SCRAP supports x86-64 and arm64. Fail loudly rather than let k3s
# installation fail obscurely partway through on an unsupported arch.
set -eu

echo "--- check-arch ---"

arch=$(uname -m)
case "$arch" in
    x86_64|amd64)
        echo "ok    check-arch: $arch (x86-64)"
        ;;
    aarch64|arm64)
        echo "ok    check-arch: $arch (arm64)"
        ;;
    *)
        echo "FAIL  check-arch: '$arch' is not a supported architecture (need x86-64 or arm64)"
        exit 1
        ;;
esac
