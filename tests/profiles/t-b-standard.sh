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

# Same secret, the API bootstrap token -- same mechanism
# tests/dr/authentik-postgres-restore.sh already uses this for, needed
# here for the recovery-flow-exposure check's own structural
# corroboration (reading the Brand/IdentificationStage objects directly,
# not just what an anonymous request is shown).
AUTHENTIK_TOKEN=$(cd "$REPO_ROOT/clusters/example/secrets/identity" && \
    SOPS_AGE_KEY_FILE=../PUBLISHED-NOT-SECRET-reference.agekey \
    sops -d --extract '["stringData"]["AUTHENTIK_BOOTSTRAP_TOKEN"]' identity-credentials.sops.yaml)
if [ -z "$AUTHENTIK_TOKEN" ]; then
    echo "FAIL  T-B: could not decrypt the reference AUTHENTIK_BOOTSTRAP_TOKEN -- see"
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

# capabilities/grafana/README.md's own "Enabling this capability" --
# both files, since this run wants OIDC integration proven, not just
# local auth. This is Standard profile territory per the frozen
# architecture (Grafana is documented "on by default" in Standard,
# clusters/example/capabilities/README.md) -- T-B is where it belongs,
# not a separate acceptance surface, and reusing T-B's already-built
# authentik_login() helper against a SECOND relying party (Grafana,
# after P2) is exactly what proves the OIDC contract generalizes rather
# than happening to work for one hand-picked demo app.
cp "$REPO_ROOT/capabilities/grafana/cluster-kustomization.yaml" \
    "$REPO_ROOT/clusters/example/capabilities/grafana.yaml"
cp "$REPO_ROOT/capabilities/grafana/cluster-secrets-kustomization.yaml" \
    "$REPO_ROOT/clusters/example/capabilities/grafana-secrets.yaml"

NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

# ---------------------------------------------------------------------------
log "T-B: Phase 2/4: bootstrap/install.sh -- the real, unmodified installer"
# Same mechanism as T-A: install.sh's "cp -a $REPO_ROOT/." step carries
# the capability files added above straight into what gets committed and
# reconciled, exactly as a real operator's own copy-in would.
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
# HOME=/root for this one invocation only (see tests/profiles/lib.sh's
# kc() and tests/profiles/t-a-minimal.sh's own comment at this exact
# call for the full investigation): install.sh runs as root under
# `sudo -E`, which without this would preserve HOME=/home/runner into
# every root-privileged operation inside it, including its own internal
# kubectl calls -- leaving /home/runner/.kube/ poisoned (root-owned)
# for every later, genuinely-unprivileged kc() call in this script to
# fail against, confirmed live and reproduced deterministically (5/5)
# against T-A before this fix. Root gets its own real home; this
# script's own HOME (used by kc(), after setup_kubeconfig()) is
# untouched.
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-B: bootstrap/install.sh exited non-zero -- see the 'Step N/7' marker"
    echo "      above for which layer of the documented bootstrap sequence failed."
    exit 1
fi

setup_kubeconfig

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
RESOLVE_ARGS="--resolve p2.${BASE_DOMAIN}:443:${NODE_IP} --resolve p3.${BASE_DOMAIN}:443:${NODE_IP} --resolve auth.${BASE_DOMAIN}:443:${NODE_IP} --resolve grafana.${BASE_DOMAIN}:443:${NODE_IP}"

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

