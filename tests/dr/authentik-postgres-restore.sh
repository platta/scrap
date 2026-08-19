#!/bin/sh
# tests/dr/authentik-postgres-restore.sh -- disaster-recovery acceptance
# test for R1 (application-data loss), using capabilities/identity/'s own
# Authentik + PostgreSQL as the workload. See tests/dr/README.md and
# docs/core/recovery-model.md for the recovery contract this exists to
# prove, and docs/runbooks/README.md for the manual procedure this
# automates -- specifically its multi-tier restore of identity's Postgres,
# the only place this project had ever proven multi-tier quiescence
# ordering, a real logical-dump consistency method, and stable-identifier
# (database primary key) preservation, all manually and all at once.
#
# Chosen over apps/examples/p5-stateful-backup/'s Redis (already covered
# by tests/profiles/t-a-minimal.sh) specifically BECAUSE identity is the
# one shipped workload with more than one tier talking to its own
# database -- p5 has no such tier and can't exercise this claim at all.
#
# Same expectations as tests/profiles/t-a-minimal.sh and t-b-standard.sh:
# a normal user, passwordless sudo, a genuinely fresh host, never run this
# whole script under `sudo` itself. A SEPARATE from-zero bootstrap, same
# reasoning as T-B's own -- this genuinely destroys and reloads a
# database; it must never run against a cluster some other check still
# depends on.
#
# A human can run this identically on their own scratch VM:
#   sh tests/dr/authentik-postgres-restore.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$REPO_ROOT/tests/profiles/lib.sh"

BASE_DOMAIN=$(cfg_value BASE_DOMAIN)
INSTANCE_NAME=$(cfg_value INSTANCE_NAME)
status=0

# ---------------------------------------------------------------------------
log "DR/authentik-postgres: Phase 0/5: environment prerequisites"
install_prereqs

# The checked-in reference instance's identity bootstrap credentials --
# same mechanism as tests/profiles/t-b-standard.sh, see its own comment at
# this exact call for why this is read from ciphertext rather than
# hardcoded. Both the akadmin password (not used here -- no browser login
# in this script) and the API bootstrap token (used here, directly, as a
# Bearer credential) live in the same secret.
AUTHENTIK_TOKEN=$(cd "$REPO_ROOT/clusters/example/secrets/identity" && \
    SOPS_AGE_KEY_FILE=../PUBLISHED-NOT-SECRET-reference.agekey \
    sops -d --extract '["stringData"]["AUTHENTIK_BOOTSTRAP_TOKEN"]' identity-credentials.sops.yaml)
if [ -z "$AUTHENTIK_TOKEN" ]; then
    echo "FAIL  DR/authentik-postgres: could not decrypt the reference AUTHENTIK_BOOTSTRAP_TOKEN"
    echo "      -- see clusters/example/secrets/README.md. Nothing bootstrapped yet; exiting."
    exit 1
fi

# ---------------------------------------------------------------------------
log "DR/authentik-postgres: Phase 1/5: enable identity -- exactly the documented path"
# capabilities/identity/README.md's own "Enabling this capability" --
# only the two files identity itself needs, not the optional third
# (apps/examples/identity/cluster-kustomization.yaml). This test doesn't
# use P2/P3's demo apps at all; bootstrapping them would only add cost
# without adding coverage this script exercises.
mkdir -p "$REPO_ROOT/clusters/example/capabilities"
cp "$REPO_ROOT/capabilities/identity/cluster-kustomization.yaml" \
    "$REPO_ROOT/clusters/example/capabilities/identity.yaml"
cp "$REPO_ROOT/capabilities/identity/cluster-secrets-kustomization.yaml" \
    "$REPO_ROOT/clusters/example/capabilities/identity-secrets.yaml"

NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

# ---------------------------------------------------------------------------
log "DR/authentik-postgres: Phase 2/5: bootstrap/install.sh -- the real, unmodified installer"
# Identical invocation to T-A/T-B, including the HOME=/root fix -- see
# either script's own comment at this exact call for the investigation
# that found it necessary.
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  DR/authentik-postgres: bootstrap/install.sh exited non-zero -- see the"
    echo "      'Step N/7' marker above for which layer of the documented bootstrap"
    echo "      sequence failed."
    exit 1
