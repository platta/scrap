#!/bin/sh
# T-A-offsite-backup -- live acceptance for capabilities/offsite-backup/.
# See that directory's own README, "What this claim is, precisely -- and
# what it is not" section, before reading this script: the claim proven
# here is that SCRAP can place the frozen contract's required recovery
# artifacts into storage whose failure domain is independent of the
# SCRAP host, using restic's own supported S3 backend -- NOT that a
# blank machine can be recovered from those artifacts. That is T-E
# (host-loss rehearsal), not yet implemented, and nothing in this script
# claims otherwise.
#
# Same expectations as tests/profiles/t-a-minimal.sh: a normal user,
# passwordless sudo, a genuinely fresh host, never run this whole script
# under `sudo` itself. A SEPARATE from-zero bootstrap from T-A's own,
# same reasoning as T-B's and T-A-public-tls's -- this live-edits a
# SOPS-encrypted secret and deliberately provokes a backup failure; it
# must never run against a cluster some other check still depends on.
#
# The S3-compatible target is a REAL, ephemeral MinIO instance this
# script stands up itself on the same runner -- the actual S3 wire
# protocol, not a mock or a SCRAP-specific stand-in. A human can run
# this identically on their own scratch VM, given `minio`/`mc` on PATH
# (or let Phase 1 below fetch them):
#   sh tests/profiles/t-a-offsite-backup.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

status=0

# Deliberately fake, project convention (see clusters/example/secrets/
# PUBLISHED-NOT-SECRET-reference.agekey's own comment for the same
# pattern): this credential protects nothing but a throwaway bucket on a
# throwaway MinIO instance that stops existing the moment this job ends.
MINIO_ROOT_USER="scrap-test-minio-user"
MINIO_ROOT_PASSWORD="scrap-test-minio-password-not-secret-16ch"
MINIO_BUCKET="scrap-offsite-test"
# REAL BUG, found live via this script's own first run: 9000, MinIO's own
# documented default, collides with platform/ingress/reserved-ports.yaml's
# own entry for THIS SAME PORT NUMBER (P4's raw-TCP demo,
# docs/patterns/README.md#p4) -- preflight's check-ports.sh correctly
# failed the whole bootstrap ("TCP port 9000 is already in use") because
# THIS script's own MinIO, started in Phase 1 before bootstrap runs, was
# already bound to it. Not a SCRAP defect -- a genuine port collision in
# this script's own choice of port, caught by the exact mechanism
# reserved-ports.yaml exists to catch. 19000 is well outside SCRAP's own
# reserved range (80/443/6443/9000) and isn't a host port SCRAP claims
# anywhere, so it needs no entry of its own there.
MINIO_PORT=19000

# ---------------------------------------------------------------------------
log "T-A-offsite-backup: Phase 0/5: environment prerequisites"
install_prereqs

# ---------------------------------------------------------------------------
log "T-A-offsite-backup: Phase 1/5: an ephemeral, real S3-compatible target (MinIO)"
# Real MinIO server + client binaries, not a mock -- genuinely exercises
# restic's own S3 backend code path and the real S3 wire protocol.
# Bounded downloads (--max-time), matching install_prereqs()'s own
# reliability discipline -- no arbitrary hang if dl.min.io is slow.
if ! command -v minio >/dev/null 2>&1; then
    sudo curl -sSL --connect-timeout 15 --max-time 120 \
        https://dl.min.io/server/minio/release/linux-amd64/minio -o /usr/local/bin/minio
    sudo chmod +x /usr/local/bin/minio
fi
if ! command -v mc >/dev/null 2>&1; then
    sudo curl -sSL --connect-timeout 15 --max-time 120 \
        https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
    sudo chmod +x /usr/local/bin/mc
fi

MINIO_DATA_DIR=$(mktemp -d)
MINIO_ADDR="http://127.0.0.1:${MINIO_PORT}"
MINIO_ROOT_USER="$MINIO_ROOT_USER" MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
    nohup minio server "$MINIO_DATA_DIR" --address ":${MINIO_PORT}" >/tmp/t-a-offsite-minio.log 2>&1 &
