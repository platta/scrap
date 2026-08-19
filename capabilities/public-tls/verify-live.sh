#!/bin/sh
# capabilities/public-tls/verify-live.sh -- operator-run, NOT CI-executed.
#
# The one claim this capability makes that genuinely cannot be proven
# without infrastructure this project doesn't control and never will: that
# a REAL ACME DNS-01 certificate issues from a REAL DNS provider against a
# REAL domain. tests/profiles/t-a-public-tls.sh proves everything else
# (capability ownership, the issuer swap, fail-visibly behavior) live, in
# CI, with deliberately-wrong credentials and no external dependency --
# see that script and this capability's own README for exactly which
# claim belongs to which evidence class. Faking this one in CI (a
# self-signed cert dressed up to look like it came from Let's Encrypt,
# or skipping the DNS-01 challenge) would be worse than not testing it at
# all: a green check that doesn't mean what it claims.
#
# Run this yourself, against your own already-bootstrapped cluster, after
# enabling capabilities/public-tls/ with your own real domain, DNS
# provider, and RFC2136 (or swapped-in provider-specific) credentials --
# see this directory's README's "Enabling this capability" section first.
# Point TLS_ISSUER at scrap-acme-staging before running this the first
# time: Let's Encrypt's staging environment has no meaningful rate limit,
# so a broken DNS-01 setup costs you nothing to iterate on. Only move to
# scrap-acme (production, trusted, rate-limited) after this script passes
# against staging.
#
#   sh capabilities/public-tls/verify-live.sh
#
# Requires: kubectl access to the cluster (KUBECONFIG set the normal way),
# and that you've already set TLS_ISSUER and reconciled Flux (`flux
# reconcile kustomization public-tls --with-source` if you don't want to
# wait for the next interval).
set -eu

NS=traefik
CERT=scrap-wildcard

echo "=== capabilities/public-tls/verify-live.sh ==="
echo "Watching Certificate/$CERT in namespace $NS for up to 5 minutes."
echo "(DNS-01 propagation genuinely takes minutes -- this is not a defect,"
echo " see docs/decisions/0006's own caveat.)"
echo

issuer=$(kubectl get certificate -n "$NS" "$CERT" -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)
if [ -z "$issuer" ]; then
    echo "FAIL: could not read Certificate/$CERT in namespace $NS -- is the"
    echo "      cluster reachable, and has platform/ingress/ reconciled at all?"
    exit 1
fi
echo "issuerRef.name: $issuer"
case "$issuer" in
    scrap-acme|scrap-acme-staging) : ;;
    scrap-ca)
        echo "FAIL: TLS_ISSUER is still 'scrap-ca' (the private CA default)."
        echo "      Set TLS_ISSUER to scrap-acme-staging in your instance-config.yaml,"
        echo "      commit, and let Flux reconcile before running this script."
        exit 1
        ;;
    *)
        echo "WARN: issuerRef is '$issuer', not one of this capability's own issuer"
        echo "      names -- continuing, but this may not be what you intended."
        ;;
esac

ready=""
i=0
while [ "$i" -lt 30 ]; do
    status=$(kubectl get certificate -n "$NS" "$CERT" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    reason=$(kubectl get certificate -n "$NS" "$CERT" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
    if [ "$status" = "True" ]; then
        ready=1
        break
    fi
    echo "  ($i/30) Ready=$status reason=$reason -- waiting 10s"
    sleep 10
    i=$((i + 1))
done

if [ -z "$ready" ]; then
    echo
    echo "FAIL: Certificate/$CERT never reached Ready=True within 5 minutes."
    echo "      Real cert-manager diagnostics, not a guess at the cause:"
    kubectl describe certificate -n "$NS" "$CERT" || true
    echo "--- most recent Order/Challenge objects ---"
    kubectl get order,challenge -n "$NS" 2>&1 || true
    exit 1
fi

echo
echo "ok: Certificate/$CERT is Ready under issuer '$issuer'."
echo

# The decisive check: read the actual served certificate's real issuer
# field, not cert-manager's own status (which only proves cert-manager
# THINKS it succeeded) -- this is what a real client would see.
domain=$(kubectl get certificate -n "$NS" "$CERT" -o jsonpath='{.spec.dnsNames[1]}' 2>/dev/null || true)
if [ -z "$domain" ]; then
    echo "WARN: could not read a concrete dnsName from the Certificate spec to"
    echo "      verify against directly -- Ready=True above is still real"
    echo "      evidence, just not independently cross-checked here."
    exit 0
fi

echo "Reading the actual served certificate for https://$domain/ ..."
cert_issuer=$(echo | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null || true)
echo "Served certificate issuer: ${cert_issuer:-<could not connect -- check DNS/firewall/routing>}"

case "$cert_issuer" in
    *"Let's Encrypt"*|*"(STAGING)"*)
        echo
        echo "PASS: a real certificate, actually issued by Let's Encrypt, is being served."
        ;;
    *)
        echo
        echo "WARN: cert-manager reports Ready=True, but the served certificate's"
        echo "      issuer field doesn't obviously say Let's Encrypt -- verify by hand"
        echo "      before trusting this. (Common cause: DNS for $domain doesn't yet"
        echo "      point at this cluster, so the connection above reached something else.)"
        ;;
esac