fi

setup_kubeconfig

# install.sh's own postflight only waits 5 minutes -- genuinely too short
# for identity's own 10-minute Kustomization ceiling, same reasoning as
# T-B. Poll again here for up to 15 minutes.
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
    ok DR/authentik-postgres-kustomizations-ready "every Flux Kustomization, including identity's, is Ready"
else
    fail DR/authentik-postgres-kustomizations-ready "not Ready after 15 minutes: $not_ready"
fi
kc get kustomizations -A || true

CA_CERT=/tmp/dr-scrap-ca.crt
kc get secret -n cert-manager scrap-ca-key-pair -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d > "$CA_CERT" || true

AUTH_BASE="https://auth.${BASE_DOMAIN}"
RESOLVE_ARGS="--resolve auth.${BASE_DOMAIN}:443:${NODE_IP}"

# authentik_api <method> <path> [json-body] -- a direct, authenticated
# REST call against authentik's own API using the bootstrap token as a
# Bearer credential. Deliberately not a browser-style flow-executor login
# (tests/profiles/t-b-standard.sh's authentik_login) -- T-B already
# proves a real interactive login works; this script's own subject is
# recovery, and a real API token is the correct, supported way for an
# automated client (this test, or any real integration) to manage
# objects like groups. Echoes the response body followed by a final line
# containing just the HTTP status code -- callers split the last line off.
authentik_api() {
    method="$1"; path="$2"; body="${3:-}"
    curl -s --max-time 15 --cacert "$CA_CERT" $RESOLVE_ARGS \
        -X "$method" -H "Authorization: Bearer $AUTHENTIK_TOKEN" -H "Content-Type: application/json" \
        -w '\n%{http_code}' ${body:+-d "$body"} "${AUTH_BASE}${path}" 2>/dev/null || true
}
api_status() { echo "$1" | tail -1; }
api_body()   { echo "$1" | sed '$d'; }

# ---------------------------------------------------------------------------
log "DR/authentik-postgres: Phase 3/5: create identifiable state, back it up"

# 3a. Create a canary group through authentik's own API -- the same
# object class docs/runbooks/README.md's manual execution used -- and
# retain its primary key. The stable-identifier claim this test exists to
# prove is specifically that THIS pk, not merely a group with this name,
# comes back after restore.
GROUP_NAME="dr-canary-$(date +%s)-$$"
create_resp=$(authentik_api POST /api/v3/core/groups/ "{\"name\":\"$GROUP_NAME\"}")
create_status=$(api_status "$create_resp")
CANARY_PK=$(api_body "$create_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pk",""))' 2>/dev/null || true)
if [ "$create_status" = "201" ] && [ -n "$CANARY_PK" ]; then
    ok DR/authentik-postgres-create "created group '$GROUP_NAME', pk=$CANARY_PK, through authentik's own API"
else
    fail DR/authentik-postgres-create "group creation failed (HTTP $create_status): $(api_body "$create_resp" | head -c 500)"
    echo "DR FAILED before any destructive step was taken -- nothing to clean up."
    exit 1
fi

# 3b. Trigger the real, platform-owned backup and prove the PostgreSQL
# consistency mechanism specifically ran -- not just that some backup
# job succeeded. platform/backup/scripts-configmap.yaml logs exactly
# "==> <ns>/<pvc>: running consistency command in pod <pod>: <cmd>"
# before it runs the command; the command itself is pg_dump, per
# capabilities/identity/helmrelease.yaml's own annotation.
PG_PVC=$(kc get pvc -n authentik -l backup.scrap.io/enabled=true -o jsonpath='{.items[0].metadata.name}')
if [ -z "$PG_PVC" ]; then
    fail DR/authentik-postgres-backup "no PVC in the authentik namespace is labelled backup.scrap.io/enabled=true -- capabilities/identity/helmrelease.yaml's backup labels may have regressed"
    echo "DR FAILED before any destructive step was taken -- nothing to clean up."
    exit 1
