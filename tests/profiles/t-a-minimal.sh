#!/bin/sh
# T-A -- Minimal acceptance profile. See tests/profiles/README.md for what
# this is required to prove. Run as a normal user with passwordless sudo
# (the same expectation bootstrap/install.sh itself already has) against a
# genuinely fresh host -- a disposable VM, or a single-use CI runner; this
# script does not know or care which. Do not run the whole script under
# `sudo` itself -- it escalates only where install.sh and cluster access
# actually need it, the same least-privilege shape this project's own
# manual scratch-VM sessions have always used.
#
# This is not a CI-specific installation path. It runs the exact same
# bootstrap/install.sh a real operator runs, the exact same way
# docs/core/bootstrap-lifecycle.md documents, then mechanically re-checks
# the exact postconditions this project's own manual live-validation
# sessions have already proven by hand -- the destructive-restore
# procedure in step 2f is docs/runbooks/README.md's own five-step
# procedure, encoded verbatim, not reinvented for CI convenience.
#
# Covers every application pattern the *minimal* profile actually ships
# (P1, P4, P5, P6 -- see apps/examples/kustomization.yaml). P2 and P3 need
# capabilities/identity/, which the minimal profile deliberately doesn't
# have; see tests/profiles/t-b-standard.sh for those.
#
# A human can run this identically on their own scratch VM to reproduce a
# CI failure locally:
#   sh tests/profiles/t-a-minimal.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

BASE_DOMAIN=$(cfg_value BASE_DOMAIN)
INSTANCE_NAME=$(cfg_value INSTANCE_NAME)
status=0

# ---------------------------------------------------------------------------
log "T-A: Phase 0/4: environment prerequisites"
install_prereqs

# NODE_IP is needed before bootstrap now, not just after it: P6's setup
# below points the shipped example's external-backend address at this
# runner itself, so it has to be known before clusters/example/
# instance-config.yaml is edited and committed by install.sh.
NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

# ---------------------------------------------------------------------------
log "T-A: Phase 1/4: stand up a real external backend for P6"
# apps/examples/p6-external-proxy/ ships pointed at an RFC 5737
# documentation address on purpose -- its own README says plainly that
# until you replace it with a real device's address, "this example
# demonstrates the shape of the pattern, not a working proxy." A resource-
# readiness check can't tell the difference between that placeholder shape
# and a genuinely working proxy; only pointing it at something real and
# then reading real content back through it can. This starts a plain,
# non-Kubernetes HTTP server on the runner's own primary interface --
# exactly what a real NAS or router admin UI would be from the cluster's
# point of view: a device with an address on the LAN, but no SCRAP-managed
# code and no cluster involvement at all. It listens on a non-standard
# port, not 80, because 80 on this same host is already claimed by
# Traefik's own ServiceLB hostPort binding once bootstrap runs -- a real,
# unavoidable collision on a single-machine test host that a real
# multi-device LAN never has. EXAMPLE_P6_BACKEND_PORT (see
# instance-config.yaml and endpointslice.yaml) exists so this is a normal,
# generally-useful configuration knob, not a CI-only fork of the example.
P6_BACKEND_PORT=18080
P6_MARKER="t-a-p6-marker-$(date +%s)-$$"
P6_WEBROOT=$(mktemp -d)
echo "$P6_MARKER" > "$P6_WEBROOT/index.html"
( cd "$P6_WEBROOT" && exec python3 -m http.server "$P6_BACKEND_PORT" --bind 0.0.0.0 >/tmp/t-a-p6-backend.log 2>&1 ) &
P6_BACKEND_PID=$!
sleep 1

sed -i "s|^\(  EXAMPLE_P6_BACKEND_ADDRESS: \).*|\1\"$NODE_IP\"|" "$INSTANCE_CONFIG"
if grep -q '^  EXAMPLE_P6_BACKEND_PORT:' "$INSTANCE_CONFIG"; then
    sed -i "s|^\(  EXAMPLE_P6_BACKEND_PORT: \).*|\1\"$P6_BACKEND_PORT\"|" "$INSTANCE_CONFIG"