# 3a-pre. CA trust for in-cluster OIDC backend calls -- components/ca-trust/'s
# whole contract (see that directory's own README). P2's own login below
# already exercises this end to end -- its backend calls to
# https://auth.${BASE_DOMAIN} would fail outright with a TLS verification
# error without it, since nothing in this image's stock trust store knows
# the platform's private CA -- but a bare P2 failure doesn't say WHICH
# layer broke; a TLS error and a broken Blueprint look identical from the
# outside (both just fail the login). This checks the component's own
# wiring directly and attributably, before P2 runs, so a ca-trust
# regression fails here by name: the pod's own env carries
# SSL_CERT_FILE at the exact path the component's kustomization.yaml
# patches in, AND the platform's real CA (the same secret
# platform/cert-manager-config/ exports, already decoded into $CA_CERT
# above) is genuinely present inside the mounted scrap-ca-bundle
# ConfigMap's content -- not just that a bundle exists, but that it
# contains the right CA, not merely the stock system set.
p2_pod=$(kc get pods -n scrap-examples -l app=p2-oidc-debugger -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
p2_ssl_cert_file=$(kc get pod -n scrap-examples "$p2_pod" -o jsonpath='{.spec.containers[0].env[?(@.name=="SSL_CERT_FILE")].value}' 2>/dev/null || true)
kc get configmap -n scrap-examples scrap-ca-bundle -o jsonpath='{.data.ca-bundle\.crt}' > /tmp/t-b-p2-ca-bundle.pem 2>/dev/null || true
ca_in_bundle=""
if [ -s /tmp/t-b-p2-ca-bundle.pem ]; then
    ca_in_bundle=$(python3 -c "
needle = open('$CA_CERT').read().strip()
haystack = open('/tmp/t-b-p2-ca-bundle.pem').read()
print('yes' if needle and needle in haystack else 'no')
" 2>/dev/null || echo no)
fi
if [ "$p2_ssl_cert_file" = "/etc/ssl/scrap/ca-bundle.crt" ] && [ "$ca_in_bundle" = "yes" ]; then
    ok T-B/ca-trust-wiring "components/ca-trust/ wired SSL_CERT_FILE onto p2's own pod, and the platform's real CA is genuinely present in the mounted scrap-ca-bundle ConfigMap"
else
    fail T-B/ca-trust-wiring "SSL_CERT_FILE='$p2_ssl_cert_file' (expected /etc/ssl/scrap/ca-bundle.crt), CA present in bundle: '$ca_in_bundle' -- see components/ca-trust/README.md"
fi

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
# not a placeholder. Strengthened beyond bare presence: also requires
# preferred_username=="akadmin", the exact identity actually logged in
# with -- ties the claim to THIS specific login, not merely "some
# claims happened to be present," which a garbage-but-nonempty response
# could otherwise satisfy.
p2_debug_url="https://p2.${BASE_DOMAIN}/debug?oidc_client_id=scrap-p2-demo&oidc_client_secret=scrap-p2-demo-client-secret-not-sensitive&oidc_discovery=${AUTH_BASE}/application/o/scrap-p2-oidc-demo/.well-known/openid-configuration&oidc_redirect_uri=https://p2.${BASE_DOMAIN}/login"
if p2_final=$(authentik_login "$p2_debug_url" /tmp/t-b-p2-cookies); then
    if echo "$p2_final" | jq -e '
        .access_token_jwt_payload_decoded.iss and
        .access_token_jwt_payload_decoded.sub and
        (.access_token_jwt_payload_decoded.preferred_username == "akadmin")
    ' >/dev/null 2>&1; then
        ok T-B/p2-native-oidc "the app completed a real login, exchanged the code itself, and printed real ID token claims for the exact user logged in (iss/sub present, preferred_username=akadmin)"
    else
        fail T-B/p2-native-oidc "login completed but the app's final response is missing iss/sub, or preferred_username isn't akadmin -- got: $(echo "$p2_final" | head -c 1500)"
    fi
else
    fail T-B/p2-native-oidc "the scripted login against authentik's flow-executor API failed -- see the authentik_login diagnostic output above"
fi

# 3b. P3 -- the adversarial claim first: an unauthenticated request must
# never reach the protected app at all. Checked two independent ways --
# the HTTP status/Location say "redirected to authentik specifically",
# and the body does NOT contain whoami's own marker string -- so this
# can't pass by accident on a redirect to the wrong place. The Location
# check requires the exact host "auth.${BASE_DOMAIN}", not a loose
# substring match against "${BASE_DOMAIN}" -- p3.${BASE_DOMAIN} itself
# also contains that substring, so the looser check couldn't have told
# "redirected to authentik" apart from "redirected back to itself" on
# host alone; the body-marker check below is what actually carries that
# distinction, but the location check should say what it means too.
p3_unauth_headers=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -D - -o /tmp/t-b-p3-unauth-body \
    "https://p3.${BASE_DOMAIN}/" 2>/dev/null || true)
p3_unauth_status=$(echo "$p3_unauth_headers" | awk 'NR==1{print $2}')
p3_unauth_location=$(echo "$p3_unauth_headers" | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r' | tail -1)
p3_unauth_body=$(cat /tmp/t-b-p3-unauth-body 2>/dev/null || true)
case "$p3_unauth_status" in
    30[0-9])
        case "$p3_unauth_location" in
            https://auth."${BASE_DOMAIN}"/*)
                if ! echo "$p3_unauth_body" | grep -q "Hostname:"; then
                    ok T-B/p3-adversarial-unauth "an unauthenticated request never reached whoami -- redirected to authentik instead (status $p3_unauth_status -> $p3_unauth_location)"
                else
                    fail T-B/p3-adversarial-unauth "redirected to authentik but whoami's own marker leaked through in the response body anyway (status $p3_unauth_status, location '$p3_unauth_location')"
                fi
                ;;
            *)
                fail T-B/p3-adversarial-unauth "got a redirect but not to auth.${BASE_DOMAIN} specifically (status $p3_unauth_status, location '$p3_unauth_location')"
                ;;
        esac
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

