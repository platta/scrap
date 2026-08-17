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
# A human can run this identically on their own scratch VM to reproduce a
# CI failure locally:
#   sh tests/profiles/t-a-minimal.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"

# Read straight from the checked-in reference instance-config, the same
# one bootstrap/install.sh's default CLUSTER_PATH points at -- never a
# CI-specific override. Minimal, dependency-free extraction, matching the
# style bootstrap/preflight/check-ports.sh already uses for
# reserved-ports.yaml, since a genuinely fresh host may not have a YAML
# parser available this early.
cfg_value() {
    awk -v k="$1" '$0 ~ "^  "k":" {
        sub("^  "k": *", ""); gsub(/"/, ""); print; exit
    }' "$INSTANCE_CONFIG"
}
BASE_DOMAIN=$(cfg_value BASE_DOMAIN)
INSTANCE_NAME=$(cfg_value INSTANCE_NAME)

log() { echo; echo "=== T-A: $* ==="; }
ok()   { echo "ok    T-A/$1: $2"; }
fail() { echo "FAIL  T-A/$1: $2"; status=1; }

# ---------------------------------------------------------------------------
log "Phase 0/3: environment prerequisites"
# check-prerequisites.sh fails loud rather than auto-installing -- correct
# for a real operator, who should decide what lands on their own host, but
# this fresh/disposable environment needs those prerequisites actually
# present before install.sh's own preflight will let it continue. Installs
# exactly what bootstrap/preflight/check-prerequisites.sh's own FAIL
# messages already tell an operator to run.
if ! command -v age-keygen >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq age >/dev/null
fi
if ! command -v sops >/dev/null 2>&1; then
    SOPS_VERSION=v3.9.4
    curl -sfLo /tmp/sops.deb "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops_${SOPS_VERSION#v}_amd64.deb"
    sudo dpkg -i /tmp/sops.deb >/dev/null
    rm -f /tmp/sops.deb
fi
if ! command -v ss >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq iproute2 >/dev/null
fi

# ---------------------------------------------------------------------------
log "Phase 1/3: bootstrap/install.sh -- the real, unmodified installer"
# SCRAP_ESCROW_CONFIRMED=1 is install.sh's own documented mechanism for a
# non-interactive shell (docs/core/bootstrap-lifecycle.md step 3) -- not a
# CI-specific bypass invented here. Everything else is left at its
# documented default: REPO_URL unset (the D5 local-bare-repo minimum
# path), CLUSTER_PATH the checked-in clusters/example/.
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A: bootstrap/install.sh exited non-zero -- see the 'Step N/7' marker"
    echo "      above for which layer of the documented bootstrap sequence failed."
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
status=0

# ---------------------------------------------------------------------------
log "Phase 2/3: T-A postconditions"

# 2a. Every Flux Kustomization Ready -- install.sh's own postflight.sh
# already waited for this; re-check explicitly here so a CI failure names
# this specific postcondition rather than relying on postflight's exit
# code (which install.sh deliberately ignores with '|| true').
not_ready=$(sudo -E flux get kustomizations -A --no-header 2>/dev/null | awk -F'\t' '{gsub(/ /,"",$5); if ($5!="True") print $2}')
if [ -z "$not_ready" ]; then
    ok kustomizations-ready "every Flux Kustomization is Ready"
else
    fail kustomizations-ready "not Ready: $not_ready"
fi
sudo -E flux get kustomizations -A || true

# 2b. The gap tests/profiles/README.md itself already found: a live value
# check, not just that Helm accepted the values without error.
svc_type=$(sudo -E kubectl get svc -n traefik traefik -o jsonpath='{.spec.type}' 2>/dev/null || true)
if [ "$svc_type" = "LoadBalancer" ]; then
    ok traefik-service-type "traefik Service is genuinely type LoadBalancer"
else
    fail traefik-service-type "traefik Service type is '$svc_type', expected LoadBalancer"
fi