MINIO_PID=$!

minio_up=""
i=0
while [ "$i" -lt 30 ]; do
    if curl -sf --max-time 3 "${MINIO_ADDR}/minio/health/live" >/dev/null 2>&1; then
        minio_up=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ -z "$minio_up" ]; then
    echo "FAIL  T-A-offsite-backup: MinIO never came up -- see /tmp/t-a-offsite-minio.log"
    cat /tmp/t-a-offsite-minio.log 2>/dev/null || true
    exit 1
fi

mc alias set localminio "$MINIO_ADDR" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb "localminio/${MINIO_BUCKET}" >/dev/null
echo "MinIO up (pid $MINIO_PID), bucket ${MINIO_BUCKET} created."

# ---------------------------------------------------------------------------
log "T-A-offsite-backup: Phase 2/5: bootstrap/install.sh -- the real, unmodified installer"
# Identical invocation to T-A/T-B/T-A-public-tls/the DR rehearsal -- see
# any of their own comments at this exact call for the HOME=/root
# investigation.
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A-offsite-backup: bootstrap/install.sh exited non-zero -- see the"
    echo "      'Step N/7' marker above for which layer of the documented bootstrap"
    echo "      sequence failed."
    exit 1
fi

setup_kubeconfig

not_ready=$(kc get kustomizations -A --no-header 2>/dev/null | awk -F'\t' '{gsub(/ /,"",$5); if ($5!="True") print $2}')
if [ -z "$not_ready" ]; then
    ok T-A-offsite-backup/kustomizations-ready "every Flux Kustomization is Ready"
else
    fail T-A-offsite-backup/kustomizations-ready "not Ready: $not_ready"
fi

NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
# The pod-to-host reachability mechanism this whole script depends on --
# already proven live and repeatedly by every other profile script that
# reaches a runner-hosted target from inside the cluster (P6's own
# external backend in t-a-minimal.sh; this is the exact same pattern,
# reused for a real S3-compatible target instead of a plain HTTP one).
MINIO_S3_URL="s3:http://${NODE_IP}:${MINIO_PORT}/${MINIO_BUCKET}"

# ---------------------------------------------------------------------------
log "T-A-offsite-backup: Phase 3/5: baseline -- BACKUP_DESTINATION defaults to local, unaffected by this capability's existence"
baseline_dest=$(kc get cronjob -n scrap-backup scrap-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="RESTIC_REPOSITORY")].value}' 2>/dev/null || true)
if [ "$baseline_dest" = "local:/var/lib/scrap-backup" ]; then
    ok T-A-offsite-backup/baseline-local "the backup CronJob's RESTIC_REPOSITORY is genuinely the local default before this capability is enabled"
else
    fail T-A-offsite-backup/baseline-local "expected RESTIC_REPOSITORY=local:/var/lib/scrap-backup, got '$baseline_dest'"
fi
# T-A itself already proves the local destination fully, end to end
# (backup + destructive restore of P5's Redis, verified by a specific
# recently-changed value) -- not repeated here to keep this script
# scoped to what's actually new: the off-site destination.

# ---------------------------------------------------------------------------
log "T-A-offsite-backup: Phase 4/5: enable off-site backup live -- exactly the documented two-edit path"
# Live-edits the ALREADY-BOOTSTRAPPED cluster's own git source, same
# mechanism as tests/profiles/t-a-public-tls.sh's own Phase 3 -- see its
# comment at the identical git-clone step for why this targets the bare
# repo, not this checkout.
BARE_REPO=/var/lib/scrap/repo.git
LIVEDIR=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR"
LIVE_CLUSTER_DIR="$LIVEDIR/clusters/example"

sed -i "s|^\(  BACKUP_DESTINATION: \).*|\1\"${MINIO_S3_URL}\"|" "$LIVE_CLUSTER_DIR/instance-config.yaml"

