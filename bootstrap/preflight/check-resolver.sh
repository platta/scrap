#!/bin/sh
# The node's own DNS resolution must not depend on a service this cluster
# will host. Direct fix for a real incident: stopping an in-cluster DNS
# service broke the node's own resolution, which broke `git push`, which
# blocked the Git-delivered fix that would have restored DNS -- a genuine
# deadlock discovered live during a migration, not in advance.
#
# What's actually checkable at preflight time, honestly: we can't know in
# advance what the operator will deploy, so this can't be a hard
# "never point at yourself" rule -- a loopback stub resolver (e.g.
# systemd-resolved's 127.0.0.53, forwarding to a real upstream) is normal
# and fine. What we CAN check: (a) DNS resolution actually works right
# now, and (b) whether the configured nameserver is either this host's own
# LAN address, OR a loopback address with no positive confirmation
# (resolvectl reporting real upstreams) that it's a safe stub rather than
# something arbitrary running locally -- since that second shape is
# EXACTLY the configuration that caused the real incident this check
# exists to prevent, and a first version of this script was tested
# against that real host's actual /etc/resolv.conf (a bare `nameserver
# 127.0.0.1`, no resolvectl available) and silently reported "ok". Fixed
# before shipping, not left as a false negative in the one case that
# matters most.
set -eu
status=0

echo "--- check-resolver ---"

# (a) DNS actually works right now.
if command -v getent >/dev/null 2>&1; then
    if getent hosts github.com >/dev/null 2>&1; then
        echo "ok    check-resolver: DNS resolution works (resolved github.com)"
    else
        echo "FAIL  check-resolver: could not resolve github.com -- DNS is not working right now"
        status=1
    fi
else
    echo "WARN  check-resolver: 'getent' not found, cannot verify resolution works"
fi

# (b) Is the configured nameserver this host's own address, or an
# unconfirmed loopback?
own_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

resolver_is_confirmed_stub=0
if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
    if resolvectl status 2>/dev/null | grep -q "DNS Servers:"; then
        resolver_is_confirmed_stub=1
    fi
fi

nameservers=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null || true)
own_address_hits=""
unconfirmed_loopback_hits=""
for ns in $nameservers; do
    case "$ns" in
        127.*)
            if [ "$resolver_is_confirmed_stub" != "1" ]; then
                unconfirmed_loopback_hits="$unconfirmed_loopback_hits $ns"
            fi
            continue
            ;;
    esac
    for ip in $own_ips; do
        if [ "$ns" = "$ip" ]; then
            own_address_hits="$own_address_hits $ns"
        fi
    done
done

if [ -n "$own_address_hits" ]; then
    echo "WARN  check-resolver: /etc/resolv.conf nameserver(s)$own_address_hits match this host's own LAN address(es)."
    echo "      If anything at that address is (or will be) a pod this cluster hosts, stopping it will"
    echo "      break this node's own DNS -- the exact incident this check exists to catch."
elif [ -n "$unconfirmed_loopback_hits" ]; then
    echo "WARN  check-resolver: /etc/resolv.conf points at loopback ($unconfirmed_loopback_hits) with no"
    echo "      confirmed independent upstream (no working 'resolvectl status' showing real DNS servers)."
    echo "      This is precisely the shape of a real, previously-observed incident: a loopback resolver"
    echo "      backed by a locally-run DNS service. If that service is or becomes a workload this"
    echo "      cluster hosts, stopping it will break this node's own DNS, including its ability to"
    echo "      pull the Git-delivered fix. Point this host's resolver at a router/upstream resolver,"
    echo "      or confirm what's actually answering on that loopback address before proceeding."
elif [ "$resolver_is_confirmed_stub" = "1" ]; then
    echo "ok    check-resolver: local stub resolver detected with real upstream DNS servers configured"
else
    echo "ok    check-resolver: configured nameserver(s) are not this host's own address"
fi

exit $status
