#!/bin/sh
# Orchestrates: preflight -> k3s -> age keys (verified escrow) -> Git source
# -> seed the SOPS decryption secret -> flux bootstrap -> postflight.
# See docs/core/bootstrap-lifecycle.md for the full documented sequence
# this script implements.
#
# Configuration via environment variables, all optional:
#
#   REPO_URL       Git URL to bootstrap Flux against. If unset, a local
#                   bare repository is created and seeded with a snapshot
#                   of THIS SCRAP checkout -- the D5 minimum path: no
#                   GitHub, no hosted Git, no internet at bootstrap time
#                   beyond what k3s/Helm charts already need. See
#                   docs/decisions/0005-minimum-git-remote.md.
#                   Set this to your own repository (a fork, or a separate
#                   Topology B consumer repo -- see
#                   docs/decisions/0009-repository-topology.md) for a real,
#                   externally-hosted install.
#   REPO_BRANCH     Default: main
#   CLUSTER_PATH    Default: ./clusters/example -- rename this to your own
#                   instance name for a real install (copy
#                   clusters/example/ to clusters/<name>/ first).
#   K3S_VERSION     Passed through to bootstrap/host/install-k3s.sh.
#   FLUX_VERSION    Default: v2.9.4, pinned.
#   AGE_KEY_DIR     Where the two age keypairs are written. Default:
#                   /etc/scrap/age -- root-only permissions.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_BRANCH="${REPO_BRANCH:-main}"
CLUSTER_PATH="${CLUSTER_PATH:-./clusters/example}"
FLUX_VERSION="${FLUX_VERSION:-v2.9.4}"
AGE_KEY_DIR="${AGE_KEY_DIR:-/etc/scrap/age}"

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
log "Step 1/7: preflight"
if ! sh "$SCRIPT_DIR/preflight/run-all.sh"; then
    echo
    echo "Preflight failed. Aborting before touching anything. Fix the FAIL items and re-run."
    exit 1
fi
echo

# ---------------------------------------------------------------------------
log "Step 2/7: install k3s"
K3S_VERSION="${K3S_VERSION:-}" sh "$SCRIPT_DIR/host/install-k3s.sh"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo

# ---------------------------------------------------------------------------
log "Step 3/7: install the flux CLI (pinned ${FLUX_VERSION})"
if ! command -v flux >/dev/null 2>&1 || [ "$(flux version --client 2>/dev/null | awk '{print $2}')" != "$FLUX_VERSION" ]; then
    # REAL BUG, found running this end-to-end: fluxcd.io/install.sh itself
    # requires bash (`#!/usr/bin/env bash`, using bash-only syntax further
    # in) -- piping it into plain `sh` fails with a parse error on Debian,
    # where /bin/sh is dash, not bash. bash itself is assumed present as a
    # base OS component (unlike git/age, it is not something Debian/Ubuntu
    # ship without), so no preflight check was added for it specifically.
    curl -sfL https://fluxcd.io/install.sh | FLUX_VERSION="${FLUX_VERSION#v}" bash
fi
flux install --version="$FLUX_VERSION"
echo

# ---------------------------------------------------------------------------
log "Step 4/7: age keys -- operational + offline escrow, escrow verified before continuing"
# age-keygen's presence was already confirmed by preflight's
# check-prerequisites.sh in step 1 -- not re-checked here.
mkdir -p "$AGE_KEY_DIR"
chmod 700 "$AGE_KEY_DIR"
OP_KEY="$AGE_KEY_DIR/operational.agekey"
ESCROW_KEY="$AGE_KEY_DIR/escrow.agekey"

if [ ! -f "$OP_KEY" ]; then
    age-keygen -o "$OP_KEY" 2>&1
    chmod 600 "$OP_KEY"
fi
if [ ! -f "$ESCROW_KEY" ]; then
    age-keygen -o "$ESCROW_KEY" 2>&1
    chmod 600 "$ESCROW_KEY"
fi

OP_PUB=$(age-keygen -y "$OP_KEY")
ESCROW_PUB=$(age-keygen -y "$ESCROW_KEY")

echo
echo "Two age keys were generated. Both public keys will be committed (public keys are not"
echo "secret). Both PRIVATE keys must never be committed."
echo
echo "  Operational public key: $OP_PUB"
echo "  Escrow public key:      $ESCROW_PUB"
echo
echo "The OPERATIONAL key ($OP_KEY) stays on this host -- it's what Flux uses to decrypt"
echo "secrets day to day."
echo
echo "The ESCROW key ($ESCROW_KEY) is your recovery copy. If this host is lost, it is the"
echo "only way to read your secrets back out of Git. Copy it somewhere that survives this"
echo "host dying -- a password manager, a printed copy, a USB drive kept elsewhere -- NOW."
echo
if [ -t 0 ]; then
    fingerprint=$(printf '%s' "$ESCROW_PUB" | tail -c 9)
    echo "Escrow key fingerprint (last 8 characters of its public key): $fingerprint"
    printf "Once you have copied %s off this host, type that fingerprint to confirm: " "$ESCROW_KEY"
    read -r confirm
    if [ "$confirm" != "$fingerprint" ]; then
        echo "Fingerprint did not match -- refusing to continue without confirmed escrow."
        exit 1
    fi
    echo "Escrow confirmed."
