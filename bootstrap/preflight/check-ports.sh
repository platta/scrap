#!/bin/sh
# Fail loudly if a port SCRAP's core needs is already bound by something
# else. Direct fix for a real incident class: an ingress controller
# claiming ports that were secretly already in use, discovered only at
# cutover instead of before it.
#
# 6443 -- the Kubernetes API server (k3s).
# 80/443 -- platform/ingress/'s Gateway, per
# platform/ingress/reserved-ports.yaml (the single source of truth this
# check reads, so an app-declared port added there is checked here too).
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALLOWLIST="$REPO_ROOT/platform/ingress/reserved-ports.yaml"

status=0

check_port() {
    port="$1"
    proto="$2"
    if [ "$proto" = "TCP" ]; then
        ss_flags="-lnt"
    else
        ss_flags="-lnu"
    fi
    if command -v ss >/dev/null 2>&1; then
        # Local Address:Port is column 4 of `ss -ln[tu]` output, NOT column
        # 5 (that's the peer address) -- verified directly against real
        # output, not assumed from memory. Real bug caught testing this
        # script on a host that actually had 6443 bound: the original
        # version read the wrong column AND concatenated `-ln` + `-t` into
        # one invalid argument, silently reporting every port "free" no
        # matter what was actually listening.
        if ss $ss_flags 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$"; then
            echo "FAIL  check-ports: $proto port $port is already in use"
            status=1
        else
            echo "ok    check-ports: $proto port $port is free"
        fi
    else
        echo "WARN  check-ports: 'ss' not found, cannot check port $port/$proto"
    fi
}

check_port 6443 TCP

if [ -f "$ALLOWLIST" ]; then
    # Minimal, dependency-free YAML read: pull "port: N" / "protocol: X"
    # pairs out of the reservedPorts list without needing a YAML parser
    # on a bare host that may not have one yet.
    ports=$(grep -A1 '^  - port:' "$ALLOWLIST" | grep 'port:' | awk '{print $3}')
    for port in $ports; do
        proto=$(awk -v p="$port" '
            $0 ~ "port: "p"$" {found=1}
            found && /protocol:/ {print $2; exit}
        ' "$ALLOWLIST")
        proto="${proto:-TCP}"
        check_port "$port" "$proto"
    done
else
    echo "WARN  check-ports: $ALLOWLIST not found, only checked 6443"
fi

exit $status
