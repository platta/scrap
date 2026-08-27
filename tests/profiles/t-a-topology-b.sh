#!/bin/sh
# T-A-topology-b -- live acceptance for the ADR-0009 Topology B onboarding
# path: bootstrap/generate-topology-b.sh's generated operator repository
# genuinely bootstraps and reconciles, sourcing platform/ content from a
# SEPARATE, independently pinned "scrap-platform" GitRepository rather than
# from its own repository -- the actual structural claim Topology B makes,
# not just that some bootstrap succeeds.
#
# Same expectations as tests/profiles/t-a-minimal.sh: a normal user,
# passwordless sudo, a genuinely fresh host, never run this whole script
# under `sudo` itself. A SEPARATE from-zero bootstrap from every other
# profile's own, same reasoning as theirs.
#
# CI-hosting note, stated honestly: this test hosts BOTH the generated
# operator repository and the pinned "upstream" it consumes from ONE local
# bare Git repository (two different commits on the same branch, two
# independent GitRepository objects with independent refs -- flux-system
# tracks the branch tip, scrap-platform pins the earlier commit) rather than
# two physically separate repositories/hosts. Flux's own source-controller
# treats each GitRepository object as an independent poll target regardless
# of whether their URLs happen to coincide, so this genuinely exercises the
# real mechanism (a second, independently pinned GitRepository whose ref
# differs from flux-system's own) without inventing new SSH-hosting
# plumbing beyond what bootstrap/install.sh's own D5 default path already
# proves works. A real Topology B install typically points scrap-platform
# at a genuinely different, publicly-hosted repository (the generator's own
# default, https://github.com/platta/scrap) -- see
# docs/decisions/0009-repository-topology.md.
#
# A human can run this identically on their own scratch VM:
#   sh tests/profiles/t-a-topology-b.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

status=0
INSTANCE_NAME=topology-b-instance

# ---------------------------------------------------------------------------
log "T-A-topology-b: Phase 0/7: environment prerequisites"
install_prereqs

# ---------------------------------------------------------------------------
log "T-A-topology-b: Phase 1/7: generator input validation -- instance-name, no cluster needed"
# Fast, local, no-cluster checks of bootstrap/generate-topology-b.sh's own
# instance-name contract (an RFC 1123 DNS label) -- run first, before any
# of the expensive live-bootstrap phases below, since a broken validator is
# exactly the kind of defect that should fail loud and cheap. Closes a
# real, reviewed defect: an earlier version of the generator accepted "."
# and ".." (rejecting only an empty name or one containing "/"), under
# which CLUSTER_DIR resolved to the output directory itself and the
# generator silently wrote -- and committed -- a malformed repository
# instead of failing safely (PLAT-38 review).
VALIDATION_DIR=/tmp/t-a-topology-b-validation
VALIDATION_LOG=/tmp/t-a-topology-b-validation.log
rm -rf "$VALIDATION_DIR"

# assert_generator_rejects <bad-name> <label> -- runs the generator against
# a fresh, otherwise-untouched output directory and asserts BOTH a nonzero
# exit AND that no partial repository was left behind: an invalid name
# that still leaves files on disk is exactly the "malformed repository
# committed anyway" failure mode this exists to catch.
assert_generator_rejects() {
    bad_name="$1"; check_label="$2"
    out="$VALIDATION_DIR/$check_label"
    rm -rf "$out"
    if sh "$REPO_ROOT/bootstrap/generate-topology-b.sh" "$out" "$bad_name" >"$VALIDATION_LOG" 2>&1; then
        fail "T-A-topology-b/reject-$check_label" "generate-topology-b.sh exited 0 for instance-name '$bad_name' -- expected a nonzero exit"
        return
    fi
    if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
        fail "T-A-topology-b/reject-$check_label" "instance-name '$bad_name' was rejected (nonzero exit) but left a partial repository behind at $out"
        return
    fi
    ok "T-A-topology-b/reject-$check_label" "instance-name '$bad_name' rejected with a nonzero exit and no partial output"
}

assert_generator_rejects "." "dot"
assert_generator_rejects ".." "dotdot"
assert_generator_rejects "topology/b" "slash"
assert_generator_rejects "has space" "whitespace"
assert_generator_rejects "bad;name\`x\`" "metacharacter"

# Positive boundary case: the shortest possible valid RFC 1123 DNS label (a
# single lowercase letter) must still be ACCEPTED -- proves the validator
# isn't merely rejecting everything.
BOUNDARY_DIR="$VALIDATION_DIR/boundary-valid"
rm -rf "$BOUNDARY_DIR"
if sh "$REPO_ROOT/bootstrap/generate-topology-b.sh" "$BOUNDARY_DIR" "x" >"$VALIDATION_LOG" 2>&1 \
    && [ -d "$BOUNDARY_DIR/clusters/x" ]; then
    ok T-A-topology-b/accept-boundary "a minimal single-character instance-name ('x') is accepted and generates clusters/x/"
