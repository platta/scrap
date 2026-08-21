#!/bin/sh
# T-A -- Minimal acceptance profile. See tests/profiles/README.md for what
# this is required to prove. Run as a normal user with passwordless sudo
# (the same expectation bootstrap/install.sh itself already has) against a
# genuinely fresh host -- a disposable VM, or a single-use CI runner; this
# script does not know or care which. Do not run the whole script under
# `sudo` itself -- it escalates only where install.sh and cluster access
# actually need it, the same least-privilege shape this project's own
# manual scratch-VM sessions have always used.
#
# This is not a CI-specific installation path. It runs the exact same
# bootstrap/install.sh a real operator runs, the exact same way
# docs/core/bootstrap-lifecycle.md documents, then mechanically re-checks
# the exact postconditions this project's own manual live-validation
# sessions have already proven by hand -- the destructive-restore
# procedure in step 2f is docs/runbooks/README.md's own five-step
# procedure, encoded verbatim, not reinvented for CI convenience.
#
# Covers every application pattern the *minimal* profile actually ships
# (P1, P4, P5, P6 -- see apps/examples/kustomization.yaml). P2 and P3 need
# capabilities/identity/, which the minimal profile deliberately doesn't
# have; see tests/profiles/t-b-standard.sh for those.
#
# A human can run this identically on their own scratch VM to reproduce a
# CI failure locally:
#   sh tests/profiles/t-a-minimal.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

BASE_DOMAIN=$(cfg_value BASE_DOMAIN)
INSTANCE_NAME=$(cfg_value INSTANCE_NAME)
status=0

# ---------------------------------------------------------------------------
log "T-A: Phase 0/4: environment prerequisites"
install_prereqs

# NODE_IP is needed before bootstrap now, not just after it: P6's setup
# below points the shipped example's external-backend address at this
# runner itself, so it has to be known before clusters/example/
# instance-config.yaml is edited and committed by install.sh.
NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

# ---------------------------------------------------------------------------
log "T-A: Phase 1/4: stand up a real external backend for P6"
# apps/examples/p6-external-proxy/ ships pointed at an RFC 5737
# documentation address on purpose -- its own README says plainly that
# until you replace it with a real device's address, "this example
# demonstrates the shape of the pattern, not a working proxy." A resource-
# readiness check can't tell the difference between that placeholder shape
# and a genuinely working proxy; only pointing it at something real and
# then reading real content back through it can. This starts a plain,
# non-Kubernetes HTTP server on the runner's own primary interface --
# exactly what a real NAS or router admin UI would be from the cluster's
# point of view: a device with an address on the LAN, but no SCRAP-managed
# code and no cluster involvement at all. It listens on a non-standard
# port, not 80, because 80 on this same host is already claimed by
# Traefik's own ServiceLB hostPort binding once bootstrap runs -- a real,
# unavoidable collision on a single-machine test host that a real
# multi-device LAN never has. EXAMPLE_P6_BACKEND_PORT (see
# instance-config.yaml and endpointslice.yaml) exists so this is a normal,
# generally-useful configuration knob, not a CI-only fork of the example.
P6_BACKEND_PORT=18080
P6_MARKER="t-a-p6-marker-$(date +%s)-$$"
P6_WEBROOT=$(mktemp -d)
echo "$P6_MARKER" > "$P6_WEBROOT/index.html"
( cd "$P6_WEBROOT" && exec python3 -m http.server "$P6_BACKEND_PORT" --bind 0.0.0.0 >/tmp/t-a-p6-backend.log 2>&1 ) &
P6_BACKEND_PID=$!
sleep 1

sed -i "s|^\(  EXAMPLE_P6_BACKEND_ADDRESS: \).*|\1\"$NODE_IP\"|" "$INSTANCE_CONFIG"
if grep -q '^  EXAMPLE_P6_BACKEND_PORT:' "$INSTANCE_CONFIG"; then
    sed -i "s|^\(  EXAMPLE_P6_BACKEND_PORT: \).*|\1\"$P6_BACKEND_PORT\"|" "$INSTANCE_CONFIG"
else
    printf '  EXAMPLE_P6_BACKEND_PORT: "%s"\n' "$P6_BACKEND_PORT" >> "$INSTANCE_CONFIG"
fi