fi

BACKUP_JOB="dr-authentik-backup-$(date +%s)"
kc create job -n scrap-backup "$BACKUP_JOB" --from=cronjob/scrap-backup >/dev/null
backup_result=$(wait_for_job scrap-backup "$BACKUP_JOB" 30)
echo "      --- backup job log (job/$BACKUP_JOB) ---"
backup_log=$(kc logs -n scrap-backup "job/$BACKUP_JOB" 2>&1 || true)
echo "$backup_log" | sed 's/^/      /'

if [ "$backup_result" = ok ] \
    && echo "$backup_log" | grep -q "^==> authentik/$PG_PVC: running consistency command in pod" \
    && echo "$backup_log" | grep "^==> authentik/$PG_PVC: running consistency command in pod" | grep -q "pg_dump"; then
    ok DR/authentik-postgres-backup "backup succeeded, and its log shows the pg_dump consistency command actually ran against authentik/$PG_PVC before the snapshot"
else
    fail DR/authentik-postgres-backup "backup didn't succeed, or its log doesn't show the pg_dump consistency command running against authentik/$PG_PVC -- see the log above"
fi

# ---------------------------------------------------------------------------
log "DR/authentik-postgres: Phase 4/5: destroy, quiesce, restore, reload, restart"

# 4a. Delete the canary through the app's own API, and prove it's
# actually gone through that same interface -- not inferred from the
# delete call's own status code alone.
del_status=$(api_status "$(authentik_api DELETE "/api/v3/core/groups/$CANARY_PK/")")
verify_resp=$(authentik_api GET "/api/v3/core/groups/?name=$GROUP_NAME")
verify_count=$(api_body "$verify_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pagination",{}).get("count","?"))' 2>/dev/null || true)
if [ "$del_status" = "204" ] && [ "$verify_count" = "0" ]; then
    ok DR/authentik-postgres-delete "the canary group is confirmed gone through authentik's own API (DELETE 204, subsequent GET count=0)"
    app_state_deleted=1
else
    fail DR/authentik-postgres-delete "delete didn't confirm gone (DELETE status=$del_status, GET count=$verify_count) -- destroying storage under a group the API still reports would prove nothing"
    app_state_deleted=0
fi

# 4b. Genuinely destroy the underlying PostgreSQL state -- exec into the
# still-running postgres pod and remove BOTH its real data directory and
# the local pg_dump.sql.gz the consistency command wrote, so nothing
# usable survives on the live PVC at all; whatever comes back must come
# from restic's own repository, not from anything still sitting on disk
# here. Mirrors tests/profiles/t-a-minimal.sh's P5 fix (same class of
# fix, same reasoning: prove absence mechanically, don't infer it).
PG_POD_SELECTOR="app.kubernetes.io/instance=authentik,app.kubernetes.io/name=postgresql,app.kubernetes.io/component=primary"
data_destroyed=0
if [ "$app_state_deleted" = 1 ]; then
    pg_pod=$(kc get pods -n authentik -l "$PG_POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$pg_pod" ]; then
        kc exec -n authentik "$pg_pod" -- sh -c 'rm -rf /bitnami/postgresql/data /bitnami/postgresql/scrap-backup' || true
        gone_data=$(kc exec -n authentik "$pg_pod" -- sh -c '[ -e /bitnami/postgresql/data/PG_VERSION ] && echo present || echo absent' 2>/dev/null || true)
        gone_dump=$(kc exec -n authentik "$pg_pod" -- sh -c '[ -e /bitnami/postgresql/scrap-backup/pg_dump.sql.gz ] && echo present || echo absent' 2>/dev/null || true)
        if [ "$gone_data" = absent ] && [ "$gone_dump" = absent ]; then
            data_destroyed=1
            ok DR/authentik-postgres-destroy "PostgreSQL's real data directory and the local pg_dump.sql.gz are both confirmed gone from the live PVC (PG_VERSION: $gone_data, pg_dump.sql.gz: $gone_dump)"
        else
            fail DR/authentik-postgres-destroy "destroy step didn't confirm real storage loss (PG_VERSION: $gone_data, pg_dump.sql.gz: $gone_dump)"
        fi
    else
        fail DR/authentik-postgres-destroy "could not find the running postgres pod (selector: $PG_POD_SELECTOR) to destroy its data"
    fi