else
    fail T-A-topology-b/accept-boundary "a minimal, valid single-character instance-name ('x') was rejected -- validation is too strict"
    sed 's/^/      /' "$VALIDATION_LOG" || true
fi
rm -rf "$VALIDATION_DIR"
rm -f "$VALIDATION_LOG"

# ---------------------------------------------------------------------------
log "T-A-topology-b: Phase 2/7: host a local bare repo over SSH-to-localhost -- same"
log "mechanism bootstrap/install.sh's own D5 default path uses, set up here explicitly"
log "because this test supplies its own REPO_URL (install.sh's own local-seeding branch"
log "never runs when REPO_URL is set)"
GIT_USER="$(id -un)"
HOST_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [ -z "$HOST_IP" ]; then
    echo "FAIL  T-A-topology-b: could not determine a reachable host IP for local git hosting" >&2
    exit 1
fi
BARE_REPO=/tmp/t-a-topology-b-repo.git
DEPLOY_KEY=/tmp/t-a-topology-b-deploy-key
rm -rf "$BARE_REPO" "$DEPLOY_KEY" "$DEPLOY_KEY.pub"
git init --bare -q -b main "$BARE_REPO"
ssh-keygen -t ed25519 -N "" -C "t-a-topology-b" -f "$DEPLOY_KEY" >/dev/null
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
if ! grep -qF "$(cat "$DEPLOY_KEY.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    cat "$DEPLOY_KEY.pub" >> "$HOME/.ssh/authorized_keys"
fi
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
BARE_URL="ssh://${GIT_USER}@${HOST_IP}${BARE_REPO}"

# Commit 1 on main: a full snapshot of THIS checkout -- what scrap-platform
# will be pinned to. Mirrors install.sh's own D5 seeding (find+cp per
# top-level entry, .git excluded -- see that script's own comment for the
# real bug this exact pattern was found fixing).
WORKDIR=$(mktemp -d)
git clone -q "$BARE_REPO" "$WORKDIR"
find "$REPO_ROOT" -mindepth 1 -maxdepth 1 ! -name .git -exec cp -a {} "$WORKDIR/" \;
( cd "$WORKDIR" && git add -A && \
    git -c user.name=t-a-topology-b -c user.email=t-a-topology-b@localhost \
        commit -q -m "T-A-topology-b: upstream snapshot" )
UPSTREAM_SHA=$(git -C "$WORKDIR" rev-parse HEAD)
( cd "$WORKDIR" && git push -q origin main )
rm -rf "$WORKDIR"

# ---------------------------------------------------------------------------
log "T-A-topology-b: Phase 3/7: generate the Topology B operator repository, pinned to $UPSTREAM_SHA"
AGE_KEY_DIR=/tmp/t-a-topology-b-age
rm -rf "$AGE_KEY_DIR"
mkdir -p "$AGE_KEY_DIR"
chmod 700 "$AGE_KEY_DIR"
age-keygen -o "$AGE_KEY_DIR/operational.agekey" 2>/dev/null
age-keygen -o "$AGE_KEY_DIR/escrow.agekey" 2>/dev/null
OP_PUB=$(age-keygen -y "$AGE_KEY_DIR/operational.agekey")
ESCROW_PUB=$(age-keygen -y "$AGE_KEY_DIR/escrow.agekey")

GEN_DIR=/tmp/t-a-topology-b-generated
rm -rf "$GEN_DIR"
UPSTREAM_URL="$BARE_URL" UPSTREAM_REF="$UPSTREAM_SHA" UPSTREAM_SECRET_REF=flux-system \
    OP_AGE_PUB="$OP_PUB" ESCROW_AGE_PUB="$ESCROW_PUB" \
    sh "$REPO_ROOT/bootstrap/generate-topology-b.sh" "$GEN_DIR" "$INSTANCE_NAME"

# 2a. Structural check -- cheap, decisive, needs no cluster: ADR-0009
# requires NO copy of platform/, capabilities/, or components/ in a
# Topology B operator repository at all.
if [ -d "$GEN_DIR/platform" ] || [ -d "$GEN_DIR/capabilities" ] || [ -d "$GEN_DIR/components" ]; then
    fail T-A-topology-b/no-upstream-copy "the generated repository copied platform/, capabilities/, or components/ -- ADR-0009 requires none of these exist in a Topology B operator repository"