# ---------------------------------------------------------------------------
log "T-A: Phase 2/4: bootstrap/install.sh -- the real, unmodified installer"
# SCRAP_ESCROW_CONFIRMED=1 is install.sh's own documented mechanism for a
# non-interactive shell (docs/core/bootstrap-lifecycle.md step 3) -- not a
# CI-specific bypass invented here. Everything else is left at its
# documented default: REPO_URL unset (the D5 local-bare-repo minimum
# path), CLUSTER_PATH the checked-in clusters/example/ -- with the one
# instance-config edit above, which install.sh's own "cp -a $REPO_ROOT/."
# step (see bootstrap/install.sh Step 5/7) carries straight into what gets
# committed and reconciled, the same as any real operator's own edit
# would.
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
# REAL BUG, root-caused via the §T-A-destructive-restore investigation
# (see tests/profiles/lib.sh's kc() for the earlier chapters -- this is
# where the actual poisoning happens, found by checking evidence instead
# of trusting that removing sudo from kc() alone would be enough. It
# wasn't: the same "kuberc: ... permission denied" showed up even for
# the plain, unprivileged "runner" user reading its OWN
# /home/runner/.kube/kuberc -- meaning the problem isn't which user
# kc() itself runs as at all. install.sh runs under `sudo -E` too, which
# preserves HOME=/home/runner while the process is root; install.sh's
# own internal kubectl calls (unrelated to this script's kc(), and
# rightly so -- it's the real, unmodified installer) then run as root
# with that same borrowed HOME, and something in that combination
# leaves /home/runner/.kube/ behind in a state the later, genuinely
# unprivileged "runner" user can't read -- root-owned, most likely.
# Overriding HOME to /root for JUST this one invocation (not this
# script's own environment -- kc()'s later unprivileged calls still
# need HOME=/home/runner, their own real home) keeps every
# root-privileged operation in the ENTIRE bootstrap (not just this
# script's own postcondition checks) inside root's own home, which
# root can always read/write without issue -- so /home/runner/.kube/
# is never touched by anything except the genuinely-unprivileged
# runner user from here on. This changes only how this test-harness
# script invokes the real installer, never the installer itself.
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A: bootstrap/install.sh exited non-zero -- see the 'Step N/7' marker"
    echo "      above for which layer of the documented bootstrap sequence failed."
    exit 1
fi

setup_kubeconfig

# One-time diagnostic evidence for the kc()/kuberc investigation
# (tests/profiles/lib.sh) -- confirms kc() is genuinely running kubectl
# as this unprivileged user now, not root, and exactly which binary
# that resolves to. Kept as a normal, always-printed diagnostic line
# (not conditional on failure) since it's cheap and the whole reason
# this fix needed correcting twice already was not having this
# evidence the first time.
echo "      --- kc() identity, for the record ---"
echo "      whoami: $(whoami), HOME: $HOME, KUBECONFIG: $KUBECONFIG"
kc version --client 2>&1 | sed 's/^/      /' || true
echo "      which kubectl: $(command -v kubectl)"
echo "      --- state of \$HOME/.kube/ after bootstrap, before any kc() call runs ---"
ls -la "$HOME/.kube/" 2>&1 | sed 's/^/      /' || echo "      ($HOME/.kube/ does not exist)"

# ---------------------------------------------------------------------------
log "T-A: Phase 3/4: T-A postconditions"

