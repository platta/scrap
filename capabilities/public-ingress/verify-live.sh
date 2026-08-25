#!/bin/sh
# capabilities/public-ingress/verify-live.sh -- operator-run, NOT fully
# CI-executed. See docs/decisions/0014-public-ingress-edge-authority.md
# for why this capability's implemented form is a runbook plus this
# script, never a Kubernetes manifest: the control point (your router's
# NAT table) exists entirely outside anything Flux reconciles, so there
# is nothing in-cluster for CI to enable or disable.
#
# Three checks, run in order, each proven where proof is actually
# possible and honest where it is not:
#
#   1/3 -- is the platform Gateway genuinely listening on NODE_ADDRESS's
#          own forwarded ports? Fully deterministic: this is a direct LAN
#          connection, no NAT or public DNS involved at all.
#   2/3 -- does PUBLIC DNS (not your LAN's own resolver, which
#          split-horizon DNS deliberately makes answer differently)
#          answer BASE_DOMAIN with this host's actual current public IP?
#          Deterministic once you've configured public DNS; reported as
#          informational, not a hard failure, if you haven't gotten that
#          far yet.
#   3/3 -- when the public address is actually reachable, is the served
#          certificate genuinely THIS platform's own wildcard certificate
#          -- not merely "some" certificate? Compared by SHA-256
#          fingerprint against the real Secret cert-manager wrote
#          in-cluster, the strongest form of "this is really our
#          Gateway" this script can offer. Honest where determinism
#          isn't possible: from inside your own LAN, reaching your own
#          public IP depends on your router's own NAT hairpin support --
#          the exact dependency split-horizon DNS exists to avoid for
#          in-cluster/LAN traffic, but unavoidable for THIS script
#          running on your LAN checking the PUBLIC path end to end. An
#          unreachable public address from here is not proof of
#          failure; conclusive confirmation needs an off-network vantage
#          (a phone on cellular data, a friend's connection, or an
#          online "check my port" tool pointed at your own domain).
#
#   sh capabilities/public-ingress/verify-live.sh
#
# Requires: kubectl access to the cluster (KUBECONFIG set the normal
# way), dig, and openssl. Run this after completing this capability's
# own README -- the reserved-ports review, the router forwards, and the
# split-horizon DNS arrangement -- not before.
#
# PUBLIC_INGRESS_TARGET (optional env override): skip resolving
# BASE_DOMAIN via public DNS for check 3 and connect to this host[:port]
# instead. Exists for testing this script itself against a known
# endpoint directly -- tests/profiles/t-a-public-ingress.sh uses it to
# prove this script's own cert-identity oracle is sound (green against
# the platform's real Gateway, red against a deliberately wrong one)
# without needing a real public domain, the same evidence-boundary shape
# capabilities/public-tls/verify-live.sh already establishes for a
# different claim.
set -eu

NAMESPACE=traefik
CERT_SECRET=scrap-wildcard-tls

echo "=== capabilities/public-ingress/verify-live.sh ==="
echo

BASE_DOMAIN=$(kubectl get configmap -n flux-system instance-config -o jsonpath='{.data.BASE_DOMAIN}' 2>/dev/null || true)
NODE_ADDRESS=$(kubectl get configmap -n flux-system instance-config -o jsonpath='{.data.NODE_ADDRESS}' 2>/dev/null || true)
if [ -z "$BASE_DOMAIN" ] || [ -z "$NODE_ADDRESS" ]; then
    echo "FAIL: could not read BASE_DOMAIN/NODE_ADDRESS from the live instance-config"
    echo "      ConfigMap (flux-system/instance-config) -- is the cluster reachable?"
    exit 1
fi
echo "BASE_DOMAIN=$BASE_DOMAIN  NODE_ADDRESS=$NODE_ADDRESS"
echo

status=0

# ---------------------------------------------------------------------------
echo "--- 1/3: is the Gateway genuinely listening on NODE_ADDRESS's own forwarded ports? ---"
if echo | openssl s_client -connect "$NODE_ADDRESS:443" -servername "$BASE_DOMAIN" >/dev/null 2>&1; then
    echo "ok: a TLS handshake against $NODE_ADDRESS:443 (the address your router"
    echo "    should be forwarding 443 to) genuinely succeeds."
