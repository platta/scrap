#!/bin/sh
# docs/decisions/0018-observability-topology.md's "Preflight (satellite)"
# requirement: destination URL configured, resolvable, and reachable
# (connection-level check) -- fails loudly, same discipline as every other
# preflight check.
#
# Detects satellite topology by reading THIS instance's own
# platform-observability.yaml Kustomization pointer, not a separate
# instance-config flag -- topology selection is file presence
# (docs/core/configuration-model.md), never a second, redundant "mode"
# setting that could drift from what's actually wired. A standalone (or
# not-yet-configured) instance has no satellite pointer, so this check is a
# clean no-op -- it only fails loudly when satellite mode is genuinely
# selected AND genuinely unreachable.
#
# $CLUSTER_PATH mirrors bootstrap/install.sh's own variable and default
# (./clusters/example) -- unlike every other preflight check, this one is
# genuinely instance-aware, since "is satellite mode selected" cannot be
# answered without knowing which clusters/<name>/ this install will use.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER_PATH="${CLUSTER_PATH:-./clusters/example}"
CLUSTER_DIR="$REPO_ROOT/${CLUSTER_PATH#./}"
OBS_KUSTOMIZATION="$CLUSTER_DIR/platform-observability.yaml"
INSTANCE_CONFIG="$CLUSTER_DIR/instance-config.yaml"

echo "--- check-satellite-remote-write ---"

if [ ! -f "$OBS_KUSTOMIZATION" ]; then
    echo "WARN  check-satellite-remote-write: $OBS_KUSTOMIZATION not found, cannot determine topology"
    exit 0
fi

obs_path=$(awk '/^  path:/ {print $2; exit}' "$OBS_KUSTOMIZATION")
case "$obs_path" in
    */observability-satellite)
        ;;
    *)
        echo "ok    check-satellite-remote-write: standalone topology selected -- not applicable"
        exit 0
        ;;
esac

if [ ! -f "$INSTANCE_CONFIG" ]; then
    echo "FAIL  check-satellite-remote-write: satellite topology selected but $INSTANCE_CONFIG not found"
    exit 1
fi

url=$(awk '$0 ~ "^  SATELLITE_REMOTE_WRITE_URL:" {
    sub("^  SATELLITE_REMOTE_WRITE_URL: *", ""); gsub(/"/, ""); print; exit
}' "$INSTANCE_CONFIG")

if [ -z "$url" ]; then
    echo "FAIL  check-satellite-remote-write: satellite topology selected but SATELLITE_REMOTE_WRITE_URL is empty in $INSTANCE_CONFIG"
    exit 1
fi

# Connection-level only, per docs/decisions/0018's own scoping -- this
# proves the destination is reachable right now, not that remote-write
# itself will succeed (credentials, path, and content-type are only
# proven live, post-bootstrap, by postflight and the CI acceptance
# profile). A deliberately-not-yet-up destination is a real, legitimate
# scenario (the ADR's own words) -- this fails the same way any other
# preflight check does: loudly, with what was checked, so the operator can
# bring the destination up and re-run.
if curl -sf --max-time 5 -o /dev/null "$url" 2>/dev/null; then
    echo "ok    check-satellite-remote-write: $url is reachable"
else
    # A remote-write receiver commonly answers a bare GET with 4xx/5xx
    # (wrong method, missing auth) rather than 2xx -- curl -f treats any
    # non-2xx as failure, so a non-2xx-but-connected response still proves
    # what this check actually needs: the destination is up and answering,
    # not silently unreachable. Distinguish "answered something" from
    # "never connected at all" via curl's own exit code (7 = could not
    # connect; 28 = timed out) rather than trusting -f's pass/fail alone.
    rc=0
    curl -s --max-time 5 -o /dev/null "$url" 2>/dev/null || rc=$?
    if [ "$rc" -eq 7 ] || [ "$rc" -eq 28 ]; then
        echo "FAIL  check-satellite-remote-write: $url is not reachable (curl exit $rc) -- destination must be up before bootstrap can prove satellite mode works"
        exit 1
    fi
    echo "ok    check-satellite-remote-write: $url answered (non-2xx is expected for a bare GET against a remote-write endpoint) -- connection-level reachability confirmed"
fi