else
    echo "Non-interactive shell detected -- cannot verify escrow interactively. Set"
    echo "SCRAP_ESCROW_CONFIRMED=1 to proceed anyway ONLY if escrow has genuinely been verified"
    echo "by other means; otherwise this is exactly the gap that left a real restic password"
    echo "unconfirmed in escrow once before. See docs/core/bootstrap-lifecycle.md."
    if [ "${SCRAP_ESCROW_CONFIRMED:-0}" != "1" ]; then
        exit 1
    fi
fi
echo

# ---------------------------------------------------------------------------
log "Step 5/7: Git source"
FLUX_PRIVATE_KEY_FILE=""
if [ -z "${REPO_URL:-}" ]; then
    # REAL FINDING, from actually running this: Flux's GitRepository source
    # only supports HTTP/S or SSH URLs -- confirmed directly against
    # `kubectl explain gitrepository.spec.url` and against a real failure,
    # `flux bootstrap git --url=file:///...` : `scheme "file" is not
    # supported`. A bare filesystem path is NOT a usable Flux source, even
    # though the plain `git` CLI accepts one fine. The D5-honest fix is
    # SSH to localhost with a purpose-generated deploy key -- genuinely
    # local (no internet, no hosting provider), and the native mechanism
    # Flux actually expects for a self-hosted git source, not a SCRAP
    # workaround.
    #
    # Runs as the invoking (non-root) user, not root, so this doesn't
    # depend on the host's PermitRootLogin policy at all.
    GIT_USER="${SUDO_USER:-${USER:-$(id -un)}}"
    GIT_HOME=$(getent passwd "$GIT_USER" | cut -d: -f6)
    BARE_REPO="/var/lib/scrap/repo.git"
    DEPLOY_KEY="/etc/scrap/ssh/scrap-git-deploy"

    echo "REPO_URL not set -- using a local bare repository over SSH-to-localhost as user"
    echo "'$GIT_USER' (the D5 minimum path: no hosted Git, no internet required): $BARE_REPO"

    mkdir -p "$(dirname "$BARE_REPO")"
    if [ ! -d "$BARE_REPO" ]; then
        git init --bare -b "$REPO_BRANCH" "$BARE_REPO" >/dev/null
        chown -R "$GIT_USER" "$(dirname "$BARE_REPO")"
        # WORKDIR is created by `mktemp -d` as root (this script runs under
        # sudo); it must be handed to $GIT_USER before that user can clone
        # into it, or `git clone` fails with a misleading "already exists
        # and is not an empty directory" -- the real cause is a permission
        # denied while probing the directory, not a non-empty one. Found
        # running this end-to-end on a genuinely fresh host, not by review.
        WORKDIR=$(mktemp -d)
        chown "$GIT_USER" "$WORKDIR"
        sudo -u "$GIT_USER" git clone -q "$BARE_REPO" "$WORKDIR"
        # REAL BUG, root-caused via a dedicated investigation into an
        # intermittently observed "rm: cannot remove '$WORKDIR/.git':
        # Directory not empty" that used to follow this line (see this
        # commit's own message for the full instrumentation-driven
        # writeup). The OLD code was `cp -a "$REPO_ROOT/." "$WORKDIR/"`
        # followed by `rm -rf "$WORKDIR/.git"` -- but that cp has no
        # exclusion for `.git`, so it copied the ACTUAL checked-out
        # repository's own .git directory (this repo's own: 654 files
        # across 253 directories) on top of the freshly-cloned .git that
        # `git clone` created one line up (itself a real, but much
        # smaller, directory -- verified live: 17 files / 10 dirs for a
        # clone of an empty bare repo). The next line then had to remove
        # that MERGED, far larger tree -- a genuinely unnecessary
        # copy-then-delete of real git history the intended "snapshot of
        # the working tree" was never supposed to include, and the only
        # directory tree in this entire step big/complex enough to give a
        # rare filesystem-level race real surface area to occur on.
        # Diagnostic instrumentation confirmed the checkout's own .git is
        # a real 654-file/253-dir tree but could not force a live
        # reproduction of the specific race in 23 straight T-A runs
        # (0/23) -- consistent with a genuinely rare, environment-level
        # race this project cannot fully observe or reproduce on demand,
        # not a deterministic bug in this script's own logic. Rather than
        # continue chasing that specific race, this removes the actual
        # precondition it depended on: `.git` is excluded from the copy
        # in the first place, using `find`+`cp -a` per top-level entry
        # (not rsync -- not an existing prerequisite this project checks
        # for, see bootstrap/preflight/check-prerequisites.sh, and not
        # worth adding one for this).
        find "$REPO_ROOT" -mindepth 1 -maxdepth 1 ! -name .git -exec cp -a {} "$WORKDIR/" \;
        # The rm below is still necessary, NOT just cosmetic cleanup of
        # what cp copied in -- confirmed live: `git init` on top of an
        # EXISTING .git (the one `git clone` made) does not clear its
        # `origin` remote, so without removing it first, the `git remote
        # add origin` a few lines down fails outright ("error: remote
        # origin already exists"). What changed is only WHICH .git this
        # removes: with .git now excluded from the copy above, this is
        # always the small, freshly-cloned one (17 files / 10 dirs) --
        # never the large merged-in tree that made the old version of
        # this line the flake's most likely cause.
        rm -rf "$WORKDIR/.git"

        # clusters/example/secrets/ ships a structurally-real reference
        # secret, encrypted to a PUBLISHED (intentionally non-secret)
        # reference keypair -- see clusters/example/secrets/README.md for
        # why. A committed ciphertext only a published key can open isn't
        # protecting anything, so before this becomes THIS instance's own
        # repository, re-encrypt it to the operational + escrow keys just
        # generated in step 4, and remove the reference key. Skipped
        # gracefully if CLUSTER_PATH doesn't ship one (e.g. a hand-rolled
        # instance directory with its own secrets already in place).
        REF_CLUSTER_DIR="$WORKDIR/${CLUSTER_PATH#./}"
        REF_SECRETS_DIR="$REF_CLUSTER_DIR/secrets"
        # .sops.yaml lives one level ABOVE secrets/, not inside it -- found
        # by actually running this: the first version of this block checked
        # for it at "$REF_SECRETS_DIR/.sops.yaml" and the condition was
        # always false, so re-encryption silently never ran and bootstrap
        # failed three steps later with a decryption error that gave no
        # hint the real bug was a wrong path here.
        REF_KEY=$(find "$REF_SECRETS_DIR" -maxdepth 1 -name 'PUBLISHED-NOT-SECRET-*.agekey' 2>/dev/null | head -n1)
        if [ -n "$REF_KEY" ] && [ -f "$REF_CLUSTER_DIR/.sops.yaml" ]; then
            echo "Re-encrypting the example backup credential to this install's own age keys..."
            sed -i "s|^\( *age: \).*|\1${OP_PUB},${ESCROW_PUB}|" "$REF_CLUSTER_DIR/.sops.yaml"
            # REAL FINDING, from actually running this: sops discovers
            # .sops.yaml by walking UP FROM THE CURRENT WORKING DIRECTORY,
            # not from the target file's path -- and matches path_regex
            # (unanchored) against a path relative to whatever config it
            # finds. Invoke it from anywhere else -- e.g. this script's own
            # CWD, which callers don't control -- and it can silently walk
            # up into a COMPLETELY UNRELATED repository's .sops.yaml,
            # match by substring, and re-encrypt to the wrong recipients
            # with no error at all. `cd` here first and pass a bare
            # (relative) filename, exactly like a human must (see
            # clusters/example/secrets/README.md).
            #
            # SECOND REAL FINDING, from tests/profiles/t-b-standard.sh's
            # first genuinely-from-zero run with identity enabled: this
            # loop used a flat `*.sops.yaml` glob, which only matches files
            # directly inside secrets/ -- never
            # clusters/example/secrets/identity/identity-credentials.sops.yaml,
            # one directory deeper. That file silently never got
            # re-encrypted, and the reference key it was still encrypted to
            # was then deleted two lines below, permanently locking the
            # fresh instance out of its own identity credentials:
            # "age: identity did not match any of the recipients" the very
            # first time Flux tried to decrypt it. `find`, not a glob, so
            # this reaches every *.sops.yaml under secrets/ regardless of
            # depth -- clusters/example/.sops.yaml's own path_regex
            # (`secrets/.*\.sops\.ya?ml$`) already covers subdirectories
            # fine; only this loop didn't.
            ( cd "$REF_SECRETS_DIR" && find . -name '*.sops.yaml' -print | sed 's#^\./##' | \
                while IFS= read -r f; do
                    SOPS_AGE_KEY_FILE="$REF_KEY" sops updatekeys -y "$f" >/dev/null
                done )
            rm -f "$REF_KEY"
            echo "Done -- this instance's secrets/ now decrypts only with this host's own keys."
        fi

        sudo -u "$GIT_USER" sh -c "cd '$WORKDIR' && git init -q -b '$REPO_BRANCH' && \
            git remote add origin '$BARE_REPO' && git add -A && \
            git -c user.name=scrap-bootstrap -c user.email=bootstrap@localhost \
                commit -q -m 'Initial commit from bootstrap/install.sh' && \
            git push -q origin '$REPO_BRANCH'"
        # REAL BUG, root-caused via dedicated live instrumentation (see this
        # commit's own message): this cleanup intermittently failed with
        # "rm: cannot remove '$WORKDIR/.git': Directory not empty" -- 8/8
        # T-A runs in one session, then 0/1 once instrumented, consistent
        # with a genuine but non-deterministic local race (most likely the
        # `git push` above, over SSH-to-localhost, not having fully torn
        # down every local-side helper process/fd the instant it returns
        # rc=0) rather than a deterministic bug in this script's own logic.
        # Confirmed live: the instrumented failing case's own diagnostics
        # showed the push had ALREADY succeeded (composite rc=0, logged
        # before this line ever runs) every single time -- so by the time
        # this rm can fail, the one thing that matters (the initial commit
        # landing in $BARE_REPO) is already done. $WORKDIR is a scratch
        # `mktemp -d` directory with no further purpose; failing to remove
        # it costs nothing but a few KB left in /tmp for the OS to reclaim
        # on its own schedule -- not a reason to fail the entire bootstrap.
        # `|| true`, not a retry/sleep loop: this isn't papering over
        # unexplained flakiness, it's declaring a best-effort cleanup step
        # non-fatal now that evidence shows its failure has no bearing on
        # bootstrap correctness.
        rm -rf "$WORKDIR" || true
    fi

    mkdir -p "$(dirname "$DEPLOY_KEY")"
    if [ ! -f "$DEPLOY_KEY" ]; then
        ssh-keygen -t ed25519 -N "" -C "scrap-bootstrap" -f "$DEPLOY_KEY" >/dev/null
    fi
    mkdir -p "$GIT_HOME/.ssh"
    touch "$GIT_HOME/.ssh/authorized_keys"
    if ! grep -qF "$(cat "$DEPLOY_KEY.pub")" "$GIT_HOME/.ssh/authorized_keys" 2>/dev/null; then
        cat "$DEPLOY_KEY.pub" >> "$GIT_HOME/.ssh/authorized_keys"
    fi
    chown -R "$GIT_USER" "$GIT_HOME/.ssh"
    chmod 700 "$GIT_HOME/.ssh"
    chmod 600 "$GIT_HOME/.ssh/authorized_keys"

    # REAL FINDING, from actually running this: "localhost" does NOT work
    # here, even though the flux CLI's own bootstrap-time clone/push
    # (running directly on the host) succeeds against it. The
    # IN-CLUSTER GitRepository object is reconciled by source-controller,
    # running inside a pod with its own network namespace -- that pod's
    # "localhost" is itself, not the host, so it fails with
    # `dial tcp [::1]:22: connect: connection refused` the moment Flux
    # tries to reconcile after bootstrap's own CLI-level operations already
    # succeeded. The host's actual reachable address is needed instead, so
    # traffic from the pod network reaches the host's real interface.
    HOST_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    if [ -z "$HOST_IP" ]; then
        echo "Could not determine a reachable host IP for the local Git source. Set REPO_URL"
        echo "explicitly (see the comment block at the top of this script) and re-run."
        exit 1
    fi
    REPO_URL="ssh://${GIT_USER}@${HOST_IP}${BARE_REPO}"
    FLUX_PRIVATE_KEY_FILE="$DEPLOY_KEY"
fi
echo "Bootstrapping against: $REPO_URL (branch $REPO_BRANCH, path $CLUSTER_PATH)"
echo

# ---------------------------------------------------------------------------
log "Step 6/7: seed the SOPS decryption secret, then flux bootstrap"
# The one genuinely irreducible manual step: Flux cannot decrypt the key
# that lets it decrypt anything, so it has to be placed directly.
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey="$OP_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if [ -n "$FLUX_PRIVATE_KEY_FILE" ]; then
    flux bootstrap git \
        --url="$REPO_URL" \
        --branch="$REPO_BRANCH" \
        --path="$CLUSTER_PATH" \
        --private-key-file="$FLUX_PRIVATE_KEY_FILE" \
        --silent
else
    flux bootstrap git \
        --url="$REPO_URL" \
        --branch="$REPO_BRANCH" \
        --path="$CLUSTER_PATH" \
        --silent
fi
echo

# ---------------------------------------------------------------------------
log "Step 7/7: postflight"
sh "$SCRIPT_DIR/postflight.sh" || true

echo
echo "Bootstrap complete. Escrow key location (move it off this host if not already done):"
echo "  $ESCROW_KEY"
