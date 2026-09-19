#!/bin/sh
# T-A-observability-satellite -- live acceptance for
# platform/observability-satellite/ (docs/decisions/0018-observability-topology.md).
#
# Same expectations as tests/profiles/t-a-minimal.sh: a normal user,
# passwordless sudo, a genuinely fresh host, never run this whole script
# under `sudo` itself. A SEPARATE from-zero bootstrap from T-A's own, same
# reasoning as every other capability/topology profile -- this live-edits
# SOPS-encrypted secrets, deliberately breaks remote-write twice, and
# deliberately fires a real baseline alert; it must never run against a
# cluster some other check still depends on.
#
# The remote-write destination is a REAL, ephemeral, non-SCRAP Prometheus
# this script stands up itself on the same runner, in server mode with
# --web.enable-remote-write-receiver -- genuinely exercises the real
# remote-write wire protocol end to end, never a mock. It is deliberately
# a second, independent Prometheus process (not a SCRAP-authored
# stand-in), satisfying docs/decisions/0018's own "satellite mode must be
# CI-proven against a destination that is not SCRAP" requirement --
# nothing about the receiver depends on it also being Prometheus, that's
# simply the smallest real remote-write-compliant binary this project
# already needs to understand. Protected with HTTP Basic Auth via
# Prometheus's own --web.config.file (native, not a hand-rolled
# auth layer), so the bad-credential negative control is genuine: the
# receiver really does reject the wrong password, not merely simulate it.
#
# A human can run this identically on their own scratch VM, given
# python3/htpasswd on PATH (or apt, for install_prereqs()):
#   sh tests/profiles/t-a-observability-satellite.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

status=0

# 19200: outside platform/ingress/reserved-ports.yaml's own range
# (80/443/6443/9000) and distinct from 19000 (t-a-offsite-backup's MinIO)
# and 19100 (t-a-alert-heartbeat's HTTP receiver) -- same collision
# avoidance those two scripts' own comments already establish.
RECEIVER_PORT=19200
RECEIVER_DIR=$(mktemp -d)
SAT_USER="scrap-satellite-test-user"
SAT_PASS="scrap-satellite-test-password-not-secret-16ch"
PROMETHEUS_VERSION=2.54.1

query_receiver() {
    curl -sG --max-time 5 -u "${SAT_USER}:${SAT_PASS}" \
        "http://127.0.0.1:${RECEIVER_PORT}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null || true
}
receiver_value() {
    query_receiver "$1" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true
}
query_prom() {
    curl -sG --max-time 5 "http://127.0.0.1:9099/api/v1/query" --data-urlencode "query=$1" 2>/dev/null || true
}
alertmanager_firing() {
    curl -sG --max-time 5 "http://127.0.0.1:9093/api/v2/alerts" --data-urlencode "filter=alertname=\"$1\"" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
log "T-A-observability-satellite: Phase 0/6: environment prerequisites"
install_prereqs
if ! command -v htpasswd >/dev/null 2>&1; then
    apt_install apache2-utils
fi

# ---------------------------------------------------------------------------
log "T-A-observability-satellite: Phase 1/6: an ephemeral, real, non-SCRAP Prometheus remote-write receiver"
if ! command -v "$RECEIVER_DIR/prometheus" >/dev/null 2>&1; then
    PROM_TARBALL="prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
    if ! curl -sSL --connect-timeout 15 --max-time 180 \
        "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/${PROM_TARBALL}" \
        -o "$RECEIVER_DIR/${PROM_TARBALL}"; then
        echo "FAIL  T-A-observability-satellite: could not download prometheus v${PROMETHEUS_VERSION} within 180s"
        exit 1
    fi
    tar -xzf "$RECEIVER_DIR/${PROM_TARBALL}" -C "$RECEIVER_DIR" --strip-components=1
fi
if ! prom_version_output=$("$RECEIVER_DIR/prometheus" --version 2>&1); then
    echo "FAIL  T-A-observability-satellite: 'prometheus --version' failed after install -- see output below" >&2
    echo "$prom_version_output" >&2
    exit 1
fi
echo "prometheus installed: $(echo "$prom_version_output" | head -n1)"

BCRYPT_HASH=$(htpasswd -nbBC 10 "$SAT_USER" "$SAT_PASS" | cut -d: -f2)
cat > "$RECEIVER_DIR/web.yml" <<EOF
basic_auth_users:
  ${SAT_USER}: ${BCRYPT_HASH}
EOF
cat > "$RECEIVER_DIR/prometheus.yml" <<'EOF'
global:
  scrape_interval: 60s
scrape_configs: []
EOF
mkdir -p "$RECEIVER_DIR/data"

nohup "$RECEIVER_DIR/prometheus" \
    --config.file="$RECEIVER_DIR/prometheus.yml" \
    --web.config.file="$RECEIVER_DIR/web.yml" \
    --web.enable-remote-write-receiver \
    --web.listen-address=":${RECEIVER_PORT}" \
    --storage.tsdb.path="$RECEIVER_DIR/data" \
    >/tmp/t-a-observability-satellite-receiver.log 2>&1 &
RECEIVER_PID=$!

receiver_up=""
i=0
while [ "$i" -lt 30 ]; do
    if curl -sf --max-time 2 -u "${SAT_USER}:${SAT_PASS}" \
        "http://127.0.0.1:${RECEIVER_PORT}/-/ready" >/dev/null 2>&1; then
        receiver_up=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ -z "$receiver_up" ]; then
    echo "FAIL  T-A-observability-satellite: the ephemeral receiver never came up -- see /tmp/t-a-observability-satellite-receiver.log"
    cat /tmp/t-a-observability-satellite-receiver.log 2>/dev/null || true
    exit 1