# 3d. Grafana -- CA trust for its own backend OIDC calls, checked
# directly and attributably, same reasoning as 3a-pre above:
# extraConfigmapMounts/env reach the same real scrap-ca-bundle
# components/ca-trust/ uses, through the chart's own native extension
# points rather than the Kustomize component itself (which cannot attach
# to a Helm-rendered Deployment -- see capabilities/grafana/README.md).
grafana_pod=$(kc get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
# REAL BUG, found live via this script's own first run: containers[0]
# assumed the grafana container was first, but sidecar.dashboards.enabled
# (helmrelease.yaml) inserts a grafana-sc-dashboard sidecar BEFORE it in
# spec.containers -- confirmed via a direct `helm template` render, not
# guessed. Query by container NAME instead of position; the CA-trust
# wiring itself was correct all along, only this check's own assumption
# about container ordering was wrong.
grafana_ssl_cert_file=$(kc get pod -n monitoring "$grafana_pod" -o jsonpath='{.spec.containers[?(@.name=="grafana")].env[?(@.name=="SSL_CERT_FILE")].value}' 2>/dev/null || true)
kc get configmap -n monitoring scrap-ca-bundle -o jsonpath='{.data.ca-bundle\.crt}' > /tmp/t-b-grafana-ca-bundle.pem 2>/dev/null || true
grafana_ca_in_bundle=""
if [ -s /tmp/t-b-grafana-ca-bundle.pem ]; then
    grafana_ca_in_bundle=$(python3 -c "
needle = open('$CA_CERT').read().strip()
haystack = open('/tmp/t-b-grafana-ca-bundle.pem').read()
print('yes' if needle and needle in haystack else 'no')
" 2>/dev/null || echo no)
fi
if [ "$grafana_ssl_cert_file" = "/etc/ssl/scrap/ca-bundle.crt" ] && [ "$grafana_ca_in_bundle" = "yes" ]; then
    ok T-B/grafana-ca-trust-wiring "capabilities/grafana/'s chart-native CA mounting wired SSL_CERT_FILE onto grafana's own pod, and the platform's real CA is genuinely present in the mounted scrap-ca-bundle ConfigMap"
else
    fail T-B/grafana-ca-trust-wiring "SSL_CERT_FILE='$grafana_ssl_cert_file' (expected /etc/ssl/scrap/ca-bundle.crt), CA present in bundle: '$grafana_ca_in_bundle' -- see capabilities/grafana/README.md"
fi

# 3e. Grafana is absent from T-A -- structural, not inferred: T-A's own
# Kustomization tree (clusters/example/kustomization.yaml) never
# references capabilities/grafana/ at all unless this script's own Phase
# 1 copy-in added it, and T-A runs against a COMPLETELY SEPARATE cluster
# with no such copy-in ever happening. Restated here as a live,
# in-this-cluster fact for the record: capabilities/grafana/'s own
# Kustomization, not platform/observability/, is what applied this --
# deleting capabilities/grafana/ (T1) would remove exactly this and
# nothing platform/observability/ itself owns.
#
# REAL BUG, found live via this script's own first run: checked the
# CHART-RENDERED Deployment's own labels, which came back empty --
# Flux's kustomize.toolkit.fluxcd.io/name label is applied to resources
# Kustomize itself builds and applies directly; a Deployment a Helm
# chart renders (via helm-controller, tracked through Helm's own release
# mechanism, not kustomize-controller) never carries it. The HelmRelease
# object ITSELF is what's actually a raw resource in
# capabilities/grafana/'s own Kustomization -- checking that object,
# not what it causes to be rendered, is the correct, attributable proof.
grafana_owner=$(kc get helmrelease -n monitoring grafana -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}' 2>/dev/null || true)
if [ "$grafana_owner" = "grafana" ]; then
    ok T-B/grafana-capability-owned "the Grafana HelmRelease is owned by the capabilities/grafana/ Kustomization, not platform/observability/ -- T1 holds"
else
    fail T-B/grafana-capability-owned "expected the Grafana HelmRelease's owning Kustomization to be 'grafana', got '$grafana_owner'"
fi

# 3f. Grafana is actually connected to the platform's real Prometheus --
# not just that a datasource OBJECT exists, but that querying THROUGH it
# returns real, live platform telemetry. Local admin auth (the chart's
# own auto-generated credential) drives this -- deliberately not the
# OIDC session, since this is a claim about the datasource wiring, not
# about identity.
GRAFANA_ADMIN_PASS=$(kc get secret -n monitoring grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)
ds_list=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -u "admin:$GRAFANA_ADMIN_PASS" \
    "https://grafana.${BASE_DOMAIN}/api/datasources" 2>/dev/null || true)
ds_uid=$(echo "$ds_list" | jq -r '.[] | select(.type=="prometheus") | .uid' 2>/dev/null | head -1)
if [ -n "$ds_uid" ]; then
    query_result=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -u "admin:$GRAFANA_ADMIN_PASS" \
        "https://grafana.${BASE_DOMAIN}/api/datasources/proxy/uid/${ds_uid}/api/v1/query?query=up" 2>/dev/null || true)
    result_count=$(echo "$query_result" | jq -r '.data.result | length' 2>/dev/null || echo 0)
    if [ "${result_count:-0}" -gt 0 ]; then
        ok T-B/grafana-real-prometheus-query "querying THROUGH Grafana's own Prometheus datasource returned $result_count real time series (the 'up' metric) -- not just that the datasource object exists"
    else
        fail T-B/grafana-real-prometheus-query "datasource found (uid=$ds_uid) but querying through it returned no time series: $(echo "$query_result" | head -c 500)"
    fi
