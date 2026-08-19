#!/bin/sh
# T-A-public-tls -- live acceptance for capabilities/public-tls/, the part
# of its evidence that needs a real cluster but NOT a real domain or
# working DNS credentials. See capabilities/public-tls/README.md's own
# "Acceptance evidence" section for the full evidence-class breakdown, and
# capabilities/public-tls/verify-live.sh for the one claim (a real
# certificate actually issues) that genuinely can't be proven here and is
# left to an operator running against their own domain.
#
# Same expectations as tests/profiles/t-a-minimal.sh: a normal user,
# passwordless sudo, a genuinely fresh host, never run this whole script
# under `sudo` itself. A SEPARATE from-zero bootstrap from T-A's own,
# same reasoning as T-B's -- this deliberately drives the wildcard
# Certificate into a real (if intentionally-provoked) failure state and
# live-edits instance config after bootstrap; it must never run against a
# cluster some other check still depends on.
#
# A human can run this identically on their own scratch VM:
#   sh tests/profiles/t-a-public-tls.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

status=0

# ---------------------------------------------------------------------------
log "T-A-public-tls: Phase 0/4: environment prerequisites"
install_prereqs

# ---------------------------------------------------------------------------
log "T-A-public-tls: Phase 1/4: bootstrap/install.sh -- the real, unmodified installer"
# Identical invocation to T-A/T-B/the DR rehearsal -- see any of their own
# comments at this exact call for the HOME=/root investigation.
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A-public-tls: bootstrap/install.sh exited non-zero -- see the"
    echo "      'Step N/7' marker above for which layer of the documented bootstrap"
    echo "      sequence failed."
    exit 1
fi

setup_kubeconfig

not_ready=$(kc get kustomizations -A --no-header 2>/dev/null | awk -F'\t' '{gsub(/ /,"",$5); if ($5!="True") print $2}')
if [ -z "$not_ready" ]; then
    ok T-A-public-tls/kustomizations-ready "every Flux Kustomization is Ready"
else
    fail T-A-public-tls/kustomizations-ready "not Ready: $not_ready"
fi