# capabilities/offsite-backup/README.md's own "Enabling this capability":
# no Kustomization file, just these two keys added to the SAME secret
# platform/backup/ already owns. Edited with the instance's OWN fresh
# operational age key (install.sh's Step 4, root-only, 600) -- not the
# reference key, which install.sh already re-encrypted away from during
# Phase 2 above. Root-only, hence sudo; a temp script file, not an
# inline sudo sh -c string, to avoid a nested-quoting hazard around the
# credential values.
EDIT_SCRIPT=$(mktemp)
cat > "$EDIT_SCRIPT" <<EOF
set -eu
cd '$LIVE_CLUSTER_DIR/secrets'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops --set '["stringData"]["AWS_ACCESS_KEY_ID"] "$MINIO_ROOT_USER"' restic-credentials.sops.yaml
sops --set '["stringData"]["AWS_SECRET_ACCESS_KEY"] "$MINIO_ROOT_PASSWORD"' restic-credentials.sops.yaml
EOF
if ! sudo sh "$EDIT_SCRIPT"; then
    echo "FAIL  T-A-offsite-backup: could not add the S3 credential keys to restic-credentials.sops.yaml"
    rm -f "$EDIT_SCRIPT"
    exit 1
fi
rm -f "$EDIT_SCRIPT"

( cd "$LIVEDIR" && git add -A && git -c user.email=t-a-offsite-backup@localhost -c user.name="T-A-offsite-backup" \
    commit -q -m "T-A-offsite-backup: enable off-site backup against the ephemeral MinIO target" && \
    git push -q origin main )
rm -rf "$LIVEDIR"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization platform-backup --with-source >/dev/null 2>&1 || true
flux reconcile kustomization platform-secrets --with-source >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "T-A-offsite-backup: Phase 5/5: postconditions"

# 5a. The live-edited env actually took -- ground truth on the CronJob
# object itself, before trusting a Job run to prove anything downstream.
new_dest=$(kc get cronjob -n scrap-backup scrap-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="RESTIC_REPOSITORY")].value}' 2>/dev/null || true)
if [ "$new_dest" = "$MINIO_S3_URL" ]; then
    ok T-A-offsite-backup/destination-swapped "RESTIC_REPOSITORY genuinely resolved to the S3 URL after the instance-config edit"
else
    fail T-A-offsite-backup/destination-swapped "expected RESTIC_REPOSITORY='$MINIO_S3_URL', got '$new_dest'"
fi

# 5b. A real backup run against the S3 destination succeeds.
BACKUP_JOB="t-a-offsite-backup-$(date +%s)"
kc create job -n scrap-backup "$BACKUP_JOB" --from=cronjob/scrap-backup >/dev/null
backup_result=$(wait_for_job scrap-backup "$BACKUP_JOB" 24)
echo "      --- backup job log ---"
kc logs -n scrap-backup "job/$BACKUP_JOB" 2>&1 | sed 's/^/      /' || true
if [ "$backup_result" = ok ]; then
    ok T-A-offsite-backup/backup-runs "a real backup run against the S3 destination completed successfully"
else
    fail T-A-offsite-backup/backup-runs "backup job against the S3 destination did not succeed -- see the log above"
fi

# 5c. Actual remote write, independently observed -- NOT through restic
# or through the cluster at all: `mc ls` reading MinIO's own object
# listing directly, from this runner. This is the difference between
# "the job exited 0" and "data genuinely left the host" -- a bug that
# silently no-op'd the S3 write (e.g. a client that authenticated but
# never actually PUT anything) would still pass 5b but fail this.
remote_objects=$(mc ls --recursive "localminio/${MINIO_BUCKET}" 2>/dev/null | wc -l | tr -d ' ')
if [ "${remote_objects:-0}" -gt 0 ]; then
    ok T-A-offsite-backup/remote-write-verified "MinIO's own object listing shows $remote_objects real object(s) written to the bucket -- independently observed, not inferred from job exit status"