else
    fail T-B/grafana-real-prometheus-query "no prometheus-type datasource found via Grafana's own API: $(echo "$ds_list" | head -c 500)"
fi

# 3g. Anonymous access is genuinely off -- the adversarial check this
# capability's own security claim depends on.
#
# REAL BUG, found by this exact check's own negative-control run: the
# original version of this check queried /api/user, which returned 401
# regardless of auth.anonymous.enabled -- confirmed live, with anonymous
# access DELIBERATELY enabled, the check still reported 401 and passed.
# /api/user means "give me MY signed-in user record"; an anonymous
# session has no such record even when Grafana treats it as an
# authenticated Viewer for everything else, so 401 there proves nothing
# about whether anonymous viewing is actually possible. The real,
# security-relevant surface is whether an anonymous request can see real
# platform data -- /api/datasources (which would reveal the real
# Prometheus URL this capability configured) is what an anonymous
# bypass would actually expose, and is what this now checks instead.
anon_status=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -o /dev/null -w '%{http_code}' \
    "https://grafana.${BASE_DOMAIN}/api/datasources" 2>/dev/null || true)
if [ "$anon_status" = "401" ]; then
    ok T-B/grafana-adversarial-anon "an unauthenticated request to a real Grafana API endpoint exposing the platform's own configuration (/api/datasources) is rejected (401) -- no accidental anonymous bypass"
else
    fail T-B/grafana-adversarial-anon "expected 401 for an unauthenticated /api/datasources request, got '$anon_status' -- anonymous access may be accidentally enabled"
fi