fi
echo "receiver up (pid $RECEIVER_PID) on port ${RECEIVER_PORT}"

# NEGATIVE CONTROL, wrong credential against the receiver itself, BEFORE
# anything real is enabled -- proves Basic Auth is genuinely enforced, not
# merely configured, before this script relies on it for the later
# in-satellite bad-credential control.
if curl -sf --max-time 3 -u "${SAT_USER}:wrong-password" \
    "http://127.0.0.1:${RECEIVER_PORT}/-/ready" >/dev/null 2>&1; then
    fail T-A-observability-satellite/receiver-auth-enforced "the ephemeral receiver accepted a wrong password -- Basic Auth is not genuinely enforced"
else
    ok T-A-observability-satellite/receiver-auth-enforced "the ephemeral receiver genuinely rejects a wrong password"
fi

# ---------------------------------------------------------------------------
log "T-A-observability-satellite: Phase 2/6: bootstrap/install.sh -- the real, unmodified installer, standalone"
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A-observability-satellite: bootstrap/install.sh exited non-zero -- see the"
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
    ok T-A-observability-satellite/kustomizations-ready-baseline "every Flux Kustomization is Ready before satellite topology is selected"
else
    fail T-A-observability-satellite/kustomizations-ready-baseline "not Ready: $not_ready"
fi

baseline_rw=$(kc get prometheus -n monitoring kube-prometheus-stack-prometheus -o jsonpath='{.spec.remoteWrite}' 2>/dev/null || true)
if [ -z "$baseline_rw" ]; then
    ok T-A-observability-satellite/baseline-standalone "the Prometheus CR has no remoteWrite before satellite topology is selected -- standalone is genuinely the default"
else
    fail T-A-observability-satellite/baseline-standalone "expected empty spec.remoteWrite before enabling satellite, got: $baseline_rw"
fi

NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
REMOTE_WRITE_URL="http://${NODE_IP}:${RECEIVER_PORT}/api/v1/write"

# ---------------------------------------------------------------------------
log "T-A-observability-satellite: Phase 3/6: enable satellite topology live -- exactly the documented replace-plus-add path"
BARE_REPO=/var/lib/scrap/repo.git
LIVEDIR=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR"
LIVE_CLUSTER_DIR="$LIVEDIR/clusters/example"

# REPLACE platform-observability.yaml's content -- README.md's own "not an
# addition" distinction from every other capability's file-copy shape.
cp "$REPO_ROOT/platform/observability-satellite/cluster-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/platform-observability.yaml"