# 2a. Every Flux Kustomization Ready -- install.sh's own postflight.sh
# already waited for this; re-check explicitly here so a CI failure names
# this specific postcondition rather than relying on postflight's exit
# code (which install.sh deliberately ignores with '|| true').
#
# REAL BUG, found live via an independent review and confirmed against
# this exact repository's own CI log bytes (not assumed): kubectl's
# human-readable table output pads columns with SPACES, not tab
# characters -- `cat -A` on a real captured T-A run's own
# `kc get kustomizations -A` output showed zero ^I markers anywhere.
# The previous version of this line (`awk -F'\t' ... $5 ...`) therefore
# never found more than one field on any row; `$5` was always empty,
# `gsub` a no-op on it, and `$5!="True"` was true for every single
# Kustomization every time, unconditionally -- awk printed one blank
# line per Kustomization ($2 was equally always-empty), and since that
# entire captured stdout consisted of NOTHING BUT newlines, shell
# command substitution's own trailing-newline-stripping collapsed it
# to a completely empty string. `not_ready` was therefore ALWAYS empty
# and this check could never have failed, regardless of the real
# Kustomization state -- a vacuous oracle, not a working one. Replaced
# with real JSON and a real Ready-condition lookup: the same object
# model `kc get certificate ... -o jsonpath='...status.conditions...'`
# already relies on elsewhere in this exact script, not a second,
# fragile text-table parser. A Kustomization with no Ready condition at
# all (not yet reconciled) reads as "Unknown", not "True" -- fails open,
# not open-by-accident.
not_ready=$(kc get kustomizations -A -o json | jq -r '
    .items[] |
    (.status.conditions // [] | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
    select($ready != "True") |
    "\(.metadata.namespace)/\(.metadata.name) (ready=\($ready))"
')
if [ -z "$not_ready" ]; then
    ok T-A/kustomizations-ready "every Flux Kustomization is Ready"
else
    fail T-A/kustomizations-ready "not Ready: $not_ready"
fi
kc get kustomizations -A || true

# NEGATIVE CONTROL, DO NOT KEEP: proving the corrected readiness oracle
# above can actually turn red, the same discipline already applied
# elsewhere in this project. The OLD oracle (awk -F'\t' text-table
# parsing) could never fail regardless of real state -- see this
# check's own comment a few lines up for the full root-cause writeup.
# Deliberately breaks a REAL, live Kustomization (points apps-examples at
# a path that doesn't exist), confirms the SAME jq-based check above now
# genuinely reports it not_ready, then reverts and confirms recovery --
# never leaving live breakage behind.
neg_orig_path=$(kc get kustomization -n flux-system apps-examples -o jsonpath='{.spec.path}')
kc patch kustomization -n flux-system apps-examples --type=merge \
    -p '{"spec":{"path":"./this-path-does-not-exist-negative-control"}}' >/dev/null
flux reconcile kustomization apps-examples --with-source >/dev/null 2>&1 || true
neg_seen=""
i=0
while [ "$i" -lt 24 ]; do
    neg_check=$(kc get kustomizations -A -o json | jq -r '
        .items[] |
        (.status.conditions // [] | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
        select($ready != "True") |
        "\(.metadata.namespace)/\(.metadata.name) (ready=\($ready))"
    ')
    if [ -n "$neg_check" ]; then
        neg_seen=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
echo "      --- negative control: readiness check while apps-examples is deliberately broken ---"
echo "      $neg_check"
if [ -n "$neg_seen" ]; then
    ok T-A/kustomizations-ready-negative-control "the corrected readiness oracle genuinely turned red for a real, live NotReady Kustomization (apps-examples: $neg_check)"
else
    fail T-A/kustomizations-ready-negative-control "the readiness oracle STILL reported nothing wrong with apps-examples deliberately broken -- the oracle cannot turn red"
fi

# Revert -- same mechanism, reversed.
kc patch kustomization -n flux-system apps-examples --type=merge \
    -p "{\"spec\":{\"path\":\"$neg_orig_path\"}}" >/dev/null
flux reconcile kustomization apps-examples --with-source >/dev/null 2>&1 || true
neg_reverted=""
i=0
while [ "$i" -lt 24 ]; do
    neg_check2=$(kc get kustomizations -A -o json | jq -r '
        .items[] |
        (.status.conditions // [] | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
        select($ready != "True") |
        "\(.metadata.namespace)/\(.metadata.name) (ready=\($ready))"
    ')
    if [ -z "$neg_check2" ]; then
        neg_reverted=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ -n "$neg_reverted" ]; then
    ok T-A/kustomizations-ready-negative-control-revert "reverting apps-examples's path brought every Kustomization back to Ready"
else
    fail T-A/kustomizations-ready-negative-control-revert "apps-examples did not recover to Ready after reverting its path -- got: $neg_check2"
fi

# 2a2. Grafana is genuinely absent from Minimal -- not inferred from "T-A
# never copies capabilities/grafana/ in," but checked directly against
# this live cluster: no Grafana workload exists anywhere, in any
# namespace. Enabling capabilities/grafana/ (T-B's own extension) must
# never leak into the minimal profile it's entirely separate from.
grafana_present=$(kc get deployments -A -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | wc -l)
if [ "${grafana_present:-0}" -eq 0 ]; then
    ok T-A/grafana-absent "no Grafana workload exists anywhere in the minimal profile's cluster -- capabilities/grafana/ is genuinely optional, not silently on"
else
    fail T-A/grafana-absent "expected zero Grafana deployments in the minimal profile, found $grafana_present"
fi

# 2b. The gap tests/profiles/README.md itself already found: a live value
# check, not just that Helm accepted the values without error.
svc_type=$(kc get svc -n traefik traefik -o jsonpath='{.spec.type}' 2>/dev/null || true)
if [ "$svc_type" = "LoadBalancer" ]; then
    ok T-A/traefik-service-type "traefik Service is genuinely type LoadBalancer"
else
    fail T-A/traefik-service-type "traefik Service type is '$svc_type', expected LoadBalancer"
fi

# 2c. The private CA issued the one wildcard certificate.
cert_ready=$(kc get certificate -n traefik scrap-wildcard \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$cert_ready" = "True" ]; then
    ok T-A/wildcard-certificate "scrap-wildcard Certificate is Ready (private CA issued it)"
else
    fail T-A/wildcard-certificate "scrap-wildcard Certificate Ready condition is '$cert_ready'"
fi

# Export the CA root ourselves (not relying on postflight's $HOME, which
# under `sudo` is root's home, not necessarily this shell's) -- the exact
# secret bootstrap/postflight.sh itself reads.
CA_CERT=/tmp/t-a-scrap-ca.crt
kc get secret -n cert-manager scrap-ca-key-pair -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d > "$CA_CERT" || true

# 2d. P1 reachable over TLS, trusting only the platform's real CA -- never -k.
p1_body=$(curl -s --max-time 15 --cacert "$CA_CERT" \
    --resolve "p1.${BASE_DOMAIN}:443:${NODE_IP}" \
    "https://p1.${BASE_DOMAIN}/" 2>&1 || true)
if echo "$p1_body" | grep -q "Hostname:"; then
    ok T-A/p1-reachable "p1.${BASE_DOMAIN} reachable over HTTPS through the real private CA"
else
    fail T-A/p1-reachable "unexpected response from p1.${BASE_DOMAIN}: $(echo "$p1_body" | head -3)"
fi

# 2d2. P4 -- raw TCP round trip through the LoadBalancer Service, bypassing
# the Gateway entirely (that's the pattern's whole point: not every
# protocol is HTTP). alpine/socat's whole job is TCP-LISTEN -> EXEC:/bin/cat,
# so whatever bytes go in come back unchanged -- a behavioral proof the
# byte stream genuinely round-tripped through ServiceLB into the pod and
# back, not just that the Service/pod exist and are Ready.
P4_MARKER="t-a-p4-$(date +%s)-$$"
p4_echo=$(printf '%s\n' "$P4_MARKER" | timeout 5 nc "$NODE_IP" 9000 2>/dev/null || true)
if [ "$p4_echo" = "$P4_MARKER" ]; then
    ok T-A/p4-raw-tcp "raw TCP byte stream round-tripped through the LoadBalancer Service into the pod and back"
else
    fail T-A/p4-raw-tcp "expected '$P4_MARKER' echoed back on port 9000, got '$p4_echo'"
fi

# 2d3. P6 -- the platform's TLS/routing story holding for a backend that
# isn't a Kubernetes workload at all. Reads back the actual marker the
# real external-like backend served in Phase 1/4, through the platform's
# Gateway and TLS -- proof Traefik genuinely proxied to that address, not
# just that the Service/EndpointSlice/HTTPRoute objects exist and are
# Accepted.
p6_body=$(curl -s --max-time 15 --cacert "$CA_CERT" \
    --resolve "p6.${BASE_DOMAIN}:443:${NODE_IP}" \
    "https://p6.${BASE_DOMAIN}/" 2>&1 || true)
if echo "$p6_body" | grep -q "$P6_MARKER"; then
    ok T-A/p6-external-proxy "p6.${BASE_DOMAIN} proxied through to the real external backend's own content"
else
    fail T-A/p6-external-proxy "expected marker '$P6_MARKER' from p6.${BASE_DOMAIN}, got: $(echo "$p6_body" | head -3)"
fi
kill "$P6_BACKEND_PID" 2>/dev/null || true

# 2e. Backup to local path -- trigger a real run against the whole
# labelled-PVC set (P5's redis included) and confirm it succeeds.
BACKUP_JOB="t-a-backup-$(date +%s)"
kc create job -n scrap-backup "$BACKUP_JOB" --from=cronjob/scrap-backup >/dev/null
backup_result=$(wait_for_job scrap-backup "$BACKUP_JOB" 24)
if [ "$backup_result" = ok ]; then
    ok T-A/backup-runs "backup job completed successfully (credentials, repository, discovery all working)"
else
    fail T-A/backup-runs "backup job did not succeed -- see: kubectl logs -n scrap-backup job/$BACKUP_JOB"
    kc logs -n scrap-backup "job/$BACKUP_JOB" || true
fi

# NEGATIVE CONTROL, DO NOT KEEP: proving platform/backup/'s discovery
# loop genuinely continues past a FAILING consistency command to reach a
# later PVC, rather than aborting the whole run under the script's own
# `set -eu` -- see platform/backup/scripts-configmap.yaml's own comment
# at the fix for the full root-cause writeup. A temporary, live-only PVC
# ("negctl-pvc", named to sort alphabetically BEFORE p5-redis-data within
# the same namespace, so discovery reaches it first) with a consistency
# command guaranteed to fail ("false"), backed by a real, bound
# local-path PV (a minimal Pod actually mounts it, forcing
# WaitForFirstConsumer binding) -- never committed to any file, applied
# directly against the live cluster and deleted again below.
kc apply -f - >/dev/null <<'NEGCTL_EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: negctl-pvc
  namespace: scrap-examples
  labels:
    backup.scrap.io/enabled: "true"
  annotations:
    backup.scrap.io/consistency-command: "false"
    backup.scrap.io/consistency-pod-selector: "app=negctl"
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 64Mi } }
---
apiVersion: v1
kind: Pod
metadata:
  name: negctl-pod
  namespace: scrap-examples
  labels: { app: negctl }
spec:
  containers:
    - name: negctl
      image: alpine:3.20
      command: ["sleep", "infinity"]
      volumeMounts:
        - { name: data, mountPath: /data }
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: negctl-pvc }
NEGCTL_EOF
neg5_pod_ready=$(wait_for_pod_ready scrap-examples app=negctl 24)
if [ "$neg5_pod_ready" != ok ]; then
    fail T-A/backup-discovery-negative-control "the temporary negctl pod never became Ready -- can't run this negative control"
    kc describe pod -n scrap-examples negctl-pod 2>&1 | tail -30 || true
else
    NEG5_JOB="t-a-negctl-backup-$(date +%s)"
    kc create job -n scrap-backup "$NEG5_JOB" --from=cronjob/scrap-backup >/dev/null
    neg5_result=$(wait_for_job scrap-backup "$NEG5_JOB" 24)
    neg5_log=$(kc logs -n scrap-backup "job/$NEG5_JOB" 2>&1 || true)
    echo "      --- negative-control backup job log (negctl's consistency command deliberately fails) ---"
    echo "$neg5_log" | sed 's/^/      /'
    neg5_attributed=$(echo "$neg5_log" | grep -c "FAIL  scrap-examples/negctl-pvc: consistency command failed" || true)
    neg5_p5_ran=$(echo "$neg5_log" | grep -c "scrap-examples/p5-redis-data: backing up" || true)
    if [ "${neg5_attributed:-0}" -ge 1 ] && [ "${neg5_p5_ran:-0}" -ge 1 ]; then
        ok T-A/backup-discovery-negative-control "negctl-pvc's failing consistency command was logged as an attributable FAIL, AND discovery continued on to back up p5-redis-data in the SAME run -- one bad PVC no longer aborts the whole discovery loop"
    else
        fail T-A/backup-discovery-negative-control "expected an attributable FAIL for negctl-pvc (found $neg5_attributed) AND p5-redis-data still being processed (found $neg5_p5_ran) in the same run -- see the job log above"
    fi
fi
kc delete pod -n scrap-examples negctl-pod --ignore-not-found >/dev/null 2>&1 || true
kc delete pvc -n scrap-examples negctl-pvc --ignore-not-found >/dev/null 2>&1 || true

# 2f. Destructive restore, verified by a specific named value -- exactly
# docs/runbooks/README.md's "Single-application destructive restore"
# procedure, against apps/examples/p5-stateful-backup/'s Redis, including
# the ordering fix that procedure itself documents finding live: the
# whole tier touching the data must be scaled to zero before restoring,
# not just deleted from.
CANARY="t-a-canary-$(date +%s)-$$"
kc exec -n scrap-examples deploy/p5-redis -- redis-cli SET t-a-canary "$CANARY" >/dev/null
# Sanity check the write actually landed before we trust anything downstream
# of it -- if this doesn't come back, the bug is in this SET, not in backup
# or restore.
preflight_check=$(kc exec -n scrap-examples deploy/p5-redis -- redis-cli GET t-a-canary 2>/dev/null || true)
if [ "$preflight_check" != "$CANARY" ]; then
    echo "WARN  T-A/destructive-restore: canary SET didn't read back immediately (got '$preflight_check') -- continuing anyway to see what backup/restore do"
fi

RESTORE_JOB="t-a-restore-$(date +%s)"
kc create job -n scrap-backup "${RESTORE_JOB}-backup" --from=cronjob/scrap-backup >/dev/null
wait_for_job scrap-backup "${RESTORE_JOB}-backup" 24 >/dev/null
# Diagnostic evidence, always -- not just on outright job failure. A job
# that exits 0 but restores the wrong content (the actual failure this is
# guarding against) previously left zero evidence of what the backup step
# itself saw and did.
echo "      --- backup-trigger job log (job/${RESTORE_JOB}-backup) ---"
kc logs -n scrap-backup "job/${RESTORE_JOB}-backup" 2>&1 | sed 's/^/      /' || true

# CORRECTION, found auditing this exact script (docs/core/recovery-model.md
# DR-acceptance audit): every step above this point ran for real, but
# nothing between here and the restic restore below ever actually
# destroyed the canary. The pod was scaled to zero (which does not touch
# local-path PVC content -- same node, same on-disk directory) and restic
# restore was then pointed at the SAME never-touched data. A silently
# no-op restore (wrong --path, wrong repo, an empty snapshot) would have
# passed this test with a clean exit code, because the live data was
# never actually gone to begin with -- exactly the "restic exited 0 is
# not proof" failure this project's own DR-acceptance audit exists to
# rule out. docs/runbooks/README.md's own procedure has always had a
# step 3, "destroy the data for real"; this script skipped straight from
# backup to restore. Fixed here: delete the key AND remove the on-disk
# RDB file backing it, then mechanically confirm both are gone -- through
# the app's own interface and by reading the filesystem directly -- before
# any restore is attempted. Previously-shipped runs of this script that
# reported "the exact canary value round-tripped through destroy -> restic
# restore" never destroyed anything; that message was true only in that
# the value survived the trip, not that anything had to survive it.
kc exec -n scrap-examples deploy/p5-redis -- redis-cli DEL t-a-canary >/dev/null
kc exec -n scrap-examples deploy/p5-redis -- rm -f /data/dump.rdb
gone_in_app=$(kc exec -n scrap-examples deploy/p5-redis -- redis-cli GET t-a-canary 2>/dev/null || true)
gone_on_disk=$(kc exec -n scrap-examples deploy/p5-redis -- sh -c '[ -f /data/dump.rdb ] && echo present || echo absent' 2>/dev/null || true)
if [ -z "$gone_in_app" ] && [ "$gone_on_disk" = absent ]; then
    data_destroyed=1
    ok T-A/destructive-restore-destroy "the canary is genuinely gone -- absent from the app's own GET, and the on-disk RDB file that backed it no longer exists"
else
    data_destroyed=0
    fail T-A/destructive-restore-destroy "destroy step didn't confirm real data loss (redis-cli GET returned '$gone_in_app', on-disk dump.rdb is '$gone_on_disk') -- restore would prove nothing, so it will not be attempted"
fi

PVC_NAME=p5-redis-data
PV_NAME=$(kc get pvc -n scrap-examples "$PVC_NAME" -o jsonpath='{.spec.volumeName}')
HOST_PATH=$(kc get pv "$PV_NAME" -o jsonpath='{.spec.local.path}')

# REAL BUG, found by this script's first genuinely-from-zero run: the
# backup job (platform/backup/scripts-configmap.yaml) mounts the host
# storage root at /hostdata and passes restic the path AFTER translating
# it to that mountpoint (`sed "s#^$storage_root#$mount_root#"`) -- so
# every snapshot's recorded Paths is /hostdata/pvc-..., never the raw
# spec.local.path value. A restic restore --path filter matches the
# snapshot's recorded Paths exactly, so passing the untranslated host path
# here always failed with "no snapshot found", even though the snapshot
# genuinely existed. The restore job below mounts the same host directory
# at the same /hostdata mountpoint the backup job uses (copied from
# backup-cronjob.yaml, as docs/runbooks/README.md's step 5 already says to
# do) -- this translation makes --path match what's actually in the
# repository, and --target=/ then writes the restored files back through
# that same bind mount onto the real host path.
STORAGE_ROOT="/var/lib/rancher/k3s/storage"
MOUNT_ROOT="/hostdata"
RESTORE_PATH=$(printf '%s' "$HOST_PATH" | sed "s#^$STORAGE_ROOT#$MOUNT_ROOT#")

if [ "$data_destroyed" = 1 ]; then
    kc scale -n scrap-examples deploy/p5-redis --replicas=0
    # This is the actual synchronization boundary the whole procedure
    # depends on -- restoring while the old pod might still be attached to
    # the PVC is exactly the race docs/runbooks/README.md already documents
    # finding once ("Never restore into a PVC whose pod is still attached to
    # it"). Polls `kubectl get` directly (wait_for_pod_gone, lib.sh) rather
    # than trusting `kubectl wait --for=delete`, which this same
    # investigation found fails its own argument parsing intermittently in
    # this environment even with correct, valid arguments -- see
    # wait_for_pod_gone's own comment for the full evidence. A failure here
    # is a hard stop for the restore attempt, not a silently-ignored
    # possibility: restoring without confirmed termination would be unsound.
    if [ "$(wait_for_pod_gone scrap-examples app=p5-redis)" = ok ]; then
        pod_terminated=1
    else
        pod_terminated=0
        echo "      --- old p5-redis pod did not confirm terminated within 60s -- restore NOT attempted ---"
    fi
else
    # Nothing was genuinely destroyed above -- attempting a restore now
    # would prove nothing (see the destroy-step failure already recorded).
    # Don't scale anything down or run a restore Job against data that was
    # never actually lost.
    pod_terminated=0
fi

if [ "$pod_terminated" = 1 ]; then
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
          # ls -la after the restore, not a separate `kubectl exec` into
          # the redis pod later -- REAL BUG under active investigation:
          # restic reports a genuine, correctly-sized restore every time,
          # but the canary never comes back. If redis is crash-looping on
          # the restored file (corrupt RDB, an ownership/permission
          # mismatch, or an AOF file taking precedence over the RDB this
          # restore actually wrote), a `kubectl exec` moments later can
          # race a container restart and report a misleading "container
          # not found" instead of real evidence. This runs inside the
          # restore Job itself, immediately after restic exits, so
          # there's no window for anything else to touch the directory
          # first.
          command:
            - sh
            - -c
            - restic restore latest --host=$INSTANCE_NAME --path=$RESTORE_PATH --target=/ && echo '--- restored directory contents ---' && ls -la $RESTORE_PATH
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
else
    restore_result=""
fi

kc scale -n scrap-examples deploy/p5-redis --replicas=1
# Same reasoning as the scale-down wait above: this is the real
# synchronization boundary for "is the app's own pod actually able to
# answer redis-cli yet", not a cosmetic nicety -- so its failure is
# tracked explicitly (pod_ready) rather than swallowed, and polled
# directly (wait_for_pod_ready, lib.sh) for the same reason the
# scale-down wait no longer uses `kubectl wait` either.
if [ "$(wait_for_pod_ready scrap-examples app=p5-redis)" = ok ]; then
    pod_ready=1
else
    pod_ready=0
fi

if [ "$data_destroyed" != 1 ]; then
    fail T-A/destructive-restore "the destroy step (see T-A/destructive-restore-destroy above) never confirmed real data loss, so no restore was attempted -- see that check's own message for what it found"
elif [ "$pod_terminated" != 1 ]; then
    fail T-A/destructive-restore "the old p5-redis pod never confirmed terminated within 60s after scaling to zero -- restore was not attempted, since restoring while it might still be attached to the PVC is exactly the race docs/runbooks/README.md warns against"
elif [ "$pod_ready" != 1 ]; then
    fail T-A/destructive-restore "restic restore ran, but the redis pod never became Ready again within 60s afterward -- see: kubectl logs -n scrap-examples deploy/p5-redis"
elif [ "$restore_result" = ok ]; then
    restored=$(kc exec -n scrap-examples deploy/p5-redis -- redis-cli GET t-a-canary 2>/dev/null || true)
    if [ "$restored" = "$CANARY" ]; then
        ok T-A/destructive-restore "the canary was genuinely destroyed (deleted from redis, its on-disk RDB removed, both confirmed gone) and the exact value came back through restic restore -> the original app's own interface"
    else
        fail T-A/destructive-restore "restore job succeeded but the canary value did not come back (got '$restored', wanted '$CANARY')"
        # `kubectl exec` here, in earlier runs of this same investigation,
        # raced a redis crash-loop and only ever reported "container not
        # found" -- `kubectl logs` doesn't have that race (it reads the
        # (possibly-restarted) container's own history, not a live
        # connection to a specific instance of it), so use that instead
        # for what's actually the decisive evidence here: did redis log a
        # real startup error loading the restored file?
        echo "      --- redis pod's own log, for comparison ---"
        kc logs -n scrap-examples deploy/p5-redis --all-containers --previous 2>&1 | sed 's/^/      /' || true
        kc logs -n scrap-examples deploy/p5-redis --all-containers 2>&1 | sed 's/^/      /' || true
        echo "      --- redis data dir on the restored pod, for comparison ---"
        kc exec -n scrap-examples deploy/p5-redis -- sh -c 'ls -la /data; redis-cli DBSIZE' 2>&1 | sed 's/^/      /' || true
    fi
else
    fail T-A/destructive-restore "restic restore job did not succeed -- see: kubectl logs -n scrap-backup job/$RESTORE_JOB"
fi

# 2g. A test alert actually reaches the observability surface -- not just
# that the rule loads. A deliberately-failing Job in scrap-backup makes
# kube_job_status_failed go positive, which BackupJobFailed
# (platform/observability-config/baseline-alerts.yaml) already watches
# for. Its `for: 5m` is the real, shipped rule -- this waits out the real
# window rather than shortcutting it with a test-only rule.
FAIL_JOB="t-a-alert-trigger-$(date +%s)"
cat <<EOF | kc apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $FAIL_JOB
  namespace: scrap-backup
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: fail
          image: busybox:1.37.0
          command: ["false"]
EOF

# A single port-forward from this host, polled repeatedly -- not a fresh
# in-cluster pod per poll (verified during development that spinning up a
# pod per iteration made the pod-lifecycle overhead dominate the loop).
# Filter syntax (a quoted label matcher, not a bare "name=value") verified
# directly against a live Alertmanager: an unquoted filter is accepted
# without error but silently matches nothing, which would have made this
# check impossible to fail -- worth being exact about.
kc port-forward -n monitoring svc/alertmanager-operated 9093:9093 >/tmp/t-a-portforward.log 2>&1 &
PF_PID=$!
sleep 3

alert_result=""
echo "      waiting up to 7 minutes for BackupJobFailed to transition to firing (its rule requires 'for: 5m')..."
for i in $(seq 1 84); do
    firing=$(curl -sG --max-time 5 "http://127.0.0.1:9093/api/v2/alerts" \
        --data-urlencode 'filter=alertname="BackupJobFailed"' 2>/dev/null || true)
    if echo "$firing" | grep -q '"state":"active"'; then
        alert_result=ok
        break
    fi
    sleep 5
done
kill "$PF_PID" 2>/dev/null || true

if [ "$alert_result" = ok ]; then
    ok T-A/alert-reaches-surface "BackupJobFailed fired and reached Alertmanager for the deliberately-failed job"
else
    fail T-A/alert-reaches-surface "BackupJobFailed never reached firing state in Alertmanager within 7 minutes"
fi
kc delete job -n scrap-backup "$FAIL_JOB" --ignore-not-found >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "T-A: Phase 4/4: result"
if [ "$status" -ne 0 ]; then
    echo "T-A FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A PASSED -- clean-host bootstrap, all postconditions verified."
