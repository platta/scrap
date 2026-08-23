#!/bin/sh
# T-A-alert-heartbeat -- live acceptance for capabilities/alert-delivery/
# and capabilities/heartbeat/, bundled into one profile the same way T-B
# bundles identity + Grafana + logs: both capabilities here are
# Alertmanager-plane-adjacent, share one ephemeral receiver, and neither
# is large enough on its own to justify a second full from-zero bootstrap.
#
# Same expectations as tests/profiles/t-a-minimal.sh: a normal user,
# passwordless sudo, a genuinely fresh host, never run this whole script
# under `sudo` itself. A SEPARATE from-zero bootstrap from T-A's own,
# same reasoning as T-B's, T-A-public-tls's, and T-A-offsite-backup's --
# this live-edits SOPS-encrypted secrets, deliberately fires a real
# alert, and deliberately scales Alertmanager to zero; it must never run
# against a cluster some other check still depends on.
#
# The webhook/ping receiver is a REAL, ephemeral HTTP listener this
# script stands up itself on the same runner -- genuine HTTP requests
# over the network, not a mock or a SCRAP-specific stand-in, the same
# "ephemeral, real target" shape capabilities/offsite-backup/'s own MinIO
# instance already establishes for a different wire protocol. A human can
# run this identically on their own scratch VM, given python3 on PATH:
#   sh tests/profiles/t-a-alert-heartbeat.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

status=0

# REAL BUG, found live via t-a-offsite-backup.sh's own first run (see
# that script's own comment at the identical choice): stay well clear of
# platform/ingress/reserved-ports.yaml's own reserved range (80/443/6443/
# 9000) and of 19000, MinIO's own port in that other profile -- these
# profiles never run concurrently against the SAME runner today, but
# there's no reason to depend on that.
RECEIVER_PORT=19100
# A fixed path, not mktemp -- so a failed CI run's own diagnostics step
# (.github/workflows/t-a-alert-heartbeat.yml) can cat it without needing
# to know a randomized name.
RECEIVER_LOG=/tmp/t-a-alert-heartbeat-requests.log
: > "$RECEIVER_LOG"

# ---------------------------------------------------------------------------
log "T-A-alert-heartbeat: Phase 0/5: environment prerequisites"
install_prereqs

# ---------------------------------------------------------------------------
log "T-A-alert-heartbeat: Phase 1/5: an ephemeral, real HTTP receiver for both webhook and heartbeat pings"
# python3 is already an install_prereqs()-adjacent given on every runner
# this project targets (GitHub's own ubuntu-latest image, and any
# operator's own scratch host per bootstrap/preflight's own documented
# minimums) -- not added to install_prereqs() itself since nothing in the
# actual PLATFORM depends on it, only this test harness.
cat > /tmp/t-a-alert-heartbeat-receiver.py <<'PYEOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

logfile, port = sys.argv[1], int(sys.argv[2])

class Handler(BaseHTTPRequestHandler):
    def _handle(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        with open(logfile, "a") as f:
            f.write("%s %s body=%r\n" % (self.command, self.path, body[:2000]))
        self.send_response(200)
        self.end_headers()
    def do_GET(self):
        self._handle()
    def do_POST(self):
        self._handle()
    def log_message(self, fmt, *args):
        pass

HTTPServer(("0.0.0.0", port), Handler).serve_forever()
PYEOF
nohup python3 /tmp/t-a-alert-heartbeat-receiver.py "$RECEIVER_LOG" "$RECEIVER_PORT" \
    >/tmp/t-a-alert-heartbeat-receiver.log 2>&1 &
RECEIVER_PID=$!

receiver_up=""
i=0
while [ "$i" -lt 20 ]; do
    if curl -sf --max-time 2 -o /dev/null "http://127.0.0.1:${RECEIVER_PORT}/probe"; then
        receiver_up=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ -z "$receiver_up" ]; then
    echo "FAIL  T-A-alert-heartbeat: the ephemeral receiver never came up -- see /tmp/t-a-alert-heartbeat-receiver.log"
    cat /tmp/t-a-alert-heartbeat-receiver.log 2>/dev/null || true
    exit 1
