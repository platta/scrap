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

# install.sh's own postflight.sh only waits 5 minutes before giving up
# (and deliberately ignores its own exit code, "|| true") -- fine for
# T-A's Kustomization set, genuinely too short for identity's: standing
# up Authentik + a bundled Postgres from a cold image cache can take
# longer than that on a shared CI runner, and identity's own
# cluster-kustomization.yaml already declares a 10m0s ceiling for
# itself. Rather than trust postflight already settled this, poll again
# here for up to 15 minutes -- long enough to cover that ceiling with
# room to spare, short enough to fail this specific postcondition
# distinctly rather than let a genuinely stuck install run out the
# clock silently.
kustomizations_ready=""
i=0
while [ "$i" -lt 90 ]; do
    not_ready=$(kc get kustomizations -A --no-header 2>/dev/null | awk -F'\t' '{gsub(/ /,"",$5); if ($5!="True") print $2}')
    if [ -z "$not_ready" ]; then
        kustomizations_ready=1
        break
    fi
    sleep 10
    i=$((i + 1))
done
if [ -n "$kustomizations_ready" ]; then
    ok T-B/kustomizations-ready "every Flux Kustomization, including identity's, is Ready"
else
    fail T-B/kustomizations-ready "not Ready after 15 minutes: $not_ready"
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
# resolve_location <base_url> <location_header_value>
#
# A Location header is allowed by RFC 7231 to be relative to the request
# it answers, not just an absolute URL -- found real, not theoretical:
# authentik's own login-flow redirect (the /if/flow/... hop) sends a bare
# path ("/if/flow/default-authentication-flow/?..."), no scheme or host
# at all, which broke the flow-slug parsing below the first time a login
# actually got this far. Every curl call in this function resolves its
# Location through this first, so an absolute-URL assumption doesn't
# quietly break again at some other hop.
resolve_location() {
    base="$1"; loc="$2"
    case "$loc" in
        http://*|https://*) echo "$loc" ;;
        /*) echo "$base" | sed -n 's#^\(https\?://[^/]*\).*#\1#p' | { read -r origin; echo "${origin}${loc}"; } ;;
        *) echo "$loc" ;;
    esac
}

authentik_login() {
    start_url="$1"
    jar="$2"
    rm -f "$jar"

    loc1_raw=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -D - -o /dev/null -c "$jar" -b "$jar" "$start_url" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r' | tail -1 || true)
    loc1=$(resolve_location "$start_url" "$loc1_raw")
    echo "authentik_login: trace: start_url=$start_url -> loc1=$loc1" >&2
    if [ -z "$loc1_raw" ]; then
        echo "authentik_login: no redirect from starting URL: $start_url" >&2
        return 1
    fi

    loc2_raw=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -D - -o /dev/null -c "$jar" -b "$jar" "$loc1" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r' | tail -1 || true)
    loc2=$(resolve_location "$loc1" "$loc2_raw")
    echo "authentik_login: trace: loc1 -> loc2=$loc2" >&2
    if [ -z "$loc2_raw" ]; then
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

    # The flow's own completion signal turned out not to carry the real
    # destination -- REAL FINDING, confirmed against the actual response:
    # once the flow genuinely completes, it returns
    # {"component": "xak-flow-redirect", "to": "/", "final_redirect": true},
    # not the {"type": "redirect", "to": <real url>} shape this script
    # originally assumed. "to" here is a generic post-login default
    # ("/"), not the OAuth2 authorize continuation -- that continuation
    # is the "next" query parameter loc2 already carried (the same
    # mechanism authentik's own frontend SPA holds onto client-side and
    # navigates to itself once a flow reports done, rather than trusting
    # the flow's own "to" field). Decoded and resolved once, up front,
    # so the actual completion check below only has to use it.
    # POSIX printf's %b does not understand \xHH hex escapes -- that's a
    # bash extension, silently a no-op under dash (confirmed live: the
    # sed-plus-printf version of this that seemed obviously right left
    # every %XX sequence completely undecoded when actually run under
    # /bin/sh, this script's own shebang). python3 -- already relied on
    # elsewhere on this same runner image (t-a-minimal.sh's real P6
    # backend) -- has its own correct implementation; use that instead
    # of a second hand-rolled decoder.
    urldecode() { python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]), end='')" "$1"; }
    next_raw=$(printf '%s' "$flow_query" | tr '&' '\n' | sed -n 's/^next=//p')
    next_url=$(resolve_location "$AUTH_BASE" "$(urldecode "$next_raw")")

    # authentik's session/CSRF cookie is re-read fresh before each POST
    # (it can rotate) -- Netscape jar format, tab-separated, name is
    # field 6, value is field 7, regardless of the #HttpOnly_ prefix curl
    # adds to field 1 for HttpOnly cookies.
    csrf() { awk -F'\t' '$6=="authentik_csrf"{v=$7} END{print v}' "$jar"; }

    # A response from -i is "status line\r\nheaders\r\n\r\nbody" -- body
    # is everything after the first blank line; on a redirect, curl's -i
    # output for a chained request (this endpoint doesn't get -L) is
    # just the one response, so the first blank line reliably separates
    # headers from body here.
    stage_body() { printf '%s' "$1" | awk 'body{print} /^\r?$/{body=1}'; }
    stage_status() { printf '%s' "$1" | awk 'NR==1{print $2; exit}'; }
    stage_location() { printf '%s' "$1" | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r' | tail -1; }

    # flow_stage [POST-json-body] -- GETs (no body arg) or POSTs the
    # executor URL, and follows exactly one redirect as a plain GET if
    # the response is one. REAL FINDING: the identification POST's
    # first-ever real response was a bare 302, Location pointing right
    # back at this same executor URL -- a POST/Redirect/GET pattern, not
    # the "the next stage's JSON comes back inline" shape this function
    # originally assumed. authentik's own frontend SPA presumably just
    # follows redirects like a browser does automatically; a script using
    # the raw API has to do that step itself.
    flow_stage() {
        raw=$(curl -s -i --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -c "$jar" -b "$jar" \
            -H 'Accept: application/json' -H 'Content-Type: application/json' \
            -H "X-CSRFToken: $(csrf)" -H "Referer: $referer" \
            ${1:+-d "$1"} "$executor_url" 2>/dev/null || true)
        # Loop, not a single hop: the first redirect this uncovered
        # (identification -> executor) turned out not to be the only
        # one -- the password stage's own completion redirected back to
        # the executor again too. Bounded at 5, generous for a flow with
        # at most a couple of PRG hops in a row; a real infinite loop
        # here would mean something is genuinely wrong, and this stops
        # short of hanging the whole script on it.
        hops=0
        while [ "$hops" -lt 5 ]; do
            case "$(stage_status "$raw")" in
                3??) : ;;
                *) break ;;
            esac
            next=$(resolve_location "$executor_url" "$(stage_location "$raw")")
            raw=$(curl -s -i --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -c "$jar" -b "$jar" \
                -H 'Accept: application/json' -H "Referer: $referer" "$next" 2>/dev/null || true)
            hops=$((hops + 1))
        done
        printf '%s' "$raw"
    }

    stage1=$(flow_stage)
    component1=$(stage_body "$stage1" | jq -r '.component // empty' 2>/dev/null || true)
    if [ "$component1" != "ak-stage-identification" ]; then
        echo "authentik_login: expected component ak-stage-identification, got '$component1' (HTTP $(stage_status "$stage1"), Location: $(stage_location "$stage1")). Raw body:" >&2
        stage_body "$stage1" >&2
        return 1
    fi

    stage2=$(flow_stage '{"uid_field":"akadmin"}')
    component2=$(stage_body "$stage2" | jq -r '.component // empty' 2>/dev/null || true)
    if [ "$component2" != "ak-stage-password" ]; then
        echo "authentik_login: expected component ak-stage-password after identification, got '$component2' (HTTP $(stage_status "$stage2"), Location: $(stage_location "$stage2")). Raw body:" >&2
        stage_body "$stage2" >&2
        return 1
    fi

    stage3=$(flow_stage "{\"password\":\"$AKADMIN_PASSWORD\"}")
    final_component=$(stage_body "$stage3" | jq -r '.component // empty' 2>/dev/null || true)
    final_done=$(stage_body "$stage3" | jq -r '.final_redirect // false' 2>/dev/null || true)
    if [ "$final_component" != "xak-flow-redirect" ] || [ "$final_done" != "true" ] || [ -z "$next_url" ]; then
        echo "authentik_login: expected the flow to report done (xak-flow-redirect, final_redirect=true) after submitting the password, got component='$final_component' final_redirect='$final_done' next_url='$next_url' (HTTP $(stage_status "$stage3"), Location: $(stage_location "$stage3")). Raw body:" >&2
        stage_body "$stage3" >&2
        return 1
    fi

    # Follow the ORIGINAL "next" continuation, not the flow's own "to"
    # (which is just "/" -- see the comment where next_url was computed).
    # This is where the OAuth2 authorize call actually finalizes and
    # lands back on the application's own redirect_uri (P2) or the
    # originally requested URL (P3), now carrying a real, authenticated
    # session.
    curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -c "$jar" -b "$jar" -L "$next_url" 2>/dev/null || true
}

# 3a. P2 -- native OIDC, the full round trip: the app's own /debug entry
# point (its documented Verify step, apps/examples/p2-native-oidc/README.md)
# through a real login, ending on the app's own redirect_uri, which is
# where THIS specific demo image performs its own token exchange and
# prints the resulting ID token claims nested under
# .access_token_jwt_payload_decoded -- confirmed against a real
# response, not assumed (a top-level .iss/.aud, this check's first
# guess, was wrong: this image wraps the decoded payload one level
# down). "iss" and "sub" inside it are real, guaranteed OIDC ID token
# claims -- not a SCRAP-specific field -- so their presence proves the
# app itself, not this script, validated a real token: the observed
# "iss" was genuinely "https://auth.${BASE_DOMAIN}/application/o/scrap-p2-oidc-demo/",
# not a placeholder.
p2_debug_url="https://p2.${BASE_DOMAIN}/debug?oidc_client_id=scrap-p2-demo&oidc_client_secret=scrap-p2-demo-client-secret-not-sensitive&oidc_discovery=${AUTH_BASE}/application/o/scrap-p2-oidc-demo/.well-known/openid-configuration&oidc_redirect_uri=https://p2.${BASE_DOMAIN}/login"
if p2_final=$(authentik_login "$p2_debug_url" /tmp/t-b-p2-cookies); then
    if echo "$p2_final" | jq -e '.access_token_jwt_payload_decoded.iss and .access_token_jwt_payload_decoded.sub' >/dev/null 2>&1; then
        ok T-B/p2-native-oidc "the app completed a real login, exchanged the code itself, and printed real ID token claims (iss/sub present)"
    else
        fail T-B/p2-native-oidc "login completed but the app's final response has no iss/sub claims -- got: $(echo "$p2_final" | head -c 1500)"
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