else
    fail DR/authentik-postgres-destroy "skipped -- the delete step above never confirmed the app-level state was gone"
fi

# pod_selector_for <kind> <ns> <name> -- reads a resource's OWN selector
# (spec.selector.matchLabels) rather than guessing this chart's label
# convention, so waiting for its pods to appear/disappear is correct
# regardless of exactly how the goauthentik/Bitnami charts label things.
# Goes through `-o json` + python3's real JSON parser, not
# `-o jsonpath='{.spec.selector.matchLabels}'` -- kubectl's jsonpath
# renders a whole map using Go's default %v formatting
# (`map[key:value ...]`), not JSON syntax, so piping that through a JSON
# parser would have silently broken the very first time this ran.
pod_selector_for() {
    kc get "$1" -n "$2" "$3" -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
ml = d.get('spec', {}).get('selector', {}).get('matchLabels', {})
print(','.join(f'{k}={v}' for k, v in ml.items()))
"
}

# 4c. Quiesce the COMPLETE DB-connected tier -- every Deployment in the
# authentik namespace (server AND worker) plus Postgres itself, all
# scaled to zero and confirmed actually gone before any restore is
# attempted. This is docs/runbooks/README.md's own documented lesson,
# found live restoring this exact application: leaving server/worker
# running while Postgres was reloaded let their own startup/migration
# logic race the manual reload and corrupt Django's migration
# bookkeeping. Deployment names discovered dynamically, not hardcoded --
# this chart's naming is not part of this project's own contract.
all_quiesced=0
if [ "$data_destroyed" = 1 ]; then
    STS_NAME=$(kc get statefulset -n authentik -o jsonpath='{.items[0].metadata.name}')
    DEPLOY_NAMES=$(kc get deployment -n authentik -o jsonpath='{.items[*].metadata.name}')

    kc scale -n authentik "statefulset/$STS_NAME" --replicas=0
    for d in $DEPLOY_NAMES; do
        kc scale -n authentik "deployment/$d" --replicas=0
    done

    quiesce_ok=1
    if [ "$(wait_for_pod_gone authentik "$(pod_selector_for statefulset authentik "$STS_NAME")")" != ok ]; then
        quiesce_ok=0
        echo "      --- postgres ($STS_NAME) did not confirm terminated within 60s ---"
    fi
    for d in $DEPLOY_NAMES; do
        if [ "$(wait_for_pod_gone authentik "$(pod_selector_for deployment authentik "$d")")" != ok ]; then
            quiesce_ok=0
            echo "      --- $d did not confirm terminated within 60s ---"
        fi
    done

    if [ "$quiesce_ok" = 1 ]; then
        all_quiesced=1
        ok DR/authentik-postgres-quiesce "postgres, and every Deployment in the authentik namespace ($DEPLOY_NAMES), confirmed terminated before any restore was attempted"
    else
        fail DR/authentik-postgres-quiesce "not every DB-connected component confirmed terminated within 60s -- see the detail above; restore was not attempted"
    fi
else
    fail DR/authentik-postgres-quiesce "skipped -- the destroy step above never confirmed real storage loss"
fi