# 3h. Native OIDC login through authentik, end to end, reusing the SAME
# scripted flow-executor login P2/P3 already prove works -- against a
# SECOND, independently-configured relying party, proving the contract
# generalizes. The final response is Grafana's OWN redirect target after
# its backend token exchange, not authentik's -- reading /api/user and
# /api/user/orgs through the SAME session cookie is what proves Grafana
# itself, not just authentik, recognizes this login.
if authentik_login "https://grafana.${BASE_DOMAIN}/login/generic_oauth" /tmp/t-b-grafana-cookies >/dev/null; then
    grafana_user=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -b /tmp/t-b-grafana-cookies \
        "https://grafana.${BASE_DOMAIN}/api/user" 2>/dev/null || true)
    grafana_orgs=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS -b /tmp/t-b-grafana-cookies \
        "https://grafana.${BASE_DOMAIN}/api/user/orgs" 2>/dev/null || true)
    grafana_login_name=$(echo "$grafana_user" | jq -r '.login // empty' 2>/dev/null || true)
    grafana_role=$(echo "$grafana_orgs" | jq -r '.[0].role // empty' 2>/dev/null || true)
    echo "      --- grafana /api/user ---"
    echo "$grafana_user" | sed 's/^/      /'
    echo "      --- grafana /api/user/orgs ---"
    echo "$grafana_orgs" | sed 's/^/      /'
    if [ "$grafana_login_name" = "akadmin" ] && [ "$grafana_role" = "Admin" ]; then
        ok T-B/grafana-native-oidc "a real login through authentik's own flow-executor ended with Grafana itself recognizing the exact user (login=akadmin) AND applying the expected role mapping (Admin, via the scrap-admins group's groups claim) -- not just that some session was created"
    else
        fail T-B/grafana-native-oidc "login completed but Grafana's own /api/user or /api/user/orgs didn't show the expected identity/role (login='$grafana_login_name', role='$grafana_role')"
    fi
else
    fail T-B/grafana-native-oidc "the scripted login against authentik's flow-executor API failed for Grafana's own /login/generic_oauth -- see the authentik_login diagnostic output above"
fi

# 3i/3j. Identity's own still-open obligation
# (docs/decisions/0002-identity-implementation.md: "Authentik's own
# recovery flows need adversarial testing, not just functional
# testing"). Not a general Authentik penetration test -- SCRAP is
# responsible for proving its OWN configuration doesn't violate the
# frozen security contract, not for re-auditing Authentik itself. This
# targets one specific, non-hypothetical invariant: a real account-
# takeover bug found live, twice, against production identity (recorded
# for context, not reproduced here) -- an unauthenticated party who
# knows only a username reaching a "set a new password" form with no
# possession-of-factor challenge at all, through TWO independent public
# entry points (the identification stage's own recovery_flow field, and
# the password stage's separate fallback to the Brand's flow_recovery).
# capabilities/identity/blueprints-configmap.yaml never touches either
# field -- SCRAP's shipped configuration is silent on self-service
# recovery, which is a different claim from proven safe. Checked two
# independent ways, deliberately not just one:

# authentik_api <method> <path> [json-body] -- same pattern as
# tests/dr/authentik-postgres-restore.sh's own helper of the same name
# (a direct, authenticated REST call using the bootstrap token as a
# Bearer credential). Not duplicated from lib.sh: this is the only place
# in THIS script that needs authenticated admin API access, the same
# reasoning tests/profiles/t-b-standard.sh's own authentik_login already
# documents for keeping flow-executor specifics local rather than
# shared.
authentik_api() {
    method="$1"; path="$2"; body="${3:-}"
    curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS \
        -X "$method" -H "Authorization: Bearer $AUTHENTIK_TOKEN" -H "Content-Type: application/json" \
        -w '\n%{http_code}' ${body:+-d "$body"} "${AUTH_BASE}${path}" 2>/dev/null || true
}
api_status() { echo "$1" | tail -1; }
api_body()   { echo "$1" | sed '$d'; }