else
    ok T-A-topology-b/no-upstream-copy "the generated repository contains no platform/, capabilities/, or components/ -- only clusters/$INSTANCE_NAME/ and apps/"
fi

# 2b. Structural check -- the one mechanical diff ADR-0009 documents
# genuinely happened, per file, not just "some files changed".
STRUCT_OK=1
for f in platform-crds.yaml platform-cert-manager.yaml platform-cert-manager-config.yaml \
         platform-ingress.yaml platform-observability.yaml platform-observability-config.yaml \
         platform-backup.yaml; do
    if ! grep -q '^    name: scrap-platform$' "$GEN_DIR/clusters/$INSTANCE_NAME/$f"; then
        fail T-A-topology-b/sourceref-swapped "$f still references flux-system, not scrap-platform"
        STRUCT_OK=0
    fi
done
if ! grep -q '^    name: flux-system$' "$GEN_DIR/clusters/$INSTANCE_NAME/platform-secrets.yaml"; then
    fail T-A-topology-b/instance-pointer-unswapped "platform-secrets.yaml's sourceRef should stay flux-system -- it targets this repository's own secrets/, not the pinned upstream"
    STRUCT_OK=0
fi
if [ "$STRUCT_OK" -eq 1 ]; then
    ok T-A-topology-b/sourceref-swapped "every platform-tier Kustomization points at scrap-platform; the instance-specific platform-secrets.yaml correctly stays on flux-system"
fi

# ---------------------------------------------------------------------------
log "T-A-topology-b: Phase 4/7: commit 2 on main -- the generated repo becomes flux-system's tip"
WORKDIR2=$(mktemp -d)
git clone -q "$BARE_REPO" "$WORKDIR2"
find "$WORKDIR2" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} \;
find "$GEN_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec cp -a {} "$WORKDIR2/" \;
( cd "$WORKDIR2" && git add -A && \
    git -c user.name=t-a-topology-b -c user.email=t-a-topology-b@localhost \
        commit -q -m "T-A-topology-b: generated Topology B operator repo" && \
    git push -q origin main )
rm -rf "$WORKDIR2" "$GEN_DIR"

# ---------------------------------------------------------------------------
log "T-A-topology-b: Phase 5/7: bootstrap/install.sh -- the real, unmodified installer, against the generated repo"
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E env HOME=/root AGE_KEY_DIR="$AGE_KEY_DIR" FLUX_PRIVATE_KEY_FILE="$DEPLOY_KEY" \
    REPO_URL="$BARE_URL" CLUSTER_PATH="./clusters/$INSTANCE_NAME" sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A-topology-b: bootstrap/install.sh exited non-zero -- see the 'Step N/7'"
    echo "      marker above for which layer of the documented bootstrap sequence failed."
    exit 1
fi

setup_kubeconfig

# ---------------------------------------------------------------------------
log "T-A-topology-b: Phase 6/7: postconditions"

echo "      --- flux get kustomizations -A ---"
flux get kustomizations -A 2>&1 | sed 's/^/      /' || true