# ADD the new secrets Kustomization pointer + list it as a resource.
cp "$REPO_ROOT/platform/observability-satellite/cluster-secrets-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/platform-observability-satellite-secrets.yaml"
sed -i 's/^  - platform-observability-config.yaml$/  - platform-observability-config.yaml\n  - platform-observability-satellite-secrets.yaml/' \
    "$LIVE_CLUSTER_DIR/kustomization.yaml"

sed -i "s|^\(  SATELLITE_REMOTE_WRITE_URL: \).*|\1\"${REMOTE_WRITE_URL}\"|" "$LIVE_CLUSTER_DIR/instance-config.yaml"

# CREATE (not edit -- README.md's own stated deviation from every other
# capability's pre-shipped placeholder) the credential secret, root-only
# (the operational age key lives at /etc/scrap/age/, mode 600) -- same
# temp-script-file reasoning every other live secret edit in this
# repository gives for avoiding a nested-quoting hazard.
mkdir -p "$LIVE_CLUSTER_DIR/secrets/observability-satellite"
cat > "$LIVE_CLUSTER_DIR/secrets/observability-satellite/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - observability-satellite-credentials.sops.yaml
EOF
# Written directly under its FINAL name (still plaintext at this point) --
# see the REAL BUG comment below for why.
cat > "$LIVE_CLUSTER_DIR/secrets/observability-satellite/observability-satellite-credentials.sops.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: observability-satellite-credentials
  namespace: monitoring
stringData:
  SATELLITE_REMOTE_WRITE_USERNAME: "${SAT_USER}"
  SATELLITE_REMOTE_WRITE_PASSWORD: "${SAT_PASS}"
EOF

# REAL BUG (second attempt at this fix; the first, cd-depth-based theory
# was wrong -- .sops.yaml's own header comment says the match is against
# the path relative to ITS OWN directory, not the caller's cwd, so cd
# depth was never the actual cause). `sops -e plaintext.yaml >
# plaintext.sops.yaml` never gives sops the OUTPUT filename at all -- shell
# redirection happens in the shell, invisible to the sops process, which
# only ever sees the INPUT argument "plaintext.yaml" for its own
# creation_rules matching. That path does not end in ".sops.yaml", so
# `path_regex: secrets/.*\.sops\.ya?ml$` genuinely never matches --
# "no matching creation rules found" was correct, not spurious: sops was
# telling the truth about the (wrong) path it was actually asked to
# match. Fixed by giving the plaintext file its FINAL name up front and
# encrypting it in place (`-i`) instead of redirecting -- sops then sees
# and matches against the real, correct, already-".sops.yaml" path.
EDIT_SCRIPT=$(mktemp)
cat > "$EDIT_SCRIPT" <<EOF
set -eu
cd '$LIVE_CLUSTER_DIR/secrets'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops -e -i observability-satellite/observability-satellite-credentials.sops.yaml
EOF
if ! sudo sh "$EDIT_SCRIPT"; then
    echo "FAIL  T-A-observability-satellite: could not create the satellite credential secret"
    rm -f "$EDIT_SCRIPT"
    exit 1
fi
rm -f "$EDIT_SCRIPT"

( cd "$LIVEDIR" && git add -A && git -c user.email=t-a-observability-satellite@localhost -c user.name="T-A-observability-satellite" \
    commit -q -m "T-A-observability-satellite: enable satellite topology against the ephemeral receiver" && \
    git push -q origin main )
rm -rf "$LIVEDIR" || true

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
sleep 5
flux reconcile kustomization observability-satellite-secrets --with-source >/dev/null 2>&1 || true
flux reconcile kustomization platform-observability --with-source >/dev/null 2>&1 || true
flux reconcile kustomization platform-observability-config --with-source >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "T-A-observability-satellite: Phase 4/6: postconditions -- structural, then a real positive delivery"

not_ready=""
i=0
while [ "$i" -lt 24 ]; do
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
    ok T-A-observability-satellite/kustomizations-ready "every Flux Kustomization is Ready, including observability-satellite-secrets"
