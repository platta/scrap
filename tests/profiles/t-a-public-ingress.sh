#!/bin/sh
# T-A-public-ingress -- live acceptance for capabilities/public-ingress/'s
# own verify-live.sh.
#
# Unlike every other capability, public-ingress ships no Kustomization at
# all (docs/decisions/0014-public-ingress-edge-authority.md) -- there is
# nothing to enable or disable in-cluster, so this profile proves
# something different: that verify-live.sh's own decisive oracle (does
# the certificate served at a target genuinely match the platform's real
# wildcard certificate, byte-for-byte by SHA-256 fingerprint) is sound --
# green against this cluster's real, genuinely-serving Gateway, red
# against a deliberately different TLS endpoint. A verifier that had
# never been shown to turn red would be aspirational prose with a
# shebang, not a proof -- the same standard every other capability's own
# negative control holds to.
#
# A SEPARATE from-zero bootstrap from T-A's own, same reasoning as every
# other live profile's identical comment -- this live-edits
# instance-config.yaml's own NODE_ADDRESS to a real, routable value (the
# checked-in "example" instance ships an RFC 5737 documentation
# placeholder there, never meant to be live), so it must never run
# against a cluster some other check still depends on.
#
# The "wrong" TLS endpoint for the negative control is a real, ephemeral
# openssl s_server instance this script stands up itself, presenting a
# genuinely different, freshly-generated self-signed certificate -- the
# same "real, disposable, no mock" shape every other live profile's own
# ephemeral service already establishes. A human can run this
# identically on their own scratch VM, given openssl on PATH:
#   sh tests/profiles/t-a-public-ingress.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

status=0

# Stays well clear of platform/ingress/reserved-ports.yaml's own reserved
# range and of the other live profiles' own ephemeral ports -- same
# reasoning their own identical comments give.
WRONG_TLS_PORT=15390

# ---------------------------------------------------------------------------
log "T-A-public-ingress: Phase 0/4: environment prerequisites"
install_prereqs
if ! command -v openssl >/dev/null 2>&1; then
    apt_install openssl
fi
if ! command -v dig >/dev/null 2>&1; then
    apt_install dnsutils
fi

# ---------------------------------------------------------------------------
log "T-A-public-ingress: Phase 1/4: bootstrap/install.sh -- the real, unmodified installer"
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A-public-ingress: bootstrap/install.sh exited non-zero -- see the"
    echo "      'Step N/7' marker above for which layer of the documented bootstrap"
    echo "      sequence failed."
    exit 1
fi

setup_kubeconfig

