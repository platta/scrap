#!/bin/sh
# T-B -- Standard acceptance profile. See tests/profiles/README.md for
# what this is required to prove. Same expectations as
# tests/profiles/t-a-minimal.sh (normal user, passwordless sudo, a
# genuinely fresh host, never run this whole script under `sudo` itself)
# -- read that script's own header first, since this one shares its
# shape and only documents what's different here.
#
# A SEPARATE from-zero bootstrap, not a mutation of an already-running
# T-A cluster: enabling a capability mid-run on a cluster already used to
# prove the *minimal* profile would leave it unclear which claim that
# cluster actually demonstrates by the time both scripts finished with
# it. Genuinely more expensive (a second full bootstrap), but the
# minimal-profile claim T-A makes has to stay uncontaminated -- see the
# milestone that asked for this split.
#
# Proves capabilities/identity/ enabled, and P2 (native OIDC) + P3
# (forward-auth) end to end, including the adversarial claim P3's own
# README makes: an unauthenticated request must never reach the
# protected application. This is NOT yet the full "Standard" profile
# tests/profiles/README.md originally sketched (Grafana, logs, a
# recovery-flow-abuse test) -- see that file's own status note for
# exactly what's covered here and what's still open.
#
# A human can run this identically on their own scratch VM:
#   sh tests/profiles/t-b-standard.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

BASE_DOMAIN=$(cfg_value BASE_DOMAIN)
status=0

# ---------------------------------------------------------------------------
log "T-B: Phase 0/4: environment prerequisites"
install_prereqs

# The checked-in reference instance's identity bootstrap credentials --
# decrypted here, from the pristine ciphertext, using the reference
# keypair clusters/example/secrets/README.md says is published on purpose
# for exactly this ("Treat this file exactly like cert-manager's or
# Kubernetes' own well-known 'example' TLS keys: real cryptographic
# material, zero secrecy value, committed on purpose"). Reading it this
# way, rather than hardcoding the plaintext password as a magic string,
# means this script can't silently drift out of sync with the actual
# reference secret if it's ever regenerated. install.sh's own bootstrap
# later re-encrypts this file to a FRESH operational+escrow keypair (see
# bootstrap/install.sh Step 5/7) -- that only changes which keys can
# decrypt it, never the underlying value, so decrypting the pristine copy
# here, before install.sh runs, gets the exact value that ends up live in
# the cluster either way.
AKADMIN_PASSWORD=$(cd "$REPO_ROOT/clusters/example/secrets/identity" && \
    SOPS_AGE_KEY_FILE=../PUBLISHED-NOT-SECRET-reference.agekey \
    sops -d --extract '["stringData"]["AUTHENTIK_BOOTSTRAP_PASSWORD"]' identity-credentials.sops.yaml)
if [ -z "$AKADMIN_PASSWORD" ]; then
    echo "FAIL  T-B: could not decrypt the reference akadmin bootstrap password -- see"
    echo "      clusters/example/secrets/README.md. Nothing bootstrapped yet; exiting."
    exit 1
fi

# ---------------------------------------------------------------------------
log "T-B: Phase 1/4: enable the identity capability -- exactly the documented path"
# capabilities/identity/README.md's own "Enabling this capability"
# section, copy-for-copy: three files into clusters/example/capabilities/,
# each renamed per that section's instructions. Not a CI shortcut --
# this is the only documented way to turn this capability on.
mkdir -p "$REPO_ROOT/clusters/example/capabilities"
cp "$REPO_ROOT/capabilities/identity/cluster-kustomization.yaml" \
    "$REPO_ROOT/clusters/example/capabilities/identity.yaml"
cp "$REPO_ROOT/capabilities/identity/cluster-secrets-kustomization.yaml" \
    "$REPO_ROOT/clusters/example/capabilities/identity-secrets.yaml"
cp "$REPO_ROOT/apps/examples/identity/cluster-kustomization.yaml" \
    "$REPO_ROOT/clusters/example/capabilities/identity-examples.yaml"

NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

# ---------------------------------------------------------------------------
log "T-B: Phase 2/4: bootstrap/install.sh -- the real, unmodified installer"
# Same mechanism as T-A: install.sh's "cp -a $REPO_ROOT/." step carries
# the capability files added above straight into what gets committed and
# reconciled, exactly as a real operator's own copy-in would.
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-B: bootstrap/install.sh exited non-zero -- see the 'Step N/7' marker"
    echo "      above for which layer of the documented bootstrap sequence failed."
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ---------------------------------------------------------------------------
log "T-B: Phase 3/4: T-B postconditions"

not_ready=$(kc get kustomizations -A --no-header 2>/dev/null | awk -F'\t' '{gsub(/ /,"",$5); if ($5!="True") print $2}')
if [ -z "$not_ready" ]; then
    ok T-B/kustomizations-ready "every Flux Kustomization, including identity's, is Ready"
else
    fail T-B/kustomizations-ready "not Ready: $not_ready"
fi
kc get kustomizations -A || true

CA_CERT=/tmp/t-b-scrap-ca.crt
kc get secret -n cert-manager scrap-ca-key-pair -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d > "$CA_CERT" || true