else
    fail T-A-observability-satellite/kustomizations-ready "not Ready: $not_ready"
fi

new_rw=$(kc get prometheus -n monitoring kube-prometheus-stack-prometheus -o jsonpath='{.spec.remoteWrite[0].url}' 2>/dev/null || true)
if [ "$new_rw" = "$REMOTE_WRITE_URL" ]; then
    ok T-A-observability-satellite/destination-swapped "the Prometheus CR's spec.remoteWrite genuinely resolved to the ephemeral receiver's URL"
else
    fail T-A-observability-satellite/destination-swapped "expected spec.remoteWrite[0].url='$REMOTE_WRITE_URL', got '$new_rw'"
fi

if kc get prometheusrule -n monitoring satellite-remote-write-health >/dev/null 2>&1; then
    ok T-A-observability-satellite/f3-rule-exists "the F3 telemetry-path-health PrometheusRule is applied by this topology's own Kustomization"
else
    fail T-A-observability-satellite/f3-rule-exists "expected the satellite-remote-write-health PrometheusRule to exist in the monitoring namespace"
fi

retention=$(kc get prometheus -n monitoring kube-prometheus-stack-prometheus -o jsonpath='{.spec.retention}' 2>/dev/null || true)
storage=$(kc get prometheus -n monitoring kube-prometheus-stack-prometheus -o jsonpath='{.spec.storage.volumeClaimTemplate.spec.resources.requests.storage}' 2>/dev/null || true)
if [ "$retention" = "6h" ] && [ "$storage" = "1Gi" ]; then
    ok T-A-observability-satellite/values-delta-applied "retention=6h and storage=1Gi genuinely reached the Prometheus CR -- the values-patch delta took effect, not just the remote-write addition"
else
    fail T-A-observability-satellite/values-delta-applied "expected retention=6h storage=1Gi, got retention='$retention' storage='$storage'"
fi

# NEGATIVE CONTROL: zero requests reached the receiver until this point --
# proves the earlier readiness probe (a bare GET, not a remote-write POST)
# didn't itself satisfy the positive check below.
before_samples=$(receiver_value 'prometheus_build_info')
if [ -z "$before_samples" ]; then
    ok T-A-observability-satellite/receiver-negative-control "the ephemeral receiver genuinely has zero samples before remote-write has had a chance to deliver"
else
    fail T-A-observability-satellite/receiver-negative-control "expected no samples at the receiver yet, found prometheus_build_info=$before_samples"
fi

# POSITIVE, independently observed: the receiver's OWN query API shows a
# real series, tagged with this instance's real external label -- not
# inferred from the satellite's own reported queue state.
delivered=""
echo "      waiting up to 3 minutes for the first real remote-write delivery..."
i=0
while [ "$i" -lt 36 ]; do
    v=$(receiver_value 'prometheus_build_info{scrap_instance="example"}')
    if [ -n "$v" ]; then
        delivered=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$delivered" = 1 ]; then
    ok T-A-observability-satellite/remote-write-delivers "the ephemeral, non-SCRAP receiver's own query API independently confirms a real series (prometheus_build_info) tagged scrap_instance=\"example\" -- genuine remote-write delivery, not inferred from the satellite's own reported state"
else
    fail T-A-observability-satellite/remote-write-delivers "no series with the scrap_instance=\"example\" external label ever appeared at the receiver within 3 minutes"
    echo "      --- receiver log tail ---"
    tail -n 40 /tmp/t-a-observability-satellite-receiver.log 2>/dev/null | sed 's/^/      /' || true
fi

# ---------------------------------------------------------------------------
log "T-A-observability-satellite: Phase 5/6: negative controls"

kc port-forward -n monitoring svc/prometheus-operated 9099:9090 >/tmp/t-a-observability-satellite-pf-prom.log 2>&1 &
PF_PROM_PID=$!
kc port-forward -n monitoring svc/alertmanager-operated 9093:9093 >/tmp/t-a-observability-satellite-pf-am.log 2>&1 &
PF_AM_PID=$!
sleep 3