else
    echo "FAIL: could not complete a TLS handshake against $NODE_ADDRESS:443."
    echo "      This is a LAN-local check -- no router, NAT, or public DNS is"
    echo "      involved. platform/ingress/'s own Gateway should already answer"
    echo "      here regardless of whether public-ingress is enabled at all; if"
    echo "      this fails, the platform itself isn't up, not just public"
    echo "      reachability."
    status=1
fi
echo

# ---------------------------------------------------------------------------
echo "--- 2/3: does PUBLIC DNS answer $BASE_DOMAIN with this host's current public IP? ---"
# A public, non-split-horizon resolver -- never this LAN's own DNS
# server, which by design answers $BASE_DOMAIN differently (see
# capabilities/public-ingress/README.md's own split-horizon DNS step).
PUBLIC_RESOLVER="1.1.1.1"
public_dns_answer=$(dig @"$PUBLIC_RESOLVER" +short +time=5 +tries=2 "$BASE_DOMAIN" A 2>/dev/null | tail -n1)
current_public_ip=$(curl -sf --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)
if [ -z "$current_public_ip" ]; then
    echo "WARN: could not determine this host's own current public IP (no internet"
    echo "      access, or api.ipify.org unreachable) -- skipping the comparison."
elif [ -z "$public_dns_answer" ]; then
    echo "INFO: public DNS has no A record for $BASE_DOMAIN yet -- not a failure if"
    echo "      you haven't set up the split-horizon DNS step yet; do that before"
    echo "      relying on this capability."
elif [ "$public_dns_answer" = "$current_public_ip" ]; then
    echo "ok: public DNS answers $BASE_DOMAIN with $public_dns_answer, matching this"
    echo "    host's own current public IP exactly."
else
    echo "FAIL: public DNS answers $BASE_DOMAIN with '$public_dns_answer', but this"
    echo "      host's current public IP is '$current_public_ip' -- these must"
    echo "      match. If your public IP changes, capabilities/dyndns/ keeps this"
    echo "      current automatically; otherwise update the record by hand."
    status=1
fi
echo

# ---------------------------------------------------------------------------
echo "--- 3/3: when reachable at the public address, is the served certificate genuinely this platform's own? ---"
local_fingerprint=$(kubectl get secret -n "$NAMESPACE" "$CERT_SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
if [ -z "$local_fingerprint" ]; then
    echo "FAIL: could not read the platform's own wildcard certificate from"
    echo "      Secret/$CERT_SECRET in namespace $NAMESPACE -- is platform/ingress/"
    echo "      reconciled and Ready?"
    status=1
else
    TARGET="${PUBLIC_INGRESS_TARGET:-$BASE_DOMAIN:443}"
    TARGET_HOST="${TARGET%%:*}"
    TARGET_PORT="${TARGET##*:}"
    echo "connecting to $TARGET (SNI: $BASE_DOMAIN) ..."
    served_fingerprint=$(echo | openssl s_client -connect "$TARGET_HOST:$TARGET_PORT" -servername "$BASE_DOMAIN" 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true)
    if [ -z "$served_fingerprint" ]; then
        echo "WARN: could not connect to $TARGET at all. From inside your own LAN,"
        echo "      this is EXPECTED unless your router supports NAT hairpin -- it"
        echo "      is not proof public reachability is broken. Confirm from an"
        echo "      off-network vantage (cellular data, a friend's connection, or"
        echo "      an online port-checking tool) for conclusive evidence."
    elif [ "$served_fingerprint" = "$local_fingerprint" ]; then
        echo "PASS: the certificate served at $TARGET is byte-for-byte this"
        echo "      platform's own wildcard certificate (SHA-256 fingerprint"
        echo "      $served_fingerprint) -- this is genuinely your Gateway, not"
        echo "      merely something that answered."
    else
        echo "FAIL: a certificate WAS served at $TARGET, but its fingerprint"
        echo "      ($served_fingerprint) does not match the platform's own"
        echo "      wildcard certificate ($local_fingerprint). Something other"
        echo "      than this cluster's Gateway is answering there."
        status=1
    fi
fi
echo

if [ "$status" -ne 0 ]; then
    echo "verify-live.sh: one or more checks FAILED -- see above."
    exit 1
fi
echo "verify-live.sh: all determinable checks passed. If check 3 could not connect"
echo "at all, confirm from an off-network vantage before relying on this capability --"
echo "see this script's own header for why that step can't be skipped."