AUTH_BASE="https://auth.${BASE_DOMAIN}"
RESOLVE_ARGS="--resolve p2.${BASE_DOMAIN}:443:${NODE_IP} --resolve p3.${BASE_DOMAIN}:443:${NODE_IP} --resolve auth.${BASE_DOMAIN}:443:${NODE_IP}"

# authentik_login <target_url> <cookiejar>
#
# Drives a REAL, non-interactive login against authentik's own
# flow-executor JSON API -- the same one its own frontend SPA calls --
# starting from whatever URL an unauthenticated request would hit (P2's
# own OIDC-authorize redirect, or the URL forward-auth itself redirects an
# unauthenticated P3 request to). Not a shortcut around the real
# mechanism: this submits the identification and password stages a
# browser's login form would, using the checked-in reference instance's
# own published-not-secret akadmin bootstrap credentials.
#
# Deliberately local to THIS script, not tests/profiles/lib.sh: P2 and P3
# both need it, but no other profile does, and the guessed-then-verified
# JSON contract it depends on (Authentik's own API, not SCRAP's) belongs
# next to the one profile that actually exercises identity, not promoted
# into shared plumbing other profiles would have to understand.
#
# Prints the final response body to stdout on success; prints diagnostic
# detail to stderr and returns nonzero on failure -- every stage's raw
# response is dumped on anything unexpected, since this is the one piece
# of this milestone whose exact contract (Authentik's flow-executor
# stage/field names) wasn't verified against a live instance before
# writing it. Treat a first failure here as a measurement, the same way
# t-a-minimal.sh's own early bugs were found -- not a sign the approach is
# wrong.
authentik_login() {
    start_url="$1"
    jar="$2"
    rm -f "$jar"

    loc1=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -D - -o /dev/null -c "$jar" -b "$jar" "$start_url" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r' | tail -1 || true)
    if [ -z "$loc1" ]; then
        echo "authentik_login: no redirect from starting URL: $start_url" >&2
        return 1
    fi

    loc2=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -D - -o /dev/null -c "$jar" -b "$jar" "$loc1" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r' | tail -1 || true)
    if [ -z "$loc2" ]; then
        echo "authentik_login: no redirect from the authorize endpoint: $loc1" >&2
        return 1
    fi

    # loc2 looks like https://auth.$BASE_DOMAIN/if/flow/<slug>/?<query> --
    # authentik's own frontend SPA calls the identical path+query under
    # /api/v3/flows/executor/ instead of /if/flow/ to drive the same flow
    # as JSON.
    flow_path=$(echo "$loc2" | sed -n 's#^https\?://[^/]*\(/if/flow/[^?]*\).*#\1#p')
    flow_slug=$(echo "$flow_path" | sed -n 's#^/if/flow/\([^/]*\)/\{0,1\}$#\1#p')
    flow_query=$(echo "$loc2" | sed -n 's#^[^?]*?##p')
    if [ -z "$flow_slug" ]; then
        echo "authentik_login: couldn't parse a flow slug out of the login redirect: $loc2" >&2
        return 1
    fi
    executor_url="${AUTH_BASE}/api/v3/flows/executor/${flow_slug}/?${flow_query}"
    referer="${AUTH_BASE}${flow_path}"

    # authentik's session/CSRF cookie is re-read fresh before each POST
    # (it can rotate) -- Netscape jar format, tab-separated, name is
    # field 6, value is field 7, regardless of the #HttpOnly_ prefix curl
    # adds to field 1 for HttpOnly cookies.
    csrf() { awk -F'\t' '$6=="authentik_csrf"{v=$7} END{print v}' "$jar"; }

    stage1=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -c "$jar" -b "$jar" \
        -H 'Accept: application/json' "$executor_url" 2>/dev/null || true)
    component1=$(echo "$stage1" | jq -r '.component // empty' 2>/dev/null || true)
    if [ "$component1" != "ak-stage-identification" ]; then
        echo "authentik_login: expected component ak-stage-identification, got '$component1'. Raw response:" >&2
        echo "$stage1" >&2
        return 1
    fi

    stage2=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -c "$jar" -b "$jar" \
        -H 'Accept: application/json' -H 'Content-Type: application/json' \
        -H "X-CSRFToken: $(csrf)" -H "Referer: $referer" \
        -d '{"uid_field":"akadmin"}' "$executor_url" 2>/dev/null || true)
    component2=$(echo "$stage2" | jq -r '.component // empty' 2>/dev/null || true)
    if [ "$component2" != "ak-stage-password" ]; then
        echo "authentik_login: expected component ak-stage-password after identification, got '$component2'. Raw response:" >&2
        echo "$stage2" >&2
        return 1
    fi

    stage3=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -c "$jar" -b "$jar" \
        -H 'Accept: application/json' -H 'Content-Type: application/json' \
        -H "X-CSRFToken: $(csrf)" -H "Referer: $referer" \
        -d "{\"password\":\"$AKADMIN_PASSWORD\"}" "$executor_url" 2>/dev/null || true)
    final_type=$(echo "$stage3" | jq -r '.type // empty' 2>/dev/null || true)
    final_to=$(echo "$stage3" | jq -r '.to // empty' 2>/dev/null || true)
    if [ "$final_type" != "redirect" ] || [ -z "$final_to" ]; then
        echo "authentik_login: expected a final redirect after submitting the password, got type='$final_type'. Raw response:" >&2
        echo "$stage3" >&2
        return 1
    fi

    # Follow the completion chain through -- this is where the OAuth2
    # authorize call actually finalizes and lands back on the
    # application's own redirect_uri (P2) or the originally requested URL
    # (P3), now carrying a real, authenticated session.
    curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -c "$jar" -b "$jar" -L "$final_to" 2>/dev/null || true
}

