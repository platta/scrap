#!/bin/sh
# Verifies the platform actually came up, and reports state honestly
# rather than assuming success because install.sh didn't error. Per
# docs/core/bootstrap-lifecycle.md: every Kustomization Ready, the private
# CA root exported with trust instructions, and the alerting-receiver
# state stated explicitly -- including, honestly, when there isn't one.
set -eu
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "--- postflight ---"
echo

echo "Waiting for all Kustomizations to become Ready (up to 5 minutes)..."
deadline=$(($(date +%s) + 300))
while [ "$(date +%s)" -lt "$deadline" ]; do
    not_ready=$(flux get kustomizations --no-header 2>/dev/null | awk -F'\t' '{gsub(/ /,"",$3); if ($3!="True") print}' | wc -l)
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