# ---------------------------------------------------------------------------
log "T-A-public-tls: Phase 2/4: baseline -- the private CA default is unaffected by \${TLS_ISSUER}'s existence"
baseline_issuer=$(kc get certificate -n traefik scrap-wildcard -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)
baseline_ready=$(kc get certificate -n traefik scrap-wildcard \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$baseline_issuer" = "scrap-ca" ] && [ "$baseline_ready" = "True" ]; then
    ok T-A-public-tls/baseline-private-ca "the wildcard Certificate issues via scrap-ca by default, and \${TLS_ISSUER}'s introduction didn't break it (issuerRef=$baseline_issuer, Ready=$baseline_ready)"
else
    fail T-A-public-tls/baseline-private-ca "expected issuerRef=scrap-ca, Ready=True; got issuerRef='$baseline_issuer', Ready='$baseline_ready'"
fi

# ---------------------------------------------------------------------------
log "T-A-public-tls: Phase 3/4: enable public-tls with DELIBERATELY WRONG DNS-01 credentials, live"
# No real domain or DNS server anywhere in this phase -- the point is to
# prove the WIRING and the FAILURE MODE, not to get a real certificate
# (capabilities/public-tls/verify-live.sh, run by an operator against
# their own domain, is what proves a real certificate actually issues).
#
# Live-edits the ALREADY-BOOTSTRAPPED cluster's own git source (the local
# bare repo install.sh created, /var/lib/scrap/repo.git) -- not this
# checkout's instance-config.yaml, which install.sh already committed
# from at Phase 1. A plain local-path git clone/push, no SSH needed: this
# script runs as the same unprivileged user Flux's own deploy key
# authenticates as, on the same machine, and a bare repo is a normal git
# remote over a filesystem path regardless of which URL scheme Flux
# itself was bootstrapped against.
BARE_REPO=/var/lib/scrap/repo.git
LIVEDIR=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR"
LIVE_CLUSTER_DIR="$LIVEDIR/clusters/example"

mkdir -p "$LIVE_CLUSTER_DIR/capabilities"
cp "$REPO_ROOT/capabilities/public-tls/cluster-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/public-tls.yaml"
cp "$REPO_ROOT/capabilities/public-tls/cluster-secrets-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/public-tls-secrets.yaml"

sed -i 's|^\(  TLS_ISSUER: \).*|\1"scrap-acme-staging"|' "$LIVE_CLUSTER_DIR/instance-config.yaml"
# Deliberately WRONG nameserver -- unroutable TEST-NET address (RFC 5737),
# guaranteed not to answer, so the DNS-01 challenge fails predictably and
# quickly rather than hanging on a real-but-wrong server's own timeout
# behavior.
sed -i 's|^\(  ACME_DNS01_NAMESERVER: \).*|\1"192.0.2.53:53"|' "$LIVE_CLUSTER_DIR/instance-config.yaml"

( cd "$LIVEDIR" && git add -A && git -c user.email=t-a-public-tls@localhost -c user.name="T-A-public-tls" \
    commit -q -m "T-A-public-tls: enable public-tls, swap TLS_ISSUER to scrap-acme-staging" && \
    git push -q origin main )
rm -rf "$LIVEDIR"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization capabilities --with-source >/dev/null
# public-tls-secrets and public-tls are newly-created nested Kustomizations
# as of the commit above -- give Flux's own discovery a moment before
# reconciling them by name.
sleep 5
flux reconcile kustomization public-tls-secrets --with-source >/dev/null 2>&1 || true
flux reconcile kustomization public-tls --with-source >/dev/null 2>&1 || true
flux reconcile kustomization platform-ingress --with-source >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "T-A-public-tls: Phase 4/4: T-A-public-tls postconditions"

# 4a. Capability ownership: the two ACME ClusterIssuers exist, applied by
# the public-tls Kustomization -- never referenced by any app (already
# proven statically, tests/assertions/check_tls_issuer_not_in_apps.py;
# this confirms the objects this capability owns are genuinely live).
staging_issuer_exists=$(kc get clusterissuer scrap-acme-staging -o jsonpath='{.metadata.name}' 2>/dev/null || true)
prod_issuer_exists=$(kc get clusterissuer scrap-acme -o jsonpath='{.metadata.name}' 2>/dev/null || true)
if [ "$staging_issuer_exists" = "scrap-acme-staging" ] && [ "$prod_issuer_exists" = "scrap-acme" ]; then
    ok T-A-public-tls/capability-owned "both ACME ClusterIssuers exist, applied by capabilities/public-tls/ alone"
else
    fail T-A-public-tls/capability-owned "expected both scrap-acme-staging and scrap-acme ClusterIssuers to exist (got staging='$staging_issuer_exists', prod='$prod_issuer_exists')"
fi

# 4b. The wildcard Certificate genuinely resolves to the new issuer -- not
# silently still on scrap-ca.
swapped_issuer=$(kc get certificate -n traefik scrap-wildcard -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)
if [ "$swapped_issuer" = "scrap-acme-staging" ]; then
    ok T-A-public-tls/issuer-swapped "the wildcard Certificate's issuerRef genuinely resolved to scrap-acme-staging after the instance-config change"
else
    fail T-A-public-tls/issuer-swapped "expected issuerRef=scrap-acme-staging, got '$swapped_issuer'"
fi

# 4c. Fails VISIBLY: Ready=False with a real reason, not silently True.
# Poll rather than a single read -- cert-manager needs a moment to
# process the new issuerRef and attempt the challenge.
fail_seen=""
i=0
while [ "$i" -lt 24 ]; do
    r=$(kc get certificate -n traefik scrap-wildcard \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "$r" = "False" ]; then
        fail_seen=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
ready_reason=$(kc get certificate -n traefik scrap-wildcard \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
ready_message=$(kc get certificate -n traefik scrap-wildcard \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
echo "      --- wildcard Certificate status after the swap ---"
kc describe certificate -n traefik scrap-wildcard 2>&1 | sed 's/^/      /' || true
echo "      --- Order/Challenge objects (proof a real DNS-01 attempt happened) ---"
kc get order,challenge -n traefik 2>&1 | sed 's/^/      /' || true

if [ "$fail_seen" = 1 ] && [ -n "$ready_reason" ]; then
    ok T-A-public-tls/fails-visibly "Certificate Ready=False with a real reason ('$ready_reason: $ready_message') -- no silent success, no SCRAP-invented fallback"
else
    fail T-A-public-tls/fails-visibly "expected Ready=False with a named reason within 2 minutes; got fail_seen='$fail_seen' reason='$ready_reason'"
fi

# 4d. Availability preserved: cert-manager's own native behavior keeps
# serving the OLD (still-valid, scrap-ca-issued) certificate until a new
# one succeeds -- confirmed by reading the Secret's own cert, not
# inferred. This is the concrete evidence "no silent fallback" doesn't
# also mean "the site breaks" -- upstream cert-manager behavior, nothing
# SCRAP added.
still_scrap_ca=$(kc get secret -n traefik scrap-wildcard-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
if echo "$still_scrap_ca" | grep -q "SCRAP Root CA"; then
    ok T-A-public-tls/availability-preserved "the served certificate Secret still holds the original scrap-ca-issued cert throughout the failed ACME attempt -- cert-manager's own upstream behavior, not a SCRAP fallback"
else
    fail T-A-public-tls/availability-preserved "expected the still-served certificate to be issued by 'SCRAP Root CA', got issuer line: '$still_scrap_ca'"
fi

# 4e. Revert, and confirm recovery -- same live-edit mechanism, reversed.
LIVEDIR2=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR2"
sed -i 's|^\(  TLS_ISSUER: \).*|\1"scrap-ca"|' "$LIVEDIR2/clusters/example/instance-config.yaml"
( cd "$LIVEDIR2" && git add -A && git -c user.email=t-a-public-tls@localhost -c user.name="T-A-public-tls" \
    commit -q -m "T-A-public-tls: revert TLS_ISSUER to scrap-ca" && git push -q origin main )
rm -rf "$LIVEDIR2"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization platform-ingress --with-source >/dev/null 2>&1 || true

reverted=""
i=0
while [ "$i" -lt 24 ]; do
    ri=$(kc get certificate -n traefik scrap-wildcard -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)
    rr=$(kc get certificate -n traefik scrap-wildcard \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "$ri" = "scrap-ca" ] && [ "$rr" = "True" ]; then
        reverted=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$reverted" = 1 ]; then
    ok T-A-public-tls/reverts-cleanly "reverting TLS_ISSUER back to scrap-ca brought the wildcard Certificate back to Ready=True"
else
    fail T-A-public-tls/reverts-cleanly "the wildcard Certificate never recovered to issuerRef=scrap-ca, Ready=True after reverting"
fi

# ---------------------------------------------------------------------------
log "T-A-public-tls: result"
if [ "$status" -ne 0 ]; then
    echo "T-A-public-tls FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A-public-tls PASSED -- capability-owned ACME issuers, a genuine issuer swap, visible (never silent) failure on bad credentials, preserved availability, and a clean revert, all verified live."