# 4d. Restore through SCRAP's real recovery mechanism -- the same
# restic-restore Job pattern tests/profiles/t-a-minimal.sh uses for P5,
# including the same --path translation caveat (a snapshot's recorded
# Paths is under /hostdata, the backup job's own mountpoint, never the
# raw PV hostPath). Ends by discarding the just-restored raw data/
# directory again: capabilities/identity/README.md's own documented
# finding is that a file-level copy of a live Postgres data directory is
# not safe to resume from directly -- the pg_dump.sql.gz this same
# restore brings back is the only artifact the documented, supported
# reload procedure actually uses. Leaving the raw directory in place
# would let Postgres try to start from it instead, which is exactly the
# unsupported path this project's own docs warn against.
restore_result=""
if [ "$all_quiesced" = 1 ]; then
    PV_NAME=$(kc get pvc -n authentik "$PG_PVC" -o jsonpath='{.spec.volumeName}')
    HOST_PATH=$(kc get pv "$PV_NAME" -o jsonpath='{.spec.local.path}')
    STORAGE_ROOT="/var/lib/rancher/k3s/storage"
    MOUNT_ROOT="/hostdata"
    RESTORE_PATH=$(printf '%s' "$HOST_PATH" | sed "s#^$STORAGE_ROOT#$MOUNT_ROOT#")

    RESTORE_JOB="dr-authentik-restore-$(date +%s)"
    cat <<EOF | kc apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $RESTORE_JOB
  namespace: scrap-backup
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: restore
          image: restic/restic:0.19.1
          command:
            - sh
            - -c
            - >-
              restic restore latest --host=$INSTANCE_NAME --path=$RESTORE_PATH --target=/ &&
              echo '--- restored directory contents ---' && ls -la $RESTORE_PATH &&
              echo '--- discarding the restored raw data/ directory -- only pg_dump.sql.gz is the supported reload path ---' &&
              rm -rf $RESTORE_PATH/data &&
              ls -la $RESTORE_PATH
          env:
            - name: RESTIC_REPOSITORY
              value: "local:/var/lib/scrap-backup"
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef: { name: restic-credentials, key: RESTIC_PASSWORD }
          volumeMounts:
            - { name: hostdata, mountPath: /hostdata }
            - { name: repo, mountPath: /var/lib/scrap-backup }
      volumes:
        - name: hostdata
          hostPath: { path: /var/lib/rancher/k3s/storage, type: Directory }
        - name: repo
          hostPath: { path: /var/lib/scrap-backup, type: Directory }
EOF
    restore_result=$(wait_for_job scrap-backup "$RESTORE_JOB" 20)
    echo "      --- restic restore job log (job/$RESTORE_JOB) ---"
    kc logs -n scrap-backup "job/$RESTORE_JOB" 2>&1 | sed 's/^/      /' || true
fi

if [ "$restore_result" = ok ]; then
    ok DR/authentik-postgres-restore-job "restic restore ran against the wiped PVC and reported success"
else
    fail DR/authentik-postgres-restore-job "restic restore did not succeed -- see: kubectl logs -n scrap-backup job/$RESTORE_JOB"
fi