else
    fail T-A-offsite-backup/remote-write-verified "the backup job reported success but MinIO's own bucket listing is empty -- no data actually left the host"
fi

# 5d. Independent read: a SEPARATE restic client -- not the one inside
# the cluster, not the one the backup job just used -- run directly on
# THIS runner against the S3 repository, using the intended recovery
# credentials, lists a real snapshot. Proves the repository is genuinely
# usable for recovery by any restic client with the right credentials,
# not merely writable by the one pod that just wrote to it.
if ! command -v restic >/dev/null 2>&1; then
    sudo curl -sSL --connect-timeout 15 --max-time 120 \
        https://github.com/restic/restic/releases/download/v0.19.1/restic_0.19.1_linux_amd64.bz2 \
        -o /tmp/restic.bz2
    bunzip2 -f /tmp/restic.bz2
    chmod +x /tmp/restic
    sudo mv /tmp/restic /usr/local/bin/restic
fi
INSTANCE_NAME=$(cfg_value INSTANCE_NAME)
RESTIC_PASSWORD=$(cd "$REPO_ROOT/clusters/example/secrets" && \
    SOPS_AGE_KEY_FILE=PUBLISHED-NOT-SECRET-reference.agekey \
    sops -d --extract '["stringData"]["RESTIC_PASSWORD"]' restic-credentials.sops.yaml)
snapshots_json=$(RESTIC_REPOSITORY="$MINIO_S3_URL" RESTIC_PASSWORD="$RESTIC_PASSWORD" \
    AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER" AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD" \
    restic snapshots --json 2>/tmp/t-a-offsite-restic-snapshots.log || true)
snapshot_count=$(echo "$snapshots_json" | jq 'length' 2>/dev/null || echo 0)
snapshot_host=$(echo "$snapshots_json" | jq -r '.[0].hostname // empty' 2>/dev/null || true)
if [ "${snapshot_count:-0}" -gt 0 ] && [ "$snapshot_host" = "$INSTANCE_NAME" ]; then
    ok T-A-offsite-backup/independent-read "a standalone restic client on this runner, using the intended recovery credentials, independently listed $snapshot_count real snapshot(s) tagged host=$snapshot_host -- the repository is genuinely readable for recovery, and ADR-0010's --host isolation mechanism is unaffected by the S3 destination"
else
    fail T-A-offsite-backup/independent-read "expected at least one snapshot with hostname='$INSTANCE_NAME', got count=$snapshot_count host='$snapshot_host' -- see /tmp/t-a-offsite-restic-snapshots.log"
    cat /tmp/t-a-offsite-restic-snapshots.log 2>/dev/null || true
fi

# 5e. NEGATIVE CONTROL: wrong credential -- prove backup fails VISIBLY
# against the real S3 target, rather than silently succeeding against
# some unintended local fallback (there is no fallback code path in
# discover-and-backup.sh at all -- this proves the absence has the
# effect it should, not just that the code reads that way).
LIVEDIR2=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR2"
EDIT_SCRIPT2=$(mktemp)
cat > "$EDIT_SCRIPT2" <<EOF
set -eu
cd '$LIVEDIR2/clusters/example/secrets'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops --set '["stringData"]["AWS_SECRET_ACCESS_KEY"] "deliberately-wrong-secret-key"' restic-credentials.sops.yaml
EOF
sudo sh "$EDIT_SCRIPT2"
rm -f "$EDIT_SCRIPT2"
( cd "$LIVEDIR2" && git add -A && git -c user.email=t-a-offsite-backup@localhost -c user.name="T-A-offsite-backup" \
    commit -q -m "T-A-offsite-backup: NEGATIVE CONTROL -- deliberately wrong AWS_SECRET_ACCESS_KEY" && \
    git push -q origin main )