# 2c. The private CA issued the one wildcard certificate.
cert_ready=$(sudo -E kubectl get certificate -n traefik scrap-wildcard \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$cert_ready" = "True" ]; then
    ok wildcard-certificate "scrap-wildcard Certificate is Ready (private CA issued it)"
else
    fail wildcard-certificate "scrap-wildcard Certificate Ready condition is '$cert_ready'"
fi

# Export the CA root ourselves (not relying on postflight's $HOME, which
# under `sudo` is root's home, not necessarily this shell's) -- the exact
# secret bootstrap/postflight.sh itself reads.
CA_CERT=/tmp/t-a-scrap-ca.crt
sudo -E kubectl get secret -n cert-manager scrap-ca-key-pair -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d > "$CA_CERT" || true

NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

# 2d. P1 reachable over TLS, trusting only the platform's real CA -- never -k.
p1_body=$(curl -s --max-time 15 --cacert "$CA_CERT" \
    --resolve "p1.${BASE_DOMAIN}:443:${NODE_IP}" \
    "https://p1.${BASE_DOMAIN}/" 2>&1 || true)
if echo "$p1_body" | grep -q "Hostname:"; then
    ok p1-reachable "p1.${BASE_DOMAIN} reachable over HTTPS through the real private CA"
else
    fail p1-reachable "unexpected response from p1.${BASE_DOMAIN}: $(echo "$p1_body" | head -3)"
fi

# 2e. Backup to local path -- trigger a real run against the whole
# labelled-PVC set (P5's redis included) and confirm it succeeds.
BACKUP_JOB="t-a-backup-$(date +%s)"
sudo -E kubectl create job -n scrap-backup "$BACKUP_JOB" --from=cronjob/scrap-backup >/dev/null
backup_result=""
for i in $(seq 1 24); do
    succeeded=$(sudo -E kubectl get job -n scrap-backup "$BACKUP_JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    failed=$(sudo -E kubectl get job -n scrap-backup "$BACKUP_JOB" -o jsonpath='{.status.failed}' 2>/dev/null || true)
    [ "${succeeded:-0}" -ge 1 ] 2>/dev/null && { backup_result=ok; break; }
    [ "${failed:-0}" -ge 1 ] 2>/dev/null && { backup_result=fail; break; }
    sleep 5
done
if [ "$backup_result" = ok ]; then
    ok backup-runs "backup job completed successfully (credentials, repository, discovery all working)"
else
    fail backup-runs "backup job did not succeed -- see: kubectl logs -n scrap-backup job/$BACKUP_JOB"
    sudo -E kubectl logs -n scrap-backup "job/$BACKUP_JOB" || true
fi

# 2f. Destructive restore, verified by a specific named value -- exactly
# docs/runbooks/README.md's "Single-application destructive restore"
# procedure, against apps/examples/p5-stateful-backup/'s Redis, including
# the ordering fix that procedure itself documents finding live: the
# whole tier touching the data must be scaled to zero before restoring,
# not just deleted from.
CANARY="t-a-canary-$(date +%s)-$$"
sudo -E kubectl exec -n scrap-examples deploy/p5-redis -- redis-cli SET t-a-canary "$CANARY" >/dev/null

RESTORE_JOB="t-a-restore-$(date +%s)"
sudo -E kubectl create job -n scrap-backup "${RESTORE_JOB}-backup" --from=cronjob/scrap-backup >/dev/null
for i in $(seq 1 24); do
    s=$(sudo -E kubectl get job -n scrap-backup "${RESTORE_JOB}-backup" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    [ "${s:-0}" -ge 1 ] 2>/dev/null && break
    sleep 5
done

PVC_NAME=p5-redis-data
PV_NAME=$(sudo -E kubectl get pvc -n scrap-examples "$PVC_NAME" -o jsonpath='{.spec.volumeName}')
HOST_PATH=$(sudo -E kubectl get pv "$PV_NAME" -o jsonpath='{.spec.local.path}')

sudo -E kubectl scale -n scrap-examples deploy/p5-redis --replicas=0
sudo -E kubectl wait -n scrap-examples --for=delete pod -l app=p5-redis --timeout=60s >/dev/null 2>&1 || true

cat <<EOF | sudo -E kubectl apply -f - >/dev/null
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
          command: ["restic", "restore", "latest", "--host=$INSTANCE_NAME", "--path=$HOST_PATH", "--target=/"]
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
restore_result=""
for i in $(seq 1 20); do
    s=$(sudo -E kubectl get job -n scrap-backup "$RESTORE_JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    f=$(sudo -E kubectl get job -n scrap-backup "$RESTORE_JOB" -o jsonpath='{.status.failed}' 2>/dev/null || true)
    [ "${s:-0}" -ge 1 ] 2>/dev/null && { restore_result=ok; break; }
    [ "${f:-0}" -ge 1 ] 2>/dev/null && { restore_result=fail; break; }
    sleep 5
done

sudo -E kubectl scale -n scrap-examples deploy/p5-redis --replicas=1
sudo -E kubectl wait -n scrap-examples --for=condition=Ready pod -l app=p5-redis --timeout=60s >/dev/null 2>&1 || true

if [ "$restore_result" = ok ]; then
    restored=$(sudo -E kubectl exec -n scrap-examples deploy/p5-redis -- redis-cli GET t-a-canary 2>/dev/null || true)
    if [ "$restored" = "$CANARY" ]; then
        ok destructive-restore "the exact canary value round-tripped through destroy -> restic restore -> the original app"
    else
        fail destructive-restore "restore job succeeded but the canary value did not come back (got '$restored', wanted '$CANARY')"
    fi
else
    fail destructive-restore "restic restore job did not succeed -- see: kubectl logs -n scrap-backup job/$RESTORE_JOB"
    sudo -E kubectl logs -n scrap-backup "job/$RESTORE_JOB" || true
fi

# 2g. A test alert actually reaches the observability surface -- not just
# that the rule loads. A deliberately-failing Job in scrap-backup makes
# kube_job_status_failed go positive, which BackupJobFailed
# (platform/observability-config/baseline-alerts.yaml) already watches
# for. Its `for: 5m` is the real, shipped rule -- this waits out the real
# window rather than shortcutting it with a test-only rule.
FAIL_JOB="t-a-alert-trigger-$(date +%s)"
cat <<EOF | sudo -E kubectl apply -f - >/dev/null
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
sudo -E kubectl port-forward -n monitoring svc/alertmanager-operated 9093:9093 >/tmp/t-a-portforward.log 2>&1 &
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
    ok alert-reaches-surface "BackupJobFailed fired and reached Alertmanager for the deliberately-failed job"
else
    fail alert-reaches-surface "BackupJobFailed never reached firing state in Alertmanager within 7 minutes"
fi
sudo -E kubectl delete job -n scrap-backup "$FAIL_JOB" --ignore-not-found >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "Phase 3/3: result"
if [ "$status" -ne 0 ]; then
    echo "T-A FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A PASSED -- clean-host bootstrap, all postconditions verified."