not_ready=$(kc get kustomizations -A -o json | jq -r '
    .items[] |
    (.status.conditions // [] | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
    select($ready != "True") |
    "\(.metadata.namespace)/\(.metadata.name) (ready=\($ready))"
')
if [ -z "$not_ready" ]; then
    ok T-A-public-ingress/kustomizations-ready "every Flux Kustomization is Ready from a from-zero bootstrap"
else
    fail T-A-public-ingress/kustomizations-ready "not Ready: $not_ready"
fi

# ---------------------------------------------------------------------------
log "T-A-public-ingress: Phase 2/4: point NODE_ADDRESS at this runner's own real address"

# REAL FINDING, made designing this profile: NODE_ADDRESS is consumed
# nowhere in-cluster except apps/examples/p6-external-proxy/'s own
# demonstration EndpointSlice -- the Gateway itself is reached via its
# LoadBalancer Service's own address, assigned by k3s's ServiceLB, never
# by instance-config at all. The checked-in "example" instance's own
# NODE_ADDRESS is a deliberate RFC 5737 documentation placeholder
# (192.0.2.10), which is why a real instance's own setup requires
# replacing it -- exactly what this live edit does, the same way every
# other live profile substitutes a real value for whatever this
# capability's own runbook actually depends on.
NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

BARE_REPO=/var/lib/scrap/repo.git
LIVEDIR=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR"
sed -i "s|^\(  NODE_ADDRESS: \).*|\1\"$NODE_IP\"|" "$LIVEDIR/clusters/example/instance-config.yaml"
( cd "$LIVEDIR" && git add -A && git -c user.email=t-a-public-ingress@localhost -c user.name="T-A-public-ingress" \
    commit -q -m "T-A-public-ingress: point NODE_ADDRESS at this runner's own real address" && \
    git push -q origin main )
# Same disposable post-push scratch-cleanup race bootstrap/install.sh's
# own `rm -rf "$WORKDIR" || true` and t-a-dyndns.sh's `$LIVEDIR4` site
# (PLAT-92) are hardened against ("rm: cannot remove '.../.git':
# Directory not empty", a `git clone`'s own `.git` occasionally still
# settling by the time `rm -rf` lists it): the git push above already
# landed the real work, and $LIVEDIR is a `mktemp -d` clone with no
# further purpose. PLAT-93.
rm -rf "$LIVEDIR" || true

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null

# ---------------------------------------------------------------------------
log "T-A-public-ingress: Phase 3/4: an ephemeral, real, WRONG TLS endpoint for the negative control"

WRONG_TLS_DIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$WRONG_TLS_DIR/wrong.key" -out "$WRONG_TLS_DIR/wrong.crt" \
    -subj "/CN=not-the-real-platform.invalid" >/dev/null 2>&1
nohup openssl s_server -quiet -accept "$WRONG_TLS_PORT" \
    -cert "$WRONG_TLS_DIR/wrong.crt" -key "$WRONG_TLS_DIR/wrong.key" \
    >/tmp/t-a-public-ingress-wrong-tls.log 2>&1 &
WRONG_TLS_PID=$!

wrong_tls_up=""
i=0
while [ "$i" -lt 10 ]; do
    if echo | openssl s_client -connect "127.0.0.1:$WRONG_TLS_PORT" >/dev/null 2>&1; then
        wrong_tls_up=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ -z "$wrong_tls_up" ]; then
    echo "FAIL  T-A-public-ingress: the ephemeral wrong-TLS endpoint never came up -- see /tmp/t-a-public-ingress-wrong-tls.log"
    cat /tmp/t-a-public-ingress-wrong-tls.log 2>/dev/null || true
    exit 1
fi
echo "ephemeral wrong-TLS endpoint up (pid $WRONG_TLS_PID) on port $WRONG_TLS_PORT, presenting a genuinely different, freshly-generated self-signed certificate"

# ---------------------------------------------------------------------------
log "T-A-public-ingress: Phase 4/4: verify-live.sh's own oracle, proven both ways"

# 4a. POSITIVE: pointed at this cluster's own real Gateway, the
# certificate-identity check must PASS -- a genuine SHA-256 fingerprint
# match against the real Secret cert-manager wrote, not a guess.
#
# REAL BUG, found by inspection before this ever ran live: `if CMD | sed
# ...; then` tests sed's OWN exit status (always 0, plain text
# substitution never fails), never CMD's -- the exact class of mistake
# tests/profiles/lib.sh's own wait_for_pod_gone() comment already
# documents finding once in this project's history. Redirecting to a
# file first, then sed-ing the file separately for display, is what
# 4b already does below; made consistent here too, so the `if` tests
# verify-live.sh's own real exit code directly, no pipe involved.
echo "      --- verify-live.sh, positive: pointed at the platform's own real Gateway ---"
if PUBLIC_INGRESS_TARGET="$NODE_IP:443" sh "$REPO_ROOT/capabilities/public-ingress/verify-live.sh" >/tmp/t-a-public-ingress-positive.log 2>&1; then
    sed 's/^/      /' /tmp/t-a-public-ingress-positive.log
    ok T-A-public-ingress/verify-live-passes-against-real-gateway "verify-live.sh exits successfully when pointed at this cluster's own real Gateway -- the certificate-identity check genuinely matched the platform's own wildcard certificate by SHA-256 fingerprint"
else
    sed 's/^/      /' /tmp/t-a-public-ingress-positive.log
    fail T-A-public-ingress/verify-live-passes-against-real-gateway "verify-live.sh exited non-zero when pointed at this cluster's own real, genuinely-serving Gateway -- see its own output above"
fi

# 4b. NEGATIVE CONTROL: pointed at the ephemeral wrong-TLS endpoint --
# genuinely reachable, genuinely serving A certificate, just not THIS
# platform's own -- the check must FAIL, not silently pass. This is the
# actual oracle-soundness proof: closes the same class of vacuous-pass
# gap capabilities/logs/'s own never-emitted-marker check closes for a
# different capability.
echo "      --- verify-live.sh, negative control: pointed at a real but WRONG TLS endpoint ---"
if PUBLIC_INGRESS_TARGET="127.0.0.1:$WRONG_TLS_PORT" sh "$REPO_ROOT/capabilities/public-ingress/verify-live.sh" >/tmp/t-a-public-ingress-negative.log 2>&1; then
    sed 's/^/      /' /tmp/t-a-public-ingress-negative.log
    fail T-A-public-ingress/verify-live-rejects-wrong-certificate "verify-live.sh exited successfully when pointed at a deliberately WRONG (but genuinely reachable) TLS endpoint -- the certificate-identity check must reject a fingerprint mismatch, not pass it"
else
    sed 's/^/      /' /tmp/t-a-public-ingress-negative.log
    ok T-A-public-ingress/verify-live-rejects-wrong-certificate "verify-live.sh genuinely exits non-zero when pointed at a real but WRONG TLS endpoint -- the fingerprint mismatch was actually detected, not silently accepted"
fi

kill "$WRONG_TLS_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
log "T-A-public-ingress: result"
if [ "$status" -ne 0 ]; then
    echo "T-A-public-ingress FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A-public-ingress PASSED -- verify-live.sh's own certificate-identity oracle is genuinely sound: it passes against this cluster's real Gateway and genuinely rejects a deliberately different TLS endpoint, never inferred, both proven live."