fi
: > "$RECEIVER_LOG"  # discard the /probe request above -- not a real check
echo "receiver up (pid $RECEIVER_PID) on port ${RECEIVER_PORT}, logging to $RECEIVER_LOG"

webhook_hits() { grep -c '^POST /webhook' "$RECEIVER_LOG" 2>/dev/null || true; }
ping_hits() { grep -c '^GET /ping\|^POST /ping' "$RECEIVER_LOG" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
log "T-A-alert-heartbeat: Phase 2/5: bootstrap/install.sh -- the real, unmodified installer"
# Identical invocation to every other live profile -- see any of their
# own comments at this exact call for the HOME=/root investigation.
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A-alert-heartbeat: bootstrap/install.sh exited non-zero -- see the"
    echo "      'Step N/7' marker above for which layer of the documented bootstrap"
    echo "      sequence failed."
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
    ok T-A-alert-heartbeat/kustomizations-ready-baseline "every Flux Kustomization is Ready before either capability is enabled"
else
    fail T-A-alert-heartbeat/kustomizations-ready-baseline "not Ready: $not_ready"
fi

NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

# ---------------------------------------------------------------------------
log "T-A-alert-heartbeat: Phase 3/5: enable both capabilities live -- exactly the documented two-file copy, each"
BARE_REPO=/var/lib/scrap/repo.git
LIVEDIR=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR"
LIVE_CLUSTER_DIR="$LIVEDIR/clusters/example"

mkdir -p "$LIVE_CLUSTER_DIR/capabilities"
cp "$REPO_ROOT/capabilities/alert-delivery/cluster-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/alert-delivery.yaml"
cp "$REPO_ROOT/capabilities/alert-delivery/cluster-secrets-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/alert-delivery-secrets.yaml"
cp "$REPO_ROOT/capabilities/heartbeat/cluster-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/heartbeat.yaml"
cp "$REPO_ROOT/capabilities/heartbeat/cluster-secrets-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/heartbeat-secrets.yaml"

# Point both secrets at the ephemeral receiver, reached from inside the
# cluster via this runner's own routable address -- the exact pattern
# P6's external-proxy example and t-a-offsite-backup.sh's own MinIO
# target already establish for reaching a runner-hosted service from a
# pod.
WEBHOOK_URL="http://${NODE_IP}:${RECEIVER_PORT}/webhook"
PING_URL="http://${NODE_IP}:${RECEIVER_PORT}/ping"

# Root-only (the operational age key install.sh generated lives at
# /etc/scrap/age/, mode 600) -- same reasoning t-a-offsite-backup.sh's
# own EDIT_SCRIPT gives for using a temp script file, not an inline
# `sudo sh -c` string, to avoid a nested-quoting hazard around the URLs.
EDIT_SCRIPT=$(mktemp)
cat > "$EDIT_SCRIPT" <<EOF
set -eu
cd '$LIVE_CLUSTER_DIR/secrets'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops --set '["stringData"]["WEBHOOK_URL"] "$WEBHOOK_URL"' alert-delivery/alert-delivery-credentials.sops.yaml
sops --set '["stringData"]["HEARTBEAT_PING_URL"] "$PING_URL"' heartbeat/heartbeat-credentials.sops.yaml
EOF
if ! sudo sh "$EDIT_SCRIPT"; then
    echo "FAIL  T-A-alert-heartbeat: could not set WEBHOOK_URL/HEARTBEAT_PING_URL in the live secrets"
    rm -f "$EDIT_SCRIPT"
    exit 1
fi
rm -f "$EDIT_SCRIPT"

( cd "$LIVEDIR" && git add -A && git -c user.email=t-a-alert-heartbeat@localhost -c user.name="T-A-alert-heartbeat" \
    commit -q -m "T-A-alert-heartbeat: enable alert-delivery and heartbeat against the ephemeral receiver" && \
    git push -q origin main )
rm -rf "$LIVEDIR"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization capabilities --with-source >/dev/null
# alert-delivery(-secrets) and heartbeat(-secrets) are newly-created
# nested Kustomizations as of the commit above -- same reasoning
# t-a-public-tls.sh's own identical comment gives for the short sleep
# before reconciling brand-new-by-name objects.
sleep 5
flux reconcile kustomization alert-delivery-secrets --with-source >/dev/null 2>&1 || true
flux reconcile kustomization alert-delivery --with-source >/dev/null 2>&1 || true
flux reconcile kustomization heartbeat-secrets --with-source >/dev/null 2>&1 || true
flux reconcile kustomization heartbeat --with-source >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "T-A-alert-heartbeat: Phase 4/5: postconditions"

# 4a. Both new Kustomizations (and everything else) reach Ready.
not_ready=$(kc get kustomizations -A -o json | jq -r '
    .items[] |
    (.status.conditions // [] | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
    select($ready != "True") |
    "\(.metadata.namespace)/\(.metadata.name) (ready=\($ready))"
')
if [ -z "$not_ready" ]; then
    ok T-A-alert-heartbeat/kustomizations-ready "every Flux Kustomization is Ready, including alert-delivery(-secrets) and heartbeat(-secrets)"
else
    fail T-A-alert-heartbeat/kustomizations-ready "not Ready: $not_ready"
fi

# 4b. Structural ground truth: the AlertmanagerConfig itself reports
# Accepted -- before trusting any delivery to have happened.
accepted=""
i=0
while [ "$i" -lt 24 ]; do
    accepted=$(kc get alertmanagerconfig -n monitoring scrap-alert-delivery \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
    [ "$accepted" = "True" ] && break
    sleep 5
    i=$((i + 1))
done
if [ "$accepted" = "True" ]; then
    ok T-A-alert-heartbeat/alertmanagerconfig-accepted "the AlertmanagerConfig object reports Accepted=True -- the Prometheus Operator genuinely merged it, not just applied it"
else
    fail T-A-alert-heartbeat/alertmanagerconfig-accepted "expected Accepted=True within 2 minutes, got '$accepted'"
    kc describe alertmanagerconfig -n monitoring scrap-alert-delivery 2>&1 | sed 's/^/      /' || true
fi

# 4c. NEGATIVE CONTROL, alert-delivery: zero deliveries before any alert
# has fired -- closes the same vacuous-pass gap
# capabilities/logs/'s own never-emitted-marker check closes for a
# different capability.
before_hits=$(webhook_hits)
if [ "${before_hits:-0}" -eq 0 ]; then
    ok T-A-alert-heartbeat/webhook-negative-control "the receiver has genuinely received zero /webhook requests before any alert has fired"
else
    fail T-A-alert-heartbeat/webhook-negative-control "expected zero /webhook hits before triggering an alert, got $before_hits -- this check is meaningless if it can't start from zero"
fi

# 4d. A real, live-fired alert reaches the configured webhook receiver.
# Same deliberately-failing-Job mechanism tests/profiles/t-a-minimal.sh's
# own alert-reaches-surface check uses -- BackupJobFailed's real, shipped
# `for: 5m` is waited out, not shortcut with a test-only rule.
FAIL_JOB="t-a-alert-heartbeat-trigger-$(date +%s)"
cat <<EOF | kc apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $FAIL_JOB
  namespace: scrap-backup
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: fail
          image: busybox:1.37.0
          command: ["false"]
EOF

echo "      waiting up to 8 minutes for BackupJobFailed to fire (its rule requires 'for: 5m') and reach the webhook (groupWait: 30s)..."
delivered=""
i=0
while [ "$i" -lt 96 ]; do
    if [ "$(webhook_hits)" -gt 0 ] 2>/dev/null; then
        delivered=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
kc delete job -n scrap-backup "$FAIL_JOB" --ignore-not-found >/dev/null 2>&1 || true

if [ "$delivered" = 1 ] && grep -q '^POST /webhook' "$RECEIVER_LOG" && grep '/webhook' "$RECEIVER_LOG" | grep -q BackupJobFailed; then
    ok T-A-alert-heartbeat/alert-delivered "a real, live-fired BackupJobFailed alert reached the ephemeral receiver as a genuine webhook POST carrying Alertmanager's own payload (alertname visible in the body)"
else
    fail T-A-alert-heartbeat/alert-delivered "the deliberately-failed job never produced a webhook delivery within 8 minutes -- see the receiver log and Alertmanager's own state"
    echo "      --- receiver log ---"
    sed 's/^/      /' "$RECEIVER_LOG" || true
fi

# 4e. Heartbeat, POSITIVE: Alertmanager is healthy (the normal state at
# this point) -- a manually triggered run genuinely pushes.
ping_before=$(ping_hits)
POS_JOB="t-a-alert-heartbeat-hb-pos-$(date +%s)"
kc create job -n monitoring "$POS_JOB" --from=cronjob/scrap-heartbeat >/dev/null
pos_result=$(wait_for_job monitoring "$POS_JOB" 12)
echo "      --- heartbeat job log (Alertmanager healthy) ---"
kc logs -n monitoring "job/$POS_JOB" 2>&1 | sed 's/^/      /' || true
ping_after=$(ping_hits)
if [ "$pos_result" = ok ] && [ "${ping_after:-0}" -gt "${ping_before:-0}" ]; then
    ok T-A-alert-heartbeat/heartbeat-pushes-when-healthy "a triggered heartbeat run, with Alertmanager healthy, genuinely reached the ephemeral receiver"
else
    fail T-A-alert-heartbeat/heartbeat-pushes-when-healthy "expected the job to succeed and ping count to increase (before=$ping_before after=$ping_after, job result=$pos_result)"
fi

# 4f. Heartbeat, NEGATIVE CONTROL -- the actual dead-man's-switch
# invariant: Alertmanager deliberately made unhealthy (scaled to zero, a
# real, live-induced condition, not a mocked response), a fresh triggered
# run must withhold the push AND still exit successfully (correctly
# withholding is success, not failure -- see capabilities/heartbeat/README.md).
kc scale statefulset -n monitoring alertmanager-kube-prometheus-stack-alertmanager --replicas=0 >/dev/null
scaled_down=$(wait_for_pod_gone monitoring "app.kubernetes.io/name=alertmanager" 24)
if [ "$scaled_down" != ok ]; then
    fail T-A-alert-heartbeat/heartbeat-negative-setup "Alertmanager's pod never actually terminated after scaling to zero -- can't run the negative control against a genuinely unhealthy Alertmanager without this"
fi

ping_before_neg=$(ping_hits)
NEG_JOB="t-a-alert-heartbeat-hb-neg-$(date +%s)"
kc create job -n monitoring "$NEG_JOB" --from=cronjob/scrap-heartbeat >/dev/null
neg_result=$(wait_for_job monitoring "$NEG_JOB" 12)
echo "      --- heartbeat job log (Alertmanager deliberately scaled to zero) ---"
kc logs -n monitoring "job/$NEG_JOB" 2>&1 | sed 's/^/      /' || true
ping_after_neg=$(ping_hits)
if [ "$neg_result" = ok ] && [ "${ping_after_neg:-0}" -eq "${ping_before_neg:-0}" ]; then
    ok T-A-alert-heartbeat/heartbeat-withholds-when-unhealthy "with Alertmanager genuinely unreachable, the heartbeat job succeeded (correct) while making ZERO requests to the receiver -- the withholding behavior is real, not merely documented"
else
    fail T-A-alert-heartbeat/heartbeat-withholds-when-unhealthy "expected the job to succeed with no new ping (before=$ping_before_neg after=$ping_after_neg, job result=$neg_result)"
fi

# Restore Alertmanager before anything downstream (including this
# script's own exit-status reporting on a shared runner) might expect a
# healthy platform.
kc scale statefulset -n monitoring alertmanager-kube-prometheus-stack-alertmanager --replicas=1 >/dev/null
restored=$(wait_for_pod_ready monitoring "app.kubernetes.io/name=alertmanager" 24)
if [ "$restored" = ok ]; then
    ok T-A-alert-heartbeat/alertmanager-restored "Alertmanager is Ready again after being scaled back up"
else
    fail T-A-alert-heartbeat/alertmanager-restored "Alertmanager never became Ready again after being scaled back to 1 replica"
fi

# 4g. Revert both capabilities, confirm T1: the objects they owned are
# gone, nothing else is affected.
LIVEDIR2=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR2"
rm -f "$LIVEDIR2/clusters/example/capabilities/alert-delivery.yaml" \
      "$LIVEDIR2/clusters/example/capabilities/alert-delivery-secrets.yaml" \
      "$LIVEDIR2/clusters/example/capabilities/heartbeat.yaml" \
      "$LIVEDIR2/clusters/example/capabilities/heartbeat-secrets.yaml"
( cd "$LIVEDIR2" && git add -A && git -c user.email=t-a-alert-heartbeat@localhost -c user.name="T-A-alert-heartbeat" \
    commit -q -m "T-A-alert-heartbeat: revert -- delete both capabilities' files" && git push -q origin main )
rm -rf "$LIVEDIR2"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization capabilities --with-source >/dev/null 2>&1 || true

# REAL BUG, found by inspection before this ever ran live: an earlier
# version of this loop counted "NotFound" lines with `grep -c` on
# combined stdout+stderr. Two problems with that shape: `grep -c` exits
# 1 (no match) while the object still legitimately exists mid-prune --
# under this script's own `set -e`, an assignment whose command
# substitution ends in a failing `grep` aborts the WHOLE SCRIPT on the
# very first poll instead of retrying; and checking two resource names
# in one `kubectl get a b` call conflates them -- one NotFound line can
# satisfy `-ge 1` while the OTHER named object still exists. Fixed by
# checking each object independently via `-o name`, which prints nothing
# (empty string, not an error) once the object is gone, and never fails
# under `set -e` because of the trailing `|| true` on each.
reverted=""
i=0
while [ "$i" -lt 24 ]; do
    am_exists=$(kc get alertmanagerconfig -n monitoring scrap-alert-delivery -o name 2>/dev/null || true)
    cj_exists=$(kc get cronjob -n monitoring scrap-heartbeat -o name 2>/dev/null || true)
    ks1_exists=$(kc get kustomization -n flux-system alert-delivery -o name 2>/dev/null || true)
    ks2_exists=$(kc get kustomization -n flux-system heartbeat -o name 2>/dev/null || true)
    if [ -z "$am_exists" ] && [ -z "$cj_exists" ] && [ -z "$ks1_exists" ] && [ -z "$ks2_exists" ]; then
        reverted=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$reverted" = 1 ]; then
    ok T-A-alert-heartbeat/reverts-cleanly "deleting both capabilities' files pruned the AlertmanagerConfig, the heartbeat CronJob, and their own Kustomization objects -- T1 holds"
else
    fail T-A-alert-heartbeat/reverts-cleanly "expected the AlertmanagerConfig, CronJob, and both Kustomizations to be gone after reverting"
fi

kill "$RECEIVER_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
log "T-A-alert-heartbeat: result"
if [ "$status" -ne 0 ]; then
    echo "T-A-alert-heartbeat FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A-alert-heartbeat PASSED -- a real, live-fired alert genuinely delivered through a webhook AlertmanagerConfig receiver with a passing negative control; the heartbeat CronJob genuinely pushes while Alertmanager is healthy and genuinely withholds the push (while still succeeding) when Alertmanager is deliberately made unhealthy; both capabilities revert cleanly -- all verified live, against a real ephemeral HTTP receiver, never a mock."
