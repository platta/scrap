#!/bin/sh
# T-A-ups -- live acceptance for capabilities/ups/'s two halves.
#
# A SEPARATE from-zero bootstrap from T-A's own, same reasoning as every
# other live profile's identical comment -- this live-edits
# instance-config.yaml's own NODE_ADDRESS (same live edit
# tests/profiles/t-a-public-ingress.sh already makes, for the same
# reason: the exporter needs a real, routable address to reach upsd
# over), installs real host-level NUT, and deliberately drives it into a
# simulated low-battery state; it must never run against a cluster some
# other check still depends on.
#
# The UPS itself is NUT's own `dummy-ups` driver -- a real NUT driver,
# shipped by the same `nut` package as every real hardware driver, not a
# SCRAP-authored stand-in for NUT. Its data source is a plain,
# live-editable file (`/etc/nut/scrap-ups-test.dev`) this script rewrites
# to move the simulated device between "on line, healthy" and "on
# battery, low battery" -- the same technique NUT's own documentation
# describes dummy-ups for. A human can run this identically on their own
# scratch VM (which will, unlike CI, actually run bootstrap/host/install-nut.sh
# for real against their own host's NUT install):
#   sh tests/profiles/t-a-ups.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

status=0

DUMMY_DEV=/etc/nut/scrap-ups-test.dev
SENTINEL=/tmp/t-a-ups-shutdown-sentinel
NUT_READONLY_PASSWORD="t-a-ups-test-password-$(date +%s)"
WRONG_PASSWORD="t-a-ups-deliberately-wrong-password"

write_dummy_state() {
    # $1 = ups.status value, e.g. "OL" or "OB LB"
    sudo tee "$DUMMY_DEV" >/dev/null <<DEVEOF
ups.status: $1
battery.charge: ${2:-100}
battery.runtime: ${3:-3600}
battery.voltage: 13.5
ups.load: 10
input.voltage: 230.0
ups.mfr: SCRAP
ups.model: dummy-ups (t-a-ups.sh)
device.type: ups
DEVEOF
}