rm -rf "$LIVEDIR2"
flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization platform-secrets --with-source >/dev/null 2>&1 || true
# Secret changes don't restart an already-running pod, but this is a
# fresh Job's fresh pod each time -- it reads the current Secret value
# at start, no propagation delay to wait out.

remote_objects_before=$remote_objects
FAIL_JOB="t-a-offsite-backup-neg-$(date +%s)"
kc create job -n scrap-backup "$FAIL_JOB" --from=cronjob/scrap-backup >/dev/null
neg_result=$(wait_for_job scrap-backup "$FAIL_JOB" 24)
echo "      --- negative-control job log (deliberately wrong credential) ---"
kc logs -n scrap-backup "job/$FAIL_JOB" 2>&1 | sed 's/^/      /' || true
remote_objects_after=$(mc ls --recursive "localminio/${MINIO_BUCKET}" 2>/dev/null | wc -l | tr -d ' ')
if [ "$neg_result" = fail ] && [ "${remote_objects_after:-0}" -eq "${remote_objects_before:-0}" ]; then
    ok T-A-offsite-backup/adversarial-bad-credential "a backup job with a deliberately wrong AWS_SECRET_ACCESS_KEY genuinely FAILED (job status Failed, not a timeout) with no new objects written -- no silent success, no silent fallback"
else
    fail T-A-offsite-backup/adversarial-bad-credential "expected the job to fail with the remote object count unchanged; got result='$neg_result', objects before=$remote_objects_before after=$remote_objects_after"
fi

# Revert the credential (same mechanism, correct value) before the final
# revert below re-establishes the local destination -- otherwise a
# subsequent local-destination run would still carry the broken key.
LIVEDIR3=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR3"
EDIT_SCRIPT3=$(mktemp)
cat > "$EDIT_SCRIPT3" <<EOF
set -eu
cd '$LIVEDIR3/clusters/example/secrets'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops --set '["stringData"]["AWS_SECRET_ACCESS_KEY"] "$MINIO_ROOT_PASSWORD"' restic-credentials.sops.yaml
EOF
sudo sh "$EDIT_SCRIPT3"
rm -f "$EDIT_SCRIPT3"

# 5f. Revert BACKUP_DESTINATION back to local, confirm recovery.
sed -i 's|^\(  BACKUP_DESTINATION: \).*|\1"local:/var/lib/scrap-backup"|' "$LIVEDIR3/clusters/example/instance-config.yaml"
( cd "$LIVEDIR3" && git add -A && git -c user.email=t-a-offsite-backup@localhost -c user.name="T-A-offsite-backup" \
    commit -q -m "T-A-offsite-backup: revert BACKUP_DESTINATION to local, revert AWS_SECRET_ACCESS_KEY" && \
    git push -q origin main )
rm -rf "$LIVEDIR3"
flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization platform-secrets --with-source >/dev/null 2>&1 || true

reverted_dest=$(kc get cronjob -n scrap-backup scrap-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="RESTIC_REPOSITORY")].value}' 2>/dev/null || true)
if [ "$reverted_dest" = "local:/var/lib/scrap-backup" ]; then
    ok T-A-offsite-backup/reverts-cleanly "reverting BACKUP_DESTINATION brought RESTIC_REPOSITORY back to the local default"
else
    fail T-A-offsite-backup/reverts-cleanly "expected RESTIC_REPOSITORY back to local:/var/lib/scrap-backup, got '$reverted_dest'"
fi

kill "$MINIO_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
log "T-A-offsite-backup: result"
if [ "$status" -ne 0 ]; then
    echo "T-A-offsite-backup FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A-offsite-backup PASSED -- backup data genuinely written through the real S3 protocol, independently readable using the intended recovery credentials, ADR-0010's --host isolation unaffected, a bad credential fails visibly with no silent fallback, and a clean revert -- all verified live. This proves recovery artifacts CAN be placed off-host; it does not prove host-loss recovery (R3) -- see capabilities/offsite-backup/README.md."
