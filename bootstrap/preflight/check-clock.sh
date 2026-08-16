#!/bin/sh
# A roughly correct clock is a real, easily-missed prerequisite: certificate
# notBefore/notAfter validation and etcd both misbehave on a badly-skewed
# clock, and this bites hardest on old hardware or SBCs with no RTC -- and
# fails in a way that looks like an unrelated TLS or cluster problem if
# it's not caught here first.
set -eu
status=0

echo "--- check-clock ---"

if command -v timedatectl >/dev/null 2>&1; then
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "unknown")
    if [ "$synced" = "yes" ]; then
        echo "ok    check-clock: NTP-synchronized (timedatectl)"
        exit 0
    fi
    echo "WARN  check-clock: timedatectl reports NTP not synchronized -- falling back to a live check"
fi

# Fallback, and a useful independent check regardless: compare local time
# against the Date header of a live HTTPS response.
if command -v curl >/dev/null 2>&1; then
    remote_date=$(curl -sI --max-time 5 https://github.com 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="date" {print $2}')
    if [ -n "$remote_date" ] && command -v date >/dev/null 2>&1; then
        remote_epoch=$(date -d "$remote_date" +%s 2>/dev/null || echo "")
        local_epoch=$(date +%s)
        if [ -n "$remote_epoch" ]; then
            diff=$((local_epoch - remote_epoch))
            [ "$diff" -lt 0 ] && diff=$((-diff))
            if [ "$diff" -gt 300 ]; then
                echo "FAIL  check-clock: local clock differs from a live remote source by ${diff}s (>5m)"
                status=1
            else
                echo "ok    check-clock: local clock within ${diff}s of a live remote source"
            fi
        else
            echo "WARN  check-clock: could not parse remote Date header, skipping"
        fi
    else
        echo "WARN  check-clock: could not reach a remote host to check clock skew"
    fi
else
    echo "WARN  check-clock: neither timedatectl nor curl available -- cannot verify clock"
fi

exit $status
