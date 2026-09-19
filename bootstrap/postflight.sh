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
base_receiver=""
if kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager >/dev/null 2>&1; then
    receiver=$(kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager \
        -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d | awk '/^route:/{f=1} f && /receiver:/{print $2; exit}')
    if [ "$receiver" != "'null'" ] && [ -n "$receiver" ]; then
        base_receiver="platform/observability/'s own base route (receiver: $receiver)"
    fi
fi
# REAL BUG, found implementing capabilities/alert-delivery/ (PLAT-35):
# that capability -- and any operator-authored equivalent -- wires
# delivery via a namespace-scoped AlertmanagerConfig object, never by
# editing platform/observability/'s own base config (see that capability's
# README and platform/observability/helmrelease.yaml's own comment). The
# TOP-LEVEL route's own `receiver:` therefore stays 'null' even once
# delivery genuinely works -- checking only the block above would keep
# reporting "no receiver configured" forever after this capability is
# enabled, exactly the kind of stale, misleading status this postflight
# step exists to prevent. No jq dependency introduced here -- bootstrap
# never assumes it (see tests/profiles/lib.sh's own comment on why jq is
# a test-runner-only tool) -- so this uses kubectl's own jsonpath, then
# plain shell/grep to drop any object with an empty receiver.
am_receivers=$(kubectl get alertmanagerconfigs -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" -> "}{.spec.route.receiver}{"\n"}{end}' 2>/dev/null | \
    grep -v -- '-> *$' || true)
if [ -n "$base_receiver" ] || [ -n "$am_receivers" ]; then
    if [ -n "$base_receiver" ]; then
        echo "ok    $base_receiver"
    fi
    if [ -n "$am_receivers" ]; then
        echo "ok    AlertmanagerConfig-routed delivery configured:"
        echo "$am_receivers" | sed 's/^/      /'
    fi
else
    echo "STATED PLAINLY, NOT HIDDEN: no Alertmanager receiver is configured."
    echo "Backups failing, certificates expiring, pods crash-looping -- none of it will reach"
    echo "you until a real receiver (SMTP, ntfy, webhook) is configured. See"
    echo "capabilities/alert-delivery/README.md and docs/supported/README.md."
fi
echo

# --- satellite observability (docs/decisions/0018-observability-topology.md) ---
# Detected from LIVE cluster state (the Prometheus CR's own spec.remoteWrite),
# never from a config file this script would otherwise have to guess is
# still accurate -- same "prove it, don't infer it from config existing"
# discipline as the backup check above.
remote_write_targets=$(kubectl get prometheus -n monitoring kube-prometheus-stack-prometheus \
    -o jsonpath='{.spec.remoteWrite[*].url}' 2>/dev/null || true)
if [ -n "$remote_write_targets" ]; then
    echo "--- satellite observability ---"
    echo "Satellite topology selected -- remote-write destination(s): $remote_write_targets"

    # Curled from the HOST, not via kubectl exec into the Prometheus
    # container (whose minimal image may not carry curl/wget) -- a k3s
    # single-node host can reach its own cluster's Service ClusterIPs
    # directly, the same routable-from-the-host property every other
    # in-cluster-only check in this repository already relies on.
    # prometheus-operated, not kube-prometheus-stack-prometheus -- the
    # latter is the Prometheus Operator CUSTOM RESOURCE's own name (used
    # above and by capabilities/heartbeat/'s Alertmanager equivalent), a
    # separate thing from the headless SERVICE the operator generates,
    # which capabilities/grafana/helmrelease.yaml's own datasource URL and
    # tests/profiles/t-a-ups.sh's own port-forward already name correctly.
    prom_svc_ip=$(kubectl get svc -n monitoring prometheus-operated \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -n "$prom_svc_ip" ]; then
        prom_metrics=$(curl -sf --max-time 5 "http://${prom_svc_ip}:9090/metrics" 2>/dev/null || true)
        highest_sent=$(echo "$prom_metrics" | awk '/^prometheus_remote_storage_queue_highest_sent_timestamp_seconds/ {print $NF; exit}')
        failed_total=$(echo "$prom_metrics" | awk '/^prometheus_remote_storage_samples_failed_total/ {sum+=$NF} END {print sum+0}')
        now=$(date +%s)
        if [ -n "$highest_sent" ] && \
            [ "$(awk -v h="$highest_sent" -v n="$now" 'BEGIN{print (h>0 && n-h<600)?1:0}')" = "1" ]; then
            ok_age=$(awk -v h="$highest_sent" -v n="$now" 'BEGIN{printf "%.0f", n-h}')
            echo "ok    remote-write is genuinely delivering: highest successfully-sent sample was $ok_age s ago (failed samples so far: ${failed_total:-0})"
        else
            echo "WARN  remote-write does not yet show a recent successful send (failed samples so far: ${failed_total:-0}) --"
            echo "      this is expected immediately after bootstrap; re-run this script in a few minutes."
        fi
    else
        echo "WARN  Prometheus Service not found yet -- cannot confirm remote-write is genuinely delivering"
    fi

    if kubectl get prometheusrule -n monitoring satellite-remote-write-health >/dev/null 2>&1; then
        echo "ok    the telemetry-path-health rule (F3: SatelliteRemoteWriteFailing/Stale) is loaded"
    else
        echo "FAIL  satellite-remote-write-health PrometheusRule not found -- the F3 telemetry-path"
        echo "      failure/lag alert (docs/decisions/0018) will never fire on this instance"
    fi

    if kubectl get cronjob -n monitoring scrap-heartbeat >/dev/null 2>&1; then
        echo "ok    F2 posture: capabilities/heartbeat/ is enabled -- this node's own death is covered"
    else
        echo "STATED PLAINLY, NOT HIDDEN: F2 posture -- no heartbeat capability and no hub configured."
        echo "      If this node/k3s dies entirely, NOTHING will notice -- every local alert, delivered"
        echo "      or not, dies with it. See capabilities/heartbeat/README.md (strongly recommended in"
        echo "      satellite mode) and docs/decisions/0018-observability-topology.md's F2 row."
    fi
fi
