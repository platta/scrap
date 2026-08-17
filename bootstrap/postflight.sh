#!/bin/sh
# Verifies the platform actually came up, and reports state honestly
# rather than assuming success because install.sh didn't error. Per
# docs/core/bootstrap-lifecycle.md: every Kustomization Ready, the private
# CA root exported with trust instructions, a backup engine run proven (not
# just assumed from the CronJob object existing), and the alerting-receiver
# state stated explicitly -- including, honestly, when there isn't one.
set -eu
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "--- postflight ---"
echo

echo "Waiting for all Kustomizations to become Ready (up to 5 minutes)..."
deadline=$(($(date +%s) + 300))
while [ "$(date +%s)" -lt "$deadline" ]; do
    # $4 is READY -- verified directly against real `flux get kustomizations`
    # output (NAME, REVISION, SUSPENDED, READY, MESSAGE), not assumed. The
    # first version of this checked $3 (SUSPENDED, not READY), which is
    # "False" in normal operation and therefore never equals "True" --
    # this loop would have spun for the full 5-minute deadline on every
    # single run, every time, regardless of actual readiness, and the "ok"
    # branch below could never be reached. Found building tests/profiles/
    # t-a-minimal.sh, which needed to trust this exact column mapping and
    # verified it live before relying on it.
    not_ready=$(flux get kustomizations --no-header 2>/dev/null | awk -F'\t' '{gsub(/ /,"",$4); if ($4!="True") print}' | wc -l)
    total=$(flux get kustomizations --no-header 2>/dev/null | wc -l)
    if [ "$total" -gt 0 ] && [ "$not_ready" -eq 0 ]; then
        echo "ok    all $total Kustomization(s) Ready"
        break
    fi
    sleep 5
done
echo
flux get kustomizations
echo

echo "--- TLS trust ---"
if kubectl get secret scrap-ca-key-pair -n cert-manager >/dev/null 2>&1; then
    OUT="$HOME/scrap-ca.crt"
    kubectl get secret scrap-ca-key-pair -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > "$OUT"
    echo "ok    private CA root exported to: $OUT"
    echo "      Install this on any client device that needs to trust *.<your-base-domain>"
    echo "      without a browser warning -- see platform/cert-manager-config/README.md."
    echo "      Workloads that call SCRAP endpoints (not client devices) use"
    echo "      components/ca-trust/ instead -- see that directory's README."
else
    echo "WARN  scrap-ca-key-pair Secret not found yet -- platform-cert-manager-config may"
    echo "      still be reconciling. Re-run this script, or check: flux get kustomizations"
fi
echo

echo "--- backup ---"
if kubectl get cronjob -n scrap-backup scrap-backup >/dev/null 2>&1; then
    JOB_NAME="scrap-backup-postflight-$(date +%s)"
    kubectl create job -n scrap-backup "$JOB_NAME" --from=cronjob/scrap-backup >/dev/null
    echo "Triggered an immediate run of the backup job ($JOB_NAME) to verify the engine is"
    echo "actually operational -- not just that its CronJob object exists."
    deadline=$(($(date +%s) + 120))
    result=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        succeeded=$(kubectl get job -n scrap-backup "$JOB_NAME" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
        failed=$(kubectl get job -n scrap-backup "$JOB_NAME" -o jsonpath='{.status.failed}' 2>/dev/null || true)
        if [ "${succeeded:-0}" -ge 1 ] 2>/dev/null; then
            result="ok"
            break
        fi
        if [ "${failed:-0}" -ge 1 ] 2>/dev/null; then
            result="fail"
            break
        fi
        sleep 5
    done
    case "$result" in
        ok)
            echo "ok    backup job completed successfully -- credentials, repository, and"
            echo "      discovery are all working."
            ;;
        fail)
            echo "FAIL  backup job failed -- see: kubectl logs -n scrap-backup job/$JOB_NAME"
            ;;
        *)
            echo "WARN  backup job did not finish within 2 minutes -- check:"
            echo "      kubectl get job -n scrap-backup $JOB_NAME"
            ;;
    esac
    echo
    echo "HONEST LIMIT: a fresh install has no application data yet, so this only proves the"
    echo "engine runs -- it does not exercise a restore. Restore is proven end to end, against"
    echo "real data, the first time you add a backed-up application; see"
    echo "docs/runbooks/README.md."
else
    echo "WARN  scrap-backup CronJob not found yet -- platform-backup may still be reconciling."
fi
echo

echo "--- alerting ---"
if kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager >/dev/null 2>&1; then
    receiver=$(kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager \
        -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d | awk '/^route:/{f=1} f && /receiver:/{print $2; exit}')
    if [ "$receiver" = "'null'" ] || [ -z "$receiver" ]; then
        echo "STATED PLAINLY, NOT HIDDEN: no Alertmanager receiver is configured."
        echo "Backups failing, certificates expiring, pods crash-looping -- none of it will reach"
        echo "you until a real receiver (SMTP, ntfy, webhook) is configured. See"
        echo "docs/supported/README.md and platform/observability/README.md."
    else
        echo "ok    Alertmanager route configured (receiver: $receiver)"
    fi
else
    echo "WARN  Alertmanager Secret not found yet -- platform-observability may still be reconciling."
fi