else
    printf '  EXAMPLE_P6_BACKEND_PORT: "%s"\n' "$P6_BACKEND_PORT" >> "$INSTANCE_CONFIG"
fi

# ---------------------------------------------------------------------------
log "T-A: Phase 2/4: bootstrap/install.sh -- the real, unmodified installer"
# SCRAP_ESCROW_CONFIRMED=1 is install.sh's own documented mechanism for a
# non-interactive shell (docs/core/bootstrap-lifecycle.md step 3) -- not a
# CI-specific bypass invented here. Everything else is left at its
# documented default: REPO_URL unset (the D5 local-bare-repo minimum
# path), CLUSTER_PATH the checked-in clusters/example/ -- with the one
# instance-config edit above, which install.sh's own "cp -a $REPO_ROOT/."
# step (see bootstrap/install.sh Step 5/7) carries straight into what gets
# committed and reconciled, the same as any real operator's own edit
# would.
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A: bootstrap/install.sh exited non-zero -- see the 'Step N/7' marker"
    echo "      above for which layer of the documented bootstrap sequence failed."
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ---------------------------------------------------------------------------
log "T-A: Phase 3/4: T-A postconditions"

# 2a. Every Flux Kustomization Ready -- install.sh's own postflight.sh
# already waited for this; re-check explicitly here so a CI failure names
# this specific postcondition rather than relying on postflight's exit
# code (which install.sh deliberately ignores with '|| true').
not_ready=$(kc get kustomizations -A --no-header 2>/dev/null | awk -F'\t' '{gsub(/ /,"",$5); if ($5!="True") print $2}')
if [ -z "$not_ready" ]; then
    ok T-A/kustomizations-ready "every Flux Kustomization is Ready"
else
    fail T-A/kustomizations-ready "not Ready: $not_ready"
fi
kc get kustomizations -A || true

# 2b. The gap tests/profiles/README.md itself already found: a live value
# check, not just that Helm accepted the values without error.
svc_type=$(kc get svc -n traefik traefik -o jsonpath='{.spec.type}' 2>/dev/null || true)
if [ "$svc_type" = "LoadBalancer" ]; then
    ok T-A/traefik-service-type "traefik Service is genuinely type LoadBalancer"
else
    fail T-A/traefik-service-type "traefik Service type is '$svc_type', expected LoadBalancer"
fi