# 5a. NEGATIVE CONTROL: a deliberately wrong remote-write credential fails
# VISIBLY -- SatelliteRemoteWriteFailing genuinely fires, not silently
# swallowed.
LIVEDIR2=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR2"
EDIT_SCRIPT2=$(mktemp)
cat > "$EDIT_SCRIPT2" <<EOF
set -eu
cd '$LIVEDIR2/clusters/example/secrets/observability-satellite'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops --set '["stringData"]["SATELLITE_REMOTE_WRITE_PASSWORD"] "deliberately-wrong-password"' observability-satellite-credentials.sops.yaml
EOF
sudo sh "$EDIT_SCRIPT2"
rm -f "$EDIT_SCRIPT2"
( cd "$LIVEDIR2" && git add -A && git -c user.email=t-a-observability-satellite@localhost -c user.name="T-A-observability-satellite" \
    commit -q -m "T-A-observability-satellite: NEGATIVE CONTROL -- deliberately wrong remote-write password" && \
    git push -q origin main )
rm -rf "$LIVEDIR2" || true
flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization observability-satellite-secrets --with-source >/dev/null 2>&1 || true

bad_cred_result=""
echo "      waiting up to 8 minutes for SatelliteRemoteWriteFailing to fire (its rule requires 'for: 3m', plus config-reload propagation time)..."
i=0
while [ "$i" -lt 96 ]; do
    if alertmanager_firing SatelliteRemoteWriteFailing | grep -q '"state":"active"'; then
        bad_cred_result=ok
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$bad_cred_result" = ok ]; then
    ok T-A-observability-satellite/bad-credential-fails-visibly "a deliberately wrong remote-write password made SatelliteRemoteWriteFailing genuinely fire and reach Alertmanager"
else
    fail T-A-observability-satellite/bad-credential-fails-visibly "SatelliteRemoteWriteFailing never reached firing state within 8 minutes after the credential was broken"
fi

# Revert the credential before the path-outage control below, so only one
# failure mode is active at a time.
LIVEDIR3=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR3"
EDIT_SCRIPT3=$(mktemp)
cat > "$EDIT_SCRIPT3" <<EOF
set -eu
cd '$LIVEDIR3/clusters/example/secrets/observability-satellite'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops --set '["stringData"]["SATELLITE_REMOTE_WRITE_PASSWORD"] "${SAT_PASS}"' observability-satellite-credentials.sops.yaml
EOF
sudo sh "$EDIT_SCRIPT3"
rm -f "$EDIT_SCRIPT3"
( cd "$LIVEDIR3" && git add -A && git -c user.email=t-a-observability-satellite@localhost -c user.name="T-A-observability-satellite" \
    commit -q -m "T-A-observability-satellite: revert -- restore correct remote-write password" && \
    git push -q origin main )
rm -rf "$LIVEDIR3" || true
flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization observability-satellite-secrets --with-source >/dev/null 2>&1 || true

# 5b. NEGATIVE CONTROL: an induced path outage (the ephemeral receiver
# killed outright -- indistinguishable from a real destination failure,
# ADR-0018's own F3/F4 boundary) genuinely fires SatelliteRemoteWriteStale
# AND local baseline alerting keeps working throughout, proving the
# alerting invariant is topology-invariant, not merely documented as such.
kill "$RECEIVER_PID" 2>/dev/null || true

FAIL_JOB="t-a-observability-satellite-trigger-$(date +%s)"
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

path_outage_result=""
local_alert_result=""
echo "      waiting up to 8 minutes for SatelliteRemoteWriteStale AND the local BackupJobFailed rule to both fire..."
i=0
while [ "$i" -lt 96 ]; do
    if [ -z "$path_outage_result" ] && alertmanager_firing SatelliteRemoteWriteStale | grep -q '"state":"active"'; then
        path_outage_result=ok
    fi
    if [ -z "$local_alert_result" ] && alertmanager_firing BackupJobFailed | grep -q '"state":"active"'; then
        local_alert_result=ok
    fi
    [ "$path_outage_result" = ok ] && [ "$local_alert_result" = ok ] && break
    sleep 5
    i=$((i + 1))