# 3i. Structural: ground truth, read directly from the objects
# themselves rather than inferred from what a client is shown -- every
# Brand's flow_recovery, and every IdentificationStage's own
# recovery_flow, across the whole instance (not filtered to "the
# default one" by name/slug guesswork: a fresh, Blueprint-only install
# ships exactly one of each, and checking the full list is both simpler
# and correct regardless of what authentik names them internally).
brands_resp=$(authentik_api GET /api/v3/core/brands/)
idstages_resp=$(authentik_api GET /api/v3/stages/identification/)
brands_bound=$(api_body "$brands_resp" | jq -r '[.results[]? | select(.flow_recovery != null) | .domain] | join(",")' 2>/dev/null || true)
idstages_bound=$(api_body "$idstages_resp" | jq -r '[.results[]? | select(.recovery_flow != null) | .name] | join(",")' 2>/dev/null || true)
if [ "$(api_status "$brands_resp")" = "200" ] && [ "$(api_status "$idstages_resp")" = "200" ] \
    && [ -z "$brands_bound" ] && [ -z "$idstages_bound" ]; then
    ok T-B/identity-no-recovery-flow-configured "no Brand's flow_recovery and no IdentificationStage's recovery_flow is bound to anything, read directly from the objects themselves -- the exact two fields Part 17.6/18.2's real production account-takeover bug went through"
else
    fail T-B/identity-no-recovery-flow-configured "a recovery flow is bound somewhere: brands with flow_recovery set=[$brands_bound], identification stages with recovery_flow set=[$idstages_bound] (brands HTTP $(api_status "$brands_resp"), stages HTTP $(api_status "$idstages_resp"))"
fi

# 3j. Behavioral: what an actual anonymous client sees, reaching the
# SAME two live entry points the real bug was found through -- the
# identification stage's own initial challenge, and the password stage
# reached immediately after submitting nothing but a username, no
# password ever sent. Deliberately its own small sequence, not a reuse
# of authentik_login()'s internals: that function's helper closures
# (flow_stage, csrf, ...) rely on plain, non-`local` shell variables
# left over from whichever call last ran, and this probe needs to be
# correct in isolation. Scans EVERY key anywhere in each stage's own
# JSON challenge for anything recovery-related, rather than a single
# guessed field name -- robust to not knowing authentik's exact
# response shape in advance, and this is the same data authentik's own
# frontend SPA renders the login page's links from, so a real bound
# recovery flow has to surface here in SOME form or the frontend
# couldn't render a link to it either.
recovery_jar=/tmp/t-b-recovery-probe-cookies
rm -f "$recovery_jar"
id_url="${AUTH_BASE}/api/v3/flows/executor/default-authentication-flow/"
id_stage=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS \
    -H 'Accept: application/json' -c "$recovery_jar" -b "$recovery_jar" "$id_url" 2>/dev/null || true)
id_csrf=$(awk -F'\t' '$6=="authentik_csrf"{v=$7} END{print v}' "$recovery_jar")
pw_stage=$(curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -H "X-CSRFToken: $id_csrf" -H "Referer: ${AUTH_BASE}/if/flow/default-authentication-flow/" \
    -c "$recovery_jar" -b "$recovery_jar" -d '{"uid_field":"akadmin"}' "$id_url" 2>/dev/null || true)
echo "      --- anonymous probe: identification-stage challenge ---"
echo "$id_stage" | sed 's/^/      /'
echo "      --- anonymous probe: password-stage challenge (username submitted, no password) ---"
echo "$pw_stage" | sed 's/^/      /'
id_leak=$(echo "$id_stage" | jq -c '[.. | objects | to_entries[]? | select(.key | test("recover"; "i")) | select(.value != null and .value != "" and .value != false)]' 2>/dev/null || echo '["parse error"]')
pw_leak=$(echo "$pw_stage" | jq -c '[.. | objects | to_entries[]? | select(.key | test("recover"; "i")) | select(.value != null and .value != "" and .value != false)]' 2>/dev/null || echo '["parse error"]')
if [ "$id_leak" = "[]" ] && [ "$pw_leak" = "[]" ]; then
    ok T-B/identity-adversarial-recovery "an anonymous request reaching both real entry points (identification stage, then password stage after submitting only a username) is shown no recovery affordance in either stage's own challenge -- no unauthenticated path to a password-set form"
else
    fail T-B/identity-adversarial-recovery "an anonymous request was shown a recovery-related field: identification stage=$id_leak, password stage=$pw_leak -- see the raw challenges above"
fi

# ---------------------------------------------------------------------------
log "T-B: Phase 4/4: result"
if [ "$status" -ne 0 ]; then
    echo "T-B FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-B PASSED -- clean-host bootstrap with identity enabled, P2 and P3 verified end to end."