# 2c. The private CA issued the one wildcard certificate.
cert_ready=$(kc get certificate -n traefik scrap-wildcard \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$cert_ready" = "True" ]; then
    ok T-A/wildcard-certificate "scrap-wildcard Certificate is Ready (private CA issued it)"
else
    fail T-A/wildcard-certificate "scrap-wildcard Certificate Ready condition is '$cert_ready'"
fi

# Export the CA root ourselves (not relying on postflight's $HOME, which
# under `sudo` is root's home, not necessarily this shell's) -- the exact
# secret bootstrap/postflight.sh itself reads.
CA_CERT=/tmp/t-a-scrap-ca.crt
kc get secret -n cert-manager scrap-ca-key-pair -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d > "$CA_CERT" || true

# 2d. P1 reachable over TLS, trusting only the platform's real CA -- never -k.
p1_body=$(curl -s --max-time 15 --cacert "$CA_CERT" \
    --resolve "p1.${BASE_DOMAIN}:443:${NODE_IP}" \
    "https://p1.${BASE_DOMAIN}/" 2>&1 || true)
if echo "$p1_body" | grep -q "Hostname:"; then
    ok T-A/p1-reachable "p1.${BASE_DOMAIN} reachable over HTTPS through the real private CA"
else
    fail T-A/p1-reachable "unexpected response from p1.${BASE_DOMAIN}: $(echo "$p1_body" | head -3)"
fi

# 2d2. P4 -- raw TCP round trip through the LoadBalancer Service, bypassing
# the Gateway entirely (that's the pattern's whole point: not every
# protocol is HTTP). alpine/socat's whole job is TCP-LISTEN -> EXEC:/bin/cat,
# so whatever bytes go in come back unchanged -- a behavioral proof the
# byte stream genuinely round-tripped through ServiceLB into the pod and
# back, not just that the Service/pod exist and are Ready.
P4_MARKER="t-a-p4-$(date +%s)-$$"
p4_echo=$(printf '%s\n' "$P4_MARKER" | timeout 5 nc "$NODE_IP" 9000 2>/dev/null || true)
if [ "$p4_echo" = "$P4_MARKER" ]; then
    ok T-A/p4-raw-tcp "raw TCP byte stream round-tripped through the LoadBalancer Service into the pod and back"
else
    fail T-A/p4-raw-tcp "expected '$P4_MARKER' echoed back on port 9000, got '$p4_echo'"
fi

# 2d3. P6 -- the platform's TLS/routing story holding for a backend that
# isn't a Kubernetes workload at all. Reads back the actual marker the
# real external-like backend served in Phase 1/4, through the platform's
# Gateway and TLS -- proof Traefik genuinely proxied to that address, not
# just that the Service/EndpointSlice/HTTPRoute objects exist and are
# Accepted.
p6_body=$(curl -s --max-time 15 --cacert "$CA_CERT" \
    --resolve "p6.${BASE_DOMAIN}:443:${NODE_IP}" \
    "https://p6.${BASE_DOMAIN}/" 2>&1 || true)
if echo "$p6_body" | grep -q "$P6_MARKER"; then
    ok T-A/p6-external-proxy "p6.${BASE_DOMAIN} proxied through to the real external backend's own content"
else
    fail T-A/p6-external-proxy "expected marker '$P6_MARKER' from p6.${BASE_DOMAIN}, got: $(echo "$p6_body" | head -3)"
fi
kill "$P6_BACKEND_PID" 2>/dev/null || true

# 2e. Backup to local path -- trigger a real run against the whole
# labelled-PVC set (P5's redis included) and confirm it succeeds.
BACKUP_JOB="t-a-backup-$(date +%s)"
kc create job -n scrap-backup "$BACKUP_JOB" --from=cronjob/scrap-backup >/dev/null
backup_result=$(wait_for_job scrap-backup "$BACKUP_JOB" 24)
if [ "$backup_result" = ok ]; then
    ok T-A/backup-runs "backup job completed successfully (credentials, repository, discovery all working)"
else
    fail T-A/backup-runs "backup job did not succeed -- see: kubectl logs -n scrap-backup job/$BACKUP_JOB"
    kc logs -n scrap-backup "job/$BACKUP_JOB" || true
fi

# 2f. Destructive restore, verified by a specific named value -- exactly
# docs/runbooks/README.md's "Single-application destructive restore"
# procedure, against apps/examples/p5-stateful-backup/'s Redis, including
# the ordering fix that procedure itself documents finding live: the
# whole tier touching the data must be scaled to zero before restoring,
# not just deleted from.
CANARY="t-a-canary-$(date +%s)-$$"
kc exec -n scrap-examples deploy/p5-redis -- redis-cli SET t-a-canary "$CANARY" >/dev/null
# Sanity check the write actually landed before we trust anything downstream
# of it -- if this doesn't come back, the bug is in this SET, not in backup
# or restore.
preflight_check=$(kc exec -n scrap-examples deploy/p5-redis -- redis-cli GET t-a-canary 2>/dev/null || true)
if [ "$preflight_check" != "$CANARY" ]; then
    echo "WARN  T-A/destructive-restore: canary SET didn't read back immediately (got '$preflight_check') -- continuing anyway to see what backup/restore do"
fi

RESTORE_JOB="t-a-restore-$(date +%s)"
kc create job -n scrap-backup "${RESTORE_JOB}-backup" --from=cronjob/scrap-backup >/dev/null
wait_for_job scrap-backup "${RESTORE_JOB}-backup" 24 >/dev/null
# Diagnostic evidence, always -- not just on outright job failure. A job
# that exits 0 but restores the wrong content (the actual failure this is
# guarding against) previously left zero evidence of what the backup step
# itself saw and did.
echo "      --- backup-trigger job log (job/${RESTORE_JOB}-backup) ---"
kc logs -n scrap-backup "job/${RESTORE_JOB}-backup" 2>&1 | sed 's/^/      /' || true

PVC_NAME=p5-redis-data
PV_NAME=$(kc get pvc -n scrap-examples "$PVC_NAME" -o jsonpath='{.spec.volumeName}')
HOST_PATH=$(kc get pv "$PV_NAME" -o jsonpath='{.spec.local.path}')

# REAL BUG, found by this script's first genuinely-from-zero run: the
# backup job (platform/backup/scripts-configmap.yaml) mounts the host
# storage root at /hostdata and passes restic the path AFTER translating
# it to that mountpoint (`sed "s#^$storage_root#$mount_root#"`) -- so
# every snapshot's recorded Paths is /hostdata/pvc-..., never the raw
# spec.local.path value. A restic restore --path filter matches the
# snapshot's recorded Paths exactly, so passing the untranslated host path
# here always failed with "no snapshot found", even though the snapshot
# genuinely existed. The restore job below mounts the same host directory
# at the same /hostdata mountpoint the backup job uses (copied from
# backup-cronjob.yaml, as docs/runbooks/README.md's step 5 already says to
# do) -- this translation makes --path match what's actually in the
# repository, and --target=/ then writes the restored files back through
# that same bind mount onto the real host path.
STORAGE_ROOT="/var/lib/rancher/k3s/storage"
MOUNT_ROOT="/hostdata"
RESTORE_PATH=$(printf '%s' "$HOST_PATH" | sed "s#^$STORAGE_ROOT#$MOUNT_ROOT#")

kc scale -n scrap-examples deploy/p5-redis --replicas=0
kc wait -n scrap-examples --for=delete pod -l app=p5-redis --timeout=60s >/dev/null 2>&1 || true

cat <<EOF | kc apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $RESTORE_JOB
  namespace: scrap-backup
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: restore
          image: restic/restic:0.19.1
          # ls -la after the restore, not a separate `kubectl exec` into
          # the redis pod later -- REAL BUG under active investigation:
          # restic reports a genuine, correctly-sized restore every time,
          # but the canary never comes back. If redis is crash-looping on
          # the restored file (corrupt RDB, an ownership/permission
          # mismatch, or an AOF file taking precedence over the RDB this
          # restore actually wrote), a `kubectl exec` moments later can
          # race a container restart and report a misleading "container
          # not found" instead of real evidence. This runs inside the
          # restore Job itself, immediately after restic exits, so
          # there's no window for anything else to touch the directory
          # first.
          command:
            - sh
            - -c
            - restic restore latest --host=$INSTANCE_NAME --path=$RESTORE_PATH --target=/ && echo '--- restored directory contents ---' && ls -la $RESTORE_PATH
          env:
            - name: RESTIC_REPOSITORY
              value: "local:/var/lib/scrap-backup"
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef: { name: restic-credentials, key: RESTIC_PASSWORD }
          volumeMounts:
            - { name: hostdata, mountPath: /hostdata }
            - { name: repo, mountPath: /var/lib/scrap-backup }
      volumes:
        - name: hostdata
          hostPath: { path: /var/lib/rancher/k3s/storage, type: Directory }
        - name: repo
          hostPath: { path: /var/lib/scrap-backup, type: Directory }
EOF
restore_result=$(wait_for_job scrap-backup "$RESTORE_JOB" 20)
echo "      --- restic restore job log (job/$RESTORE_JOB) ---"
kc logs -n scrap-backup "job/$RESTORE_JOB" 2>&1 | sed 's/^/      /' || true

kc scale -n scrap-examples deploy/p5-redis --replicas=1
kc wait -n scrap-examples --for=condition=Ready pod -l app=p5-redis --timeout=60s >/dev/null 2>&1 || true

if [ "$restore_result" = ok ]; then
    restored=$(kc exec -n scrap-examples deploy/p5-redis -- redis-cli GET t-a-canary 2>/dev/null || true)
    if [ "$restored" = "$CANARY" ]; then
        ok T-A/destructive-restore "the exact canary value round-tripped through destroy -> restic restore -> the original app"
    else
        fail T-A/destructive-restore "restore job succeeded but the canary value did not come back (got '$restored', wanted '$CANARY')"
        # `kubectl exec` here, in earlier runs of this same investigation,
        # raced a redis crash-loop and only ever reported "container not
        # found" -- `kubectl logs` doesn't have that race (it reads the
        # (possibly-restarted) container's own history, not a live
        # connection to a specific instance of it), so use that instead
        # for what's actually the decisive evidence here: did redis log a
        # real startup error loading the restored file?
        echo "      --- redis pod's own log, for comparison ---"
        kc logs -n scrap-examples deploy/p5-redis --all-containers --previous 2>&1 | sed 's/^/      /' || true
        kc logs -n scrap-examples deploy/p5-redis --all-containers 2>&1 | sed 's/^/      /' || true
        echo "      --- redis data dir on the restored pod, for comparison ---"
        kc exec -n scrap-examples deploy/p5-redis -- sh -c 'ls -la /data; redis-cli DBSIZE' 2>&1 | sed 's/^/      /' || true
    fi
else
    fail T-A/destructive-restore "restic restore job did not succeed -- see: kubectl logs -n scrap-backup job/$RESTORE_JOB"
fi

# 2g. A test alert actually reaches the observability surface -- not just
# that the rule loads. A deliberately-failing Job in scrap-backup makes
# kube_job_status_failed go positive, which BackupJobFailed
# (platform/observability-config/baseline-alerts.yaml) already watches
# for. Its `for: 5m` is the real, shipped rule -- this waits out the real
# window rather than shortcutting it with a test-only rule.
FAIL_JOB="t-a-alert-trigger-$(date +%s)"
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

# A single port-forward from this host, polled repeatedly -- not a fresh
# in-cluster pod per poll (verified during development that spinning up a
# pod per iteration made the pod-lifecycle overhead dominate the loop).
# Filter syntax (a quoted label matcher, not a bare "name=value") verified
# directly against a live Alertmanager: an unquoted filter is accepted
# without error but silently matches nothing, which would have made this
# check impossible to fail -- worth being exact about.
kc port-forward -n monitoring svc/alertmanager-operated 9093:9093 >/tmp/t-a-portforward.log 2>&1 &
PF_PID=$!
sleep 3

alert_result=""
echo "      waiting up to 7 minutes for BackupJobFailed to transition to firing (its rule requires 'for: 5m')..."
for i in $(seq 1 84); do
    firing=$(curl -sG --max-time 5 "http://127.0.0.1:9093/api/v2/alerts" \
        --data-urlencode 'filter=alertname="BackupJobFailed"' 2>/dev/null || true)
    if echo "$firing" | grep -q '"state":"active"'; then
        alert_result=ok
        break
    fi
    sleep 5
done
kill "$PF_PID" 2>/dev/null || true

if [ "$alert_result" = ok ]; then
    ok T-A/alert-reaches-surface "BackupJobFailed fired and reached Alertmanager for the deliberately-failed job"
else
    fail T-A/alert-reaches-surface "BackupJobFailed never reached firing state in Alertmanager within 7 minutes"
fi
kc delete job -n scrap-backup "$FAIL_JOB" --ignore-not-found >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "T-A: Phase 4/4: result"
if [ "$status" -ne 0 ]; then
    echo "T-A FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A PASSED -- clean-host bootstrap, all postconditions verified."