query_prom() {
    curl -sG --max-time 5 "http://127.0.0.1:9098/api/v1/query" --data-urlencode "query=$1" 2>/dev/null || true
}
prom_value() {
    query_prom "$1" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
log "T-A-ups: Phase 0/7: environment prerequisites"
install_prereqs

# ---------------------------------------------------------------------------
log "T-A-ups: Phase 1/7: the simulated UPS's own data file, healthy, before the driver ever starts"
sudo mkdir -p /etc/nut
write_dummy_state OL
sudo rm -f "$SENTINEL"

# ---------------------------------------------------------------------------
log "T-A-ups: Phase 2/7: bootstrap/install.sh -- the real, unmodified installer"
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A-ups: bootstrap/install.sh exited non-zero -- see the 'Step N/7'"
    echo "      marker above for which layer of the documented bootstrap sequence failed."
    exit 1
fi

setup_kubeconfig

not_ready=$(kc get kustomizations -A -o json | jq -r '
    .items[] |
    (.status.conditions // [] | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
    select($ready != "True") |
    "\(.metadata.namespace)/\(.metadata.name) (ready=\($ready))"
')
if [ -z "$not_ready" ]; then
    ok T-A-ups/kustomizations-ready-baseline "every Flux Kustomization is Ready before the capability is enabled"
else
    fail T-A-ups/kustomizations-ready-baseline "not Ready: $not_ready"
fi

NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

# ---------------------------------------------------------------------------
log "T-A-ups: Phase 3/7: host half -- bootstrap/host/install-nut.sh, for real, against dummy-ups"
if ! sudo -E env \
    NUT_UPS_NAME=ups \
    NUT_DRIVER=dummy-ups \
    NUT_PORT="$DUMMY_DEV" \
    NUT_READONLY_PASSWORD="$NUT_READONLY_PASSWORD" \
    NUT_SHUTDOWNCMD="touch $SENTINEL" \
    sh bootstrap/host/install-nut.sh; then
    echo "FAIL  T-A-ups: bootstrap/host/install-nut.sh exited non-zero -- see its own output above"
    exit 1
fi
ok T-A-ups/host-nut-installed "upsd is serving the ups dummy-ups device, upsmon is running (install-nut.sh's own verification passed)"

# 3a. NEGATIVE CONTROL, the actual shutdown trigger, checked FIRST against
# a genuinely healthy simulated UPS -- closes the same vacuous-pass gap
# every other capability's own never-fires-when-healthy check closes.
if sudo test -f "$SENTINEL"; then
    fail T-A-ups/shutdowncmd-negative-control "SENTINEL already exists with the simulated UPS healthy (OL) -- SHUTDOWNCMD fired when it should not have"
else
    ok T-A-ups/shutdowncmd-negative-control "SHUTDOWNCMD's own sentinel does not exist while the simulated UPS reports healthy (OL)"
fi

# REAL BUG, found live via this profile's own first CI run: merging
# stderr into the captured value (2>&1) picked up upsc's own harmless
# startup diagnostic ("Init SSL without certificate database", printed
# by every invocation, unrelated to dummy-ups or any real failure) ahead
# of the actual status line, breaking the exact-equality check below.
# stderr is discarded here (to a log, for diagnostics on failure), never
# merged into the value being compared.
#
# REAL BUG #2, found live via this same run once #1 was fixed: upsd
# genuinely answered "WAIT" for a few seconds immediately after the
# driver started -- dummy-ups's own real transitional status before its
# first read of the .dev file completes, not a mock or a defect. install-nut.sh's
# own readiness wait only checks upsc's EXIT STATUS (a "WAIT" answer is
# still a successful query), so it can return before the value has
# actually settled. Polled here instead of asserted once, the same
# eventual-consistency pattern every other timing-sensitive check in this
# repository already uses.
host_status=""
i=0
while [ "$i" -lt 12 ]; do
    host_status=$(sudo upsc ups@localhost ups.status 2>/tmp/t-a-ups-upsc.log || true)
    [ "$host_status" = "OL" ] && break
    sleep 2
    i=$((i + 1))
done
if [ "$host_status" = "OL" ]; then
    ok T-A-ups/host-upsc-reads-real-driver "upsc reads ups.status=OL directly from the real, running dummy-ups driver"
else
    fail T-A-ups/host-upsc-reads-real-driver "expected ups.status=OL from upsc, got: '$host_status'"
    sed 's/^/      /' /tmp/t-a-ups-upsc.log 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
log "T-A-ups: Phase 4/7: point NODE_ADDRESS at this runner's own real address, enable the in-cluster half"
BARE_REPO=/var/lib/scrap/repo.git
LIVEDIR=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR"
LIVE_CLUSTER_DIR="$LIVEDIR/clusters/example"

# Same live edit tests/profiles/t-a-public-ingress.sh already makes, for
# the same reason: NODE_ADDRESS ships as an RFC 5737 documentation
# placeholder, never meant to be live -- see that script's own comment.
sed -i "s|^\(  NODE_ADDRESS: \).*|\1\"$NODE_IP\"|" "$LIVE_CLUSTER_DIR/instance-config.yaml"

mkdir -p "$LIVE_CLUSTER_DIR/capabilities"
cp "$REPO_ROOT/capabilities/ups/cluster-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/ups.yaml"
cp "$REPO_ROOT/capabilities/ups/cluster-secrets-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/ups-secrets.yaml"

# Root-only (the operational age key install.sh generated lives at
# /etc/scrap/age/, mode 600) -- same reasoning
# t-a-alert-heartbeat.sh's own EDIT_SCRIPT gives for using a temp script
# file, not an inline `sudo sh -c` string.
EDIT_SCRIPT=$(mktemp)
cat > "$EDIT_SCRIPT" <<EOF
set -eu
cd '$LIVE_CLUSTER_DIR/secrets'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops --set '["stringData"]["NUT_USERNAME"] "k8s-monitor"' ups/ups-credentials.sops.yaml
sops --set '["stringData"]["NUT_PASSWORD"] "$NUT_READONLY_PASSWORD"' ups/ups-credentials.sops.yaml
EOF
if ! sudo sh "$EDIT_SCRIPT"; then
    echo "FAIL  T-A-ups: could not set NUT_USERNAME/NUT_PASSWORD in the live secret"
    rm -f "$EDIT_SCRIPT"
    exit 1
fi
rm -f "$EDIT_SCRIPT"

( cd "$LIVEDIR" && git add -A && git -c user.email=t-a-ups@localhost -c user.name="T-A-ups" \
    commit -q -m "T-A-ups: point NODE_ADDRESS at this runner, enable ups against the dummy-ups host" && \
    git push -q origin main )
rm -rf "$LIVEDIR"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization capabilities --with-source >/dev/null
sleep 5
flux reconcile kustomization ups-secrets --with-source >/dev/null 2>&1 || true
flux reconcile kustomization ups --with-source >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "T-A-ups: Phase 5/7: postconditions -- structural, then live, against the real host"

not_ready=""
i=0
while [ "$i" -lt 12 ]; do
    not_ready=$(kc get kustomizations -A -o json | jq -r '
        .items[] |
        (.status.conditions // [] | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
        select($ready != "True") |
        "\(.metadata.namespace)/\(.metadata.name) (ready=\($ready))"
    ')
    [ -z "$not_ready" ] && break
    sleep 5
    i=$((i + 1))
done
if [ -z "$not_ready" ]; then
    ok T-A-ups/kustomizations-ready "every Flux Kustomization is Ready, including ups(-secrets)"
else
    fail T-A-ups/kustomizations-ready "not Ready: $not_ready"
fi

# 5a. Structural: the exporter Deployment/Service/ServiceMonitor/PrometheusRule
# all exist, owned by this capability's own Kustomization.
dep_name=$(kc get deployment -n monitoring scrap-ups-exporter -o jsonpath='{.metadata.name}' 2>/dev/null || true)
svc_name=$(kc get service -n monitoring scrap-ups-exporter -o jsonpath='{.metadata.name}' 2>/dev/null || true)
sm_name=$(kc get servicemonitor -n monitoring scrap-ups-exporter -o jsonpath='{.metadata.name}' 2>/dev/null || true)
pr_name=$(kc get prometheusrule -n monitoring scrap-ups -o jsonpath='{.metadata.name}' 2>/dev/null || true)
if [ "$dep_name" = "scrap-ups-exporter" ] && [ "$svc_name" = "scrap-ups-exporter" ] && \
   [ "$sm_name" = "scrap-ups-exporter" ] && [ "$pr_name" = "scrap-ups" ]; then
    ok T-A-ups/objects-exist "Deployment, Service, ServiceMonitor, and PrometheusRule all exist, applied by capabilities/ups/'s own Kustomization"
else
    fail T-A-ups/objects-exist "expected all four objects to exist -- deployment='$dep_name' service='$svc_name' servicemonitor='$sm_name' prometheusrule='$pr_name'"
fi

# 5b. Structural: the exporter pod's own security posture, asserted
# directly, not merely claimed in this capability's README. Not
# runAsNonRoot -- REAL BUG, found live via this capability's own first
# two CI runs: `apk add` needs to write /lib/apk/db/, root-owned in the
# base image, so it cannot run non-root at all here, the same reason
# capabilities/dyndns/cronjob.yaml and capabilities/heartbeat/cronjob.yaml
# never set it either. What's actually asserted is what ADR-0013 actually
# requires: no privilege escalation, every capability dropped, no
# ServiceAccount token -- an ordinary unprivileged container, never
# privileged, never hostPID, never a host mount.
# jsonpath, not -o json | jq: REAL BUG, found live -- the Deployment's
# full JSON representation embeds this capability's own giant Python
# exporter script (the initContainer's command), and piping that whole
# object through jq produced 'Invalid string: control characters ... must
# be escaped' -- jsonpath extracts exactly the three scalars needed
# without round-tripping the embedded script through a second JSON
# parse at all, the same targeted-extraction shape 5a's own dep_name/
# svc_name/sm_name/pr_name checks already use successfully against this
# same object.
sa_token=$(kc get deployment -n monitoring scrap-ups-exporter -o jsonpath='{.spec.template.spec.automountServiceAccountToken}' 2>/dev/null || true)
no_escalation=$(kc get deployment -n monitoring scrap-ups-exporter -o jsonpath='{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null || true)
caps_dropped=$(kc get deployment -n monitoring scrap-ups-exporter -o jsonpath='{.spec.template.spec.containers[0].securityContext.capabilities.drop[0]}' 2>/dev/null || true)
if [ "$sa_token" = "false" ] && [ "$no_escalation" = "false" ] && [ "$caps_dropped" = "ALL" ]; then
    ok T-A-ups/exporter-unprivileged "the exporter Deployment genuinely has no ServiceAccount token, disallows privilege escalation, and drops every container capability -- structurally, not just documented"
else
    fail T-A-ups/exporter-unprivileged "expected automountServiceAccountToken=false, allowPrivilegeEscalation=false, capabilities dropped=ALL -- got token=$sa_token no_escalation=$no_escalation caps_dropped=$caps_dropped"
fi

wait_pod=$(wait_for_pod_ready monitoring "app.kubernetes.io/name=scrap-ups-exporter" 24)
if [ "$wait_pod" != ok ]; then
    fail T-A-ups/exporter-pod-ready "the exporter pod never became Ready"
    kc describe pod -n monitoring -l app.kubernetes.io/name=scrap-ups-exporter 2>&1 | sed 's/^/      /' || true
fi

# A single port-forward from this host, polled repeatedly across the rest
# of this phase -- same pattern tests/profiles/t-a-minimal.sh's own
# Alertmanager check already establishes, applied to Prometheus's own
# query API (prometheus-operated, the operator's own always-present
# Service -- capabilities/grafana/helmrelease.yaml's own datasource URL
# already names it).
kc port-forward -n monitoring svc/prometheus-operated 9098:9090 >/tmp/t-a-ups-portforward.log 2>&1 &
PF_PID=$!
sleep 3

# 5c. POSITIVE: the exporter genuinely reads the real dummy-ups driver's
# healthy state, THROUGH Prometheus's own query API -- not just that the
# objects exist.
up_val=""
ol_val=""
echo "      waiting up to 2 minutes for the first successful scrape..."
i=0
while [ "$i" -lt 24 ]; do
    up_val=$(prom_value 'nut_up')
    ol_val=$(prom_value 'nut_ups_status_flag{flag="OL"}')
    [ "$up_val" = "1" ] && [ "$ol_val" = "1" ] && break
    sleep 5
    i=$((i + 1))
done
if [ "$up_val" = "1" ] && [ "$ol_val" = "1" ]; then
    ok T-A-ups/exporter-reads-real-driver "nut_up=1 and nut_ups_status_flag{flag=\"OL\"}=1, read through Prometheus's own query API from the real dummy-ups driver"
else
    fail T-A-ups/exporter-reads-real-driver "expected nut_up=1 and OL flag=1, got nut_up='$up_val' OL='$ol_val'"
    kc logs -n monitoring -l app.kubernetes.io/name=scrap-ups-exporter --tail=50 2>&1 | sed 's/^/      /' || true
fi

# 5d. NEGATIVE CONTROL: a deliberately wrong credential makes nut_up
# genuinely drop to 0 -- "configuration errors fail visibly" proven live,
# not assumed. Secret env vars require a new pod to take effect.
kc patch secret -n monitoring ups-credentials --type merge \
    -p "{\"stringData\":{\"NUT_PASSWORD\":\"$WRONG_PASSWORD\"}}" >/dev/null
kc rollout restart deployment -n monitoring scrap-ups-exporter >/dev/null
wait_pod=$(wait_for_pod_ready monitoring "app.kubernetes.io/name=scrap-ups-exporter" 24)
if [ "$wait_pod" != ok ]; then
    fail T-A-ups/comm-lost-negative-setup "the exporter pod never became Ready after the deliberate credential break"
fi

down_val=""
echo "      waiting up to 2 minutes for a scrape reflecting the deliberately wrong credential..."
i=0
while [ "$i" -lt 24 ]; do
    down_val=$(prom_value 'nut_up')
    [ "$down_val" = "0" ] && break
    sleep 5
    i=$((i + 1))
done
if [ "$down_val" = "0" ]; then
    ok T-A-ups/comm-lost-negative-control "a deliberately wrong NUT_PASSWORD makes nut_up genuinely read 0 through Prometheus -- UPSCommunicationLost's own trigger condition is real, not aspirational"
else
    fail T-A-ups/comm-lost-negative-control "expected nut_up=0 with a deliberately wrong credential, got '$down_val'"
    kc logs -n monitoring -l app.kubernetes.io/name=scrap-ups-exporter --tail=50 2>&1 | sed 's/^/      /' || true
fi

# Restore the correct credential before the real shutdown-trigger phase
# below, which depends on the exporter genuinely reading upsd again.
kc patch secret -n monitoring ups-credentials --type merge \
    -p "{\"stringData\":{\"NUT_PASSWORD\":\"$NUT_READONLY_PASSWORD\"}}" >/dev/null
kc rollout restart deployment -n monitoring scrap-ups-exporter >/dev/null
wait_pod=$(wait_for_pod_ready monitoring "app.kubernetes.io/name=scrap-ups-exporter" 24)
restored_val=""
i=0
while [ "$i" -lt 24 ]; do
    restored_val=$(prom_value 'nut_up')
    [ "$restored_val" = "1" ] && break
    sleep 5
    i=$((i + 1))
done
if [ "$wait_pod" = ok ] && [ "$restored_val" = "1" ]; then
    ok T-A-ups/credential-restored "nut_up reads 1 again after the credential is restored"
else
    fail T-A-ups/credential-restored "expected nut_up=1 after restoring the credential, got '$restored_val' (pod ready=$wait_pod)"
fi

# ---------------------------------------------------------------------------
log "T-A-ups: Phase 6/7: the actual protective mechanism -- a real on-battery, low-battery event"

# A real, live-induced device-state change -- not a mocked signal. The
# same dummy-ups driver instance already running (Phase 3) picks this up
# from its own live-editable data file.
write_dummy_state "OB LB" 5 120

echo "      waiting up to 3 minutes for upsmon to detect the sustained on-battery, low-battery"
echo "      condition and run SHUTDOWNCMD (this profile's own sentinel-file stand-in, never a"
echo "      real poweroff -- see bootstrap/host/install-nut.sh's own NUT_SHUTDOWNCMD comment)..."
fired=""
i=0
while [ "$i" -lt 36 ]; do
    if sudo test -f "$SENTINEL"; then
        fired=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$fired" = 1 ]; then
    ok T-A-ups/shutdowncmd-fires "upsmon's own SHUTDOWNCMD genuinely fired against a real, live-induced on-battery/low-battery dummy-ups state"
else
    fail T-A-ups/shutdowncmd-fires "SHUTDOWNCMD's sentinel never appeared within 3 minutes of the simulated UPS reporting OB LB"
    sudo journalctl -u nut-monitor --no-pager 2>&1 | tail -n 60 | sed 's/^/      /' || true
fi

# 6a. The same real event, visible through the in-cluster half -- ties
# the host-level protective mechanism to the cluster's own observability
# surface, not just two independently-plausible halves.
ob_val=""
lb_val=""
i=0
while [ "$i" -lt 24 ]; do
    ob_val=$(prom_value 'nut_ups_status_flag{flag="OB"}')
    lb_val=$(prom_value 'nut_ups_status_flag{flag="LB"}')
    [ "$ob_val" = "1" ] && [ "$lb_val" = "1" ] && break
    sleep 5
    i=$((i + 1))
done
if [ "$ob_val" = "1" ] && [ "$lb_val" = "1" ]; then
    ok T-A-ups/alert-conditions-visible "the same real on-battery/low-battery event is visible through Prometheus (nut_ups_status_flag OB=1, LB=1) -- UPSOnBattery/UPSLowBattery's own trigger conditions are real"
else
    fail T-A-ups/alert-conditions-visible "expected OB=1 and LB=1 through Prometheus after the real event, got OB='$ob_val' LB='$lb_val'"
fi

kill "$PF_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
log "T-A-ups: Phase 7/7: revert both halves cleanly"

sudo -E sh bootstrap/host/uninstall-nut.sh || true
sudo rm -f "$DUMMY_DEV" "$SENTINEL"

LIVEDIR2=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR2"
rm -f "$LIVEDIR2/clusters/example/capabilities/ups.yaml" \
      "$LIVEDIR2/clusters/example/capabilities/ups-secrets.yaml"
( cd "$LIVEDIR2" && git add -A && git -c user.email=t-a-ups@localhost -c user.name="T-A-ups" \
    commit -q -m "T-A-ups: revert -- delete the ups capability's files" && git push -q origin main )
rm -rf "$LIVEDIR2"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization capabilities --with-source >/dev/null 2>&1 || true

reverted=""
i=0
while [ "$i" -lt 24 ]; do
    dep_exists=$(kc get deployment -n monitoring scrap-ups-exporter -o name 2>/dev/null || true)
    ks1_exists=$(kc get kustomization -n flux-system ups -o name 2>/dev/null || true)
    ks2_exists=$(kc get kustomization -n flux-system ups-secrets -o name 2>/dev/null || true)
    if [ -z "$dep_exists" ] && [ -z "$ks1_exists" ] && [ -z "$ks2_exists" ]; then
        reverted=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$reverted" = 1 ]; then
    ok T-A-ups/reverts-cleanly "deleting the capability's files pruned the exporter Deployment and both Kustomization objects -- T1 holds"
else
    fail T-A-ups/reverts-cleanly "expected the exporter Deployment and both Kustomizations to be gone after reverting"
fi

# ---------------------------------------------------------------------------
log "T-A-ups: result"
if [ "$status" -ne 0 ]; then
    echo "T-A-ups FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A-ups PASSED -- a real host-level NUT install genuinely runs upsmon's own SHUTDOWNCMD against a real, live-induced on-battery/low-battery dummy-ups state (with a passing negative control against a healthy UPS); the in-cluster exporter genuinely reads that same real state through Prometheus's own query API, genuinely fails visibly (nut_up=0) on a deliberately wrong credential, and reverts cleanly -- all verified live, never a mock."