# 3a. P2 -- native OIDC, the full round trip: the app's own /debug entry
# point (its documented Verify step, apps/examples/p2-native-oidc/README.md)
# through a real login, ending on the app's own redirect_uri, which is
# where THIS specific demo image performs its own token exchange and
# prints the resulting ID token claims. "iss"/"aud" are real, guaranteed
# OIDC ID token claims -- not a SCRAP-specific field -- so their presence
# proves the app itself, not this script, validated a real token.
p2_debug_url="https://p2.${BASE_DOMAIN}/debug?oidc_client_id=scrap-p2-demo&oidc_client_secret=scrap-p2-demo-client-secret-not-sensitive&oidc_discovery=${AUTH_BASE}/application/o/scrap-p2-oidc-demo/.well-known/openid-configuration&oidc_redirect_uri=https://p2.${BASE_DOMAIN}/login"
if p2_final=$(authentik_login "$p2_debug_url" /tmp/t-b-p2-cookies); then
    if echo "$p2_final" | jq -e '.iss and .aud' >/dev/null 2>&1; then
        ok T-B/p2-native-oidc "the app completed a real login, exchanged the code itself, and printed real ID token claims (iss/aud present)"
    else
        fail T-B/p2-native-oidc "login completed but the app's final response has no iss/aud claims -- got: $(echo "$p2_final" | head -c 500)"
    fi
else
    fail T-B/p2-native-oidc "the scripted login against authentik's flow-executor API failed -- see the authentik_login diagnostic output above"
fi

# 3b. P3 -- the adversarial claim first: an unauthenticated request must
# never reach the protected app at all. Checked two independent ways --
# the HTTP status/Location say "redirected to authentik", and the body
# does NOT contain whoami's own marker string -- so this can't pass by
# accident on a redirect to the wrong place.
p3_unauth_headers=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -D - -o /tmp/t-b-p3-unauth-body \
    "https://p3.${BASE_DOMAIN}/" 2>/dev/null || true)
p3_unauth_status=$(echo "$p3_unauth_headers" | awk 'NR==1{print $2}')
p3_unauth_location=$(echo "$p3_unauth_headers" | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r' | tail -1)
p3_unauth_body=$(cat /tmp/t-b-p3-unauth-body 2>/dev/null || true)
case "$p3_unauth_status" in
    30[0-9])
        if echo "$p3_unauth_location" | grep -q "${BASE_DOMAIN}" && ! echo "$p3_unauth_body" | grep -q "Hostname:"; then
            ok T-B/p3-adversarial-unauth "an unauthenticated request never reached whoami -- redirected to authentik instead (status $p3_unauth_status -> $p3_unauth_location)"
        else
            fail T-B/p3-adversarial-unauth "got a redirect but not to authentik, or whoami's own marker leaked through anyway (status $p3_unauth_status, location '$p3_unauth_location')"
        fi
        ;;
    *)
        fail T-B/p3-adversarial-unauth "expected a redirect (30x) to authentik's login for an unauthenticated request, got status '$p3_unauth_status'"
        ;;
esac

# 3c. P3's positive claim: after a REAL login, the app is reachable and
# the identity headers Traefik's Middleware adds are visible in whoami's
# own echoed response -- proving they came from the Middleware, not from
# any code in the application itself (which never sees a client ID, a
# token, or an OIDC library at all).
if p3_final=$(authentik_login "https://p3.${BASE_DOMAIN}/" /tmp/t-b-p3-cookies); then
    if echo "$p3_final" | grep -q "Hostname:" && echo "$p3_final" | grep -qi "X-Authentik-Username"; then
        ok T-B/p3-forward-auth "after a real login, whoami is reachable and echoes X-Authentik-* headers the Middleware added -- the app itself never authenticated anything"
    else
        fail T-B/p3-forward-auth "login completed but the final response doesn't look like an authenticated whoami: $(echo "$p3_final" | head -c 500)"
    fi
else
    fail T-B/p3-forward-auth "the scripted login against authentik's flow-executor API failed -- see the authentik_login diagnostic output above"
fi

# ---------------------------------------------------------------------------
log "T-B: Phase 4/4: result"
if [ "$status" -ne 0 ]; then
    echo "T-B FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-B PASSED -- clean-host bootstrap with identity enabled, P2 and P3 verified end to end."