# 4e. Bring Postgres back up on the (now data/-empty) PVC -- the chart's
# own entrypoint runs initdb fresh against an empty PGDATA -- then
# reconstruct the database from the dump using the documented, supported
# procedure with hard error checking: psql -v ON_ERROR_STOP=1, which
# exits non-zero on the FIRST error rather than continuing past it. A
# direct client query afterward (not through the app) confirms the
# reloaded database is genuinely queryable, per docs/runbooks/README.md's
# own "verify the database directly" lesson.
reload_result=""
if [ "$restore_result" = ok ]; then
    kc scale -n authentik "statefulset/$STS_NAME" --replicas=1
    if [ "$(wait_for_pod_ready authentik "$(pod_selector_for statefulset authentik "$STS_NAME")")" = ok ]; then
        new_pg_pod=$(kc get pods -n authentik -l "$PG_POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}')
        # The assignment lives INSIDE the if condition, deliberately --
        # under `set -e`, `var=$(cmd)` as a standalone statement aborts
        # the whole script immediately if cmd fails, before a later
        # `reload_exit=$?` line would ever run. Inside an `if`, a failing
        # command substitution does not trigger errexit; the exit status
        # just becomes the condition's own result, which is exactly what
        # this needs to check without killing the script on the very
        # failure it exists to detect and report.
        if reload_log=$(kc exec -n authentik "$new_pg_pod" -- sh -c \
            'gunzip -c /bitnami/postgresql/scrap-backup/pg_dump.sql.gz | PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")" psql -U authentik -d authentik -v ON_ERROR_STOP=1' 2>&1); then
            reload_exit=0
        else
            reload_exit=$?
        fi
        echo "      --- psql reload output ---"
        echo "$reload_log" | sed 's/^/      /'
        direct_query=$(kc exec -n authentik "$new_pg_pod" -- sh -c \
            'PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")" psql -U authentik -d authentik -tAc "SELECT 1"' 2>/dev/null || true)
        if [ "$reload_exit" = 0 ] && ! echo "$reload_log" | grep -qi "^ERROR"  && [ "$direct_query" = "1" ]; then
            reload_result=ok
            ok DR/authentik-postgres-reload "pg_dump.sql.gz reloaded with psql -v ON_ERROR_STOP=1, zero errors, and a direct client query against the reloaded database succeeded"
        else
            fail DR/authentik-postgres-reload "reload did not complete cleanly (exit=$reload_exit, direct query result='$direct_query') -- see the psql output above"
        fi
    else
        fail DR/authentik-postgres-reload "postgres never became Ready again after restoring -- see: kubectl logs -n authentik statefulset/$STS_NAME"
    fi
else
    fail DR/authentik-postgres-reload "skipped -- the restic restore job above did not succeed"
fi

# 4f. Restart the application tier, then prove FUNCTIONAL recovery
# through authentik's own API -- not container health, not HTTP 200 on
# its own, but the exact same primary key the canary was created with
# (docs/runbooks/README.md's own "verified by recently-changed values,
# never row counts" discipline, applied to an identifier instead of a
# value: a NEW group that merely happens to share the old name would not
# satisfy this).
if [ "$reload_result" = ok ]; then
    for d in $DEPLOY_NAMES; do
        kc scale -n authentik "deployment/$d" --replicas=1
    done
    tier_ready=1
    for d in $DEPLOY_NAMES; do
        if [ "$(wait_for_pod_ready authentik "$(pod_selector_for deployment authentik "$d")" 36)" != ok ]; then
            tier_ready=0
            echo "      --- $d never became Ready within 180s after restart ---"
            kc get pods -n authentik -o wide || true
            kc logs -n authentik "deployment/$d" --all-containers --tail=100 2>&1 | sed 's/^/      /' || true
        fi
    done

    if [ "$tier_ready" = 1 ]; then
        # A few extra seconds for the worker's own migration-check pass to
        # settle before hitting the API -- the migration-corruption bug
        # this whole ordering exists to prevent surfaces as exactly this
        # kind of race, so give it a real chance to show up rather than
        # racing the check against it ourselves.
        sleep 10
        final_resp=$(authentik_api GET "/api/v3/core/groups/?name=$GROUP_NAME")
        final_status=$(api_status "$final_resp")
        final_pk=$(api_body "$final_resp" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("results",[]); print(r[0]["pk"] if r else "")' 2>/dev/null || true)
        echo "      --- final API response ---"
        api_body "$final_resp" | sed 's/^/      /'
        if [ "$final_status" = "200" ] && [ "$final_pk" = "$CANARY_PK" ]; then
            ok DR/authentik-postgres-functional-recovery "the restored group is reachable through authentik's own API with the EXACT SAME primary key ($CANARY_PK) it was created with -- not merely an object with the same name"
        else
            fail DR/authentik-postgres-functional-recovery "API did not confirm the same primary key survived (HTTP $final_status, got pk='$final_pk', wanted '$CANARY_PK') -- see the response above"
        fi
    else
        fail DR/authentik-postgres-functional-recovery "the application tier never became Ready after restart -- see pod/log detail above. This is consistent with corrupted migration state, not merely a slow start"
    fi
else
    fail DR/authentik-postgres-functional-recovery "skipped -- the reload step above did not complete cleanly"
fi

# ---------------------------------------------------------------------------
log "DR/authentik-postgres: Phase 5/5: result"
if [ "$status" -ne 0 ]; then
    echo "DR/authentik-postgres FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "DR/authentik-postgres PASSED -- identity's own multi-tier Postgres genuinely destroyed, quiesced in the documented order, restored through SCRAP's real recovery mechanism, reloaded with hard error checking, and proven back through authentik's own API with the exact same primary key."