not_ready=$(kc get kustomizations -A -o json | jq -r '
    .items[] |
    (.status.conditions // [] | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
    select($ready != "True") |
    "\(.metadata.namespace)/\(.metadata.name) (ready=\($ready))"
')
if [ -z "$not_ready" ]; then
    ok T-A-topology-b/kustomizations-ready "every Flux Kustomization is Ready"
else
    fail T-A-topology-b/kustomizations-ready "not Ready: $not_ready"
fi

# 5a. Not just "Ready" -- the LIVE object genuinely resolves via
# scrap-platform, not flux-system. This is the actual structural claim
# Topology B makes; a Kustomization can report Ready against the wrong
# source if both happen to contain compatible content.
live_sourceref=$(kc get kustomization platform-crds -n flux-system -o jsonpath='{.spec.sourceRef.name}' 2>/dev/null || true)
if [ "$live_sourceref" = "scrap-platform" ]; then
    ok T-A-topology-b/live-sourceref-swapped "the live platform-crds Kustomization genuinely resolves via scrap-platform, not flux-system"
else
    fail T-A-topology-b/live-sourceref-swapped "expected platform-crds sourceRef.name=scrap-platform, got '$live_sourceref'"
fi

# 5b. scrap-platform itself is Ready AND resolved the EXACT pinned commit --
# not merely "some" revision.
sp_ready=$(kc get gitrepository scrap-platform -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
sp_revision=$(kc get gitrepository scrap-platform -n flux-system -o jsonpath='{.status.artifact.revision}' 2>/dev/null || true)
case "$sp_revision" in
    *"$UPSTREAM_SHA"*) revision_ok=1 ;;
    *) revision_ok=0 ;;
esac
if [ "$sp_ready" = "True" ] && [ "$revision_ok" -eq 1 ]; then
    ok T-A-topology-b/scrap-platform-pinned "the scrap-platform GitRepository is Ready and resolved the exact pinned commit ($UPSTREAM_SHA)"
else
    fail T-A-topology-b/scrap-platform-pinned "expected Ready=True and a revision containing $UPSTREAM_SHA; got Ready='$sp_ready' revision='$sp_revision'"
fi

# 5c. Behavioral, not just structural: real platform/cert-manager-config
# content, sourced entirely from scrap-platform, genuinely reconciled --
# the wildcard Certificate issues.
cert_issuer=$(kc get certificate -n traefik scrap-wildcard -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)
cert_ready=$(kc get certificate -n traefik scrap-wildcard -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$cert_issuer" = "scrap-ca" ] && [ "$cert_ready" = "True" ]; then
    ok T-A-topology-b/platform-actually-works "platform/cert-manager-config content sourced entirely from the pinned upstream genuinely reconciled -- the wildcard Certificate issued via scrap-ca"
else
    fail T-A-topology-b/platform-actually-works "expected the wildcard Certificate issuerRef=scrap-ca, Ready=True; got issuerRef='$cert_issuer' Ready='$cert_ready'"
fi

# ---------------------------------------------------------------------------
log "T-A-topology-b: Phase 7/7: negative control -- a deliberately wrong pinned commit fails visibly"
BOGUS_SHA=0000000000000000000000000000000000dead
WORKDIR3=$(mktemp -d)
git clone -q "$BARE_REPO" "$WORKDIR3"
sed -i "s|commit: $UPSTREAM_SHA|commit: $BOGUS_SHA|" "$WORKDIR3/clusters/$INSTANCE_NAME/scrap-platform-source.yaml"
( cd "$WORKDIR3" && git add -A && \
    git -c user.name=t-a-topology-b -c user.email=t-a-topology-b@localhost \
        commit -q -m "T-A-topology-b: negative control -- bogus scrap-platform pin" && \
    git push -q origin main )
rm -rf "$WORKDIR3"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null 2>&1 || true
flux reconcile source git scrap-platform >/dev/null 2>&1 || true

fail_seen=""
i=0
while [ "$i" -lt 24 ]; do
    r=$(kc get gitrepository scrap-platform -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "$r" = "False" ]; then
        fail_seen=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
bad_reason=$(kc get gitrepository scrap-platform -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
echo "      --- scrap-platform GitRepository after the bogus pin ---"
kc describe gitrepository scrap-platform -n flux-system 2>&1 | sed 's/^/      /' || true
if [ "$fail_seen" = 1 ]; then
    ok T-A-topology-b/pin-fails-visibly "a deliberately wrong scrap-platform commit pin fails visibly (Ready=False, reason='$bad_reason') -- the pin genuinely matters, not silently ignored"
else
    fail T-A-topology-b/pin-fails-visibly "expected scrap-platform Ready=False within 2 minutes of a bogus commit pin; it never went False"
fi

# Revert, and confirm recovery.
WORKDIR4=$(mktemp -d)
git clone -q "$BARE_REPO" "$WORKDIR4"
sed -i "s|commit: $BOGUS_SHA|commit: $UPSTREAM_SHA|" "$WORKDIR4/clusters/$INSTANCE_NAME/scrap-platform-source.yaml"
( cd "$WORKDIR4" && git add -A && \
    git -c user.name=t-a-topology-b -c user.email=t-a-topology-b@localhost \
        commit -q -m "T-A-topology-b: revert to the real pinned commit" && \
    git push -q origin main )
rm -rf "$WORKDIR4"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null 2>&1 || true
flux reconcile source git scrap-platform >/dev/null 2>&1 || true

reverted=""
i=0
while [ "$i" -lt 24 ]; do
    r=$(kc get gitrepository scrap-platform -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "$r" = "True" ]; then
        reverted=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$reverted" = 1 ]; then
    ok T-A-topology-b/reverts-cleanly "reverting to the real pinned commit brought scrap-platform back to Ready=True"
else
    fail T-A-topology-b/reverts-cleanly "scrap-platform never recovered to Ready=True after reverting the pin"
fi

# ---------------------------------------------------------------------------
log "T-A-topology-b: result"
if [ "$status" -ne 0 ]; then
    echo "T-A-topology-b FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A-topology-b PASSED -- a generated Topology B operator repository genuinely bootstraps and"
echo "reconciles from a separately pinned scrap-platform source, the pin itself fails visibly when"
echo "wrong, and recovers cleanly when corrected."