done
kc delete job -n scrap-backup "$FAIL_JOB" --ignore-not-found >/dev/null 2>&1 || true

if [ "$path_outage_result" = ok ]; then
    ok T-A-observability-satellite/path-outage-fires-visibly "killing the remote-write destination outright made SatelliteRemoteWriteStale genuinely fire (F3/F4 -- indistinguishable from the satellite's own perspective, per ADR-0018)"
else
    fail T-A-observability-satellite/path-outage-fires-visibly "SatelliteRemoteWriteStale never reached firing state within 8 minutes after the receiver was killed"
fi
if [ "$local_alert_result" = ok ]; then
    ok T-A-observability-satellite/local-alerting-unaffected "a real, live-fired baseline alert (BackupJobFailed) still reached the LOCAL Alertmanager while remote-write was genuinely broken -- the alerting invariant is topology-invariant, not merely documented"
else
    fail T-A-observability-satellite/local-alerting-unaffected "BackupJobFailed never reached firing state locally while remote-write was broken -- the alerting invariant would be topology-dependent, contradicting ADR-0018"
fi

kill "$PF_PROM_PID" 2>/dev/null || true
kill "$PF_AM_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
log "T-A-observability-satellite: Phase 6/6: revert -- restore standalone, confirm T1"
LIVEDIR4=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR4"
LIVE_CLUSTER_DIR4="$LIVEDIR4/clusters/example"
cp "$REPO_ROOT/clusters/example/platform-observability.yaml" "$LIVE_CLUSTER_DIR4/platform-observability.yaml"
rm -f "$LIVE_CLUSTER_DIR4/platform-observability-satellite-secrets.yaml"
rm -rf "$LIVE_CLUSTER_DIR4/secrets/observability-satellite"
sed -i '/^  - platform-observability-satellite-secrets.yaml$/d' "$LIVE_CLUSTER_DIR4/kustomization.yaml"
sed -i "s|^\(  SATELLITE_REMOTE_WRITE_URL: \).*|\1\"https://observability.example.internal/api/v1/write\"|" \
    "$LIVE_CLUSTER_DIR4/instance-config.yaml"
( cd "$LIVEDIR4" && git add -A && git -c user.email=t-a-observability-satellite@localhost -c user.name="T-A-observability-satellite" \
    commit -q -m "T-A-observability-satellite: revert -- restore standalone topology" && \
    git push -q origin main )
rm -rf "$LIVEDIR4" || true

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization platform-observability --with-source >/dev/null 2>&1 || true

reverted=""
i=0
while [ "$i" -lt 24 ]; do
    rw_after=$(kc get prometheus -n monitoring kube-prometheus-stack-prometheus -o jsonpath='{.spec.remoteWrite}' 2>/dev/null || true)
    secrets_ks_gone=$(kc get kustomization -n flux-system observability-satellite-secrets -o name 2>/dev/null || true)
    if [ -z "$rw_after" ] && [ -z "$secrets_ks_gone" ]; then
        reverted=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$reverted" = 1 ]; then
    ok T-A-observability-satellite/reverts-cleanly "reverting removed spec.remoteWrite and pruned the observability-satellite-secrets Kustomization -- T1 holds"
else
    fail T-A-observability-satellite/reverts-cleanly "expected spec.remoteWrite empty and observability-satellite-secrets Kustomization gone after reverting"
fi

# ---------------------------------------------------------------------------
log "T-A-observability-satellite: result"
if [ "$status" -ne 0 ]; then
    echo "T-A-observability-satellite FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A-observability-satellite PASSED -- satellite topology genuinely delivers to a real, non-SCRAP remote-write receiver (independently confirmed via the receiver's own query API), the values-delta (retention/storage/remoteWrite) genuinely reached the Prometheus CR, a bad credential and an induced path outage both fail visibly through the new F3 telemetry-path-health rule, local baseline alerting keeps working throughout a genuine remote-write outage, and reverting to standalone is clean -- all verified live."
