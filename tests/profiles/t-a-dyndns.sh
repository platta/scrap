#!/bin/sh
# T-A-dyndns -- live acceptance for capabilities/dyndns/.
#
# Same expectations as tests/profiles/t-a-minimal.sh: a normal user,
# passwordless sudo, a genuinely fresh host, never run this whole script
# under `sudo` itself. A SEPARATE from-zero bootstrap from T-A's own,
# same reasoning as T-B's, T-A-public-tls's, T-A-offsite-backup's, and
# T-A-alert-heartbeat's -- this live-edits SOPS-encrypted secrets and
# deliberately sends a wrong-credential DNS update; it must never run
# against a cluster some other check still depends on.
#
# BOTH externally-facing dependencies this capability has -- the
# authoritative nameserver and the IP-lookup endpoint -- are REAL,
# ephemeral services this script stands up itself on the same runner, the
# same "genuine wire protocol, no mock, no external account" shape
# t-a-offsite-backup.sh's own MinIO instance and t-a-alert-heartbeat.sh's
# own HTTP receiver already establish. Unlike capabilities/public-tls/'s
# own live test -- structurally bounded to ACME's Order stage because a
# real DNS-01 Challenge needs a real public domain -- this capability's
# entire mechanism is provable end-to-end without any external service at
# all, because RFC2136 update traffic never has to reach one specific,
# mandatory third party the way ACME has to reach Let's Encrypt. A human
# can run this identically on their own scratch VM, given python3 on
# PATH: sh tests/profiles/t-a-dyndns.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTANCE_CONFIG="$REPO_ROOT/clusters/example/instance-config.yaml"
# shellcheck source=tests/profiles/lib.sh
. "$SCRIPT_DIR/lib.sh"

status=0

# REAL BUG class this project has already found twice at this exact
# choice (t-a-offsite-backup.sh, t-a-alert-heartbeat.sh's own identical
# comments) -- stay well clear of platform/ingress/reserved-ports.yaml's
# own reserved range (80/443/6443/9000) and of the other live profiles'
# own ephemeral ports (19000, 19100). These profiles never run
# concurrently against the SAME runner today, but there's no reason to
# depend on that.
BIND_PORT=15353
ECHO_PORT=15380
BIND_DIR=/tmp/t-a-dyndns-bind
mkdir -p "$BIND_DIR"
ZONE="dyndns-test.internal"
RECORD="host.${ZONE}"
TSIG_KEY_NAME="t-a-dyndns-test-key"
TSIG_SECRET=$(openssl rand -base64 32)
IP_INITIAL="203.0.113.1"
IP_ONE="203.0.113.77"
IP_TWO="203.0.113.88"
BIND_LOG=/tmp/t-a-dyndns-named.log
IPFILE=/tmp/t-a-dyndns-current-ip.txt

# ---------------------------------------------------------------------------
log "T-A-dyndns: Phase 0/5: environment prerequisites"
install_prereqs
if ! command -v named >/dev/null 2>&1; then
    apt_install bind9
fi
if ! command -v dig >/dev/null 2>&1; then
    apt_install dnsutils
fi
if ! command -v openssl >/dev/null 2>&1; then
    apt_install openssl
fi

# ---------------------------------------------------------------------------
log "T-A-dyndns: Phase 1/5: two real, ephemeral services -- an authoritative nameserver and an IP-lookup endpoint"

# The IP-lookup endpoint: a real HTTP server whose response body is
# whatever this script last wrote to $IPFILE -- lets later phases change
# "the current public IP" the CronJob observes without restarting the
# server, the exact contract capabilities/dyndns/README.md documents
# (DYNDNS_IP_LOOKUP_URL: an endpoint whose entire response body is a bare
# IPv4 address).
echo "$IP_INITIAL" > "$IPFILE"
cat > /tmp/t-a-dyndns-echo.py <<'PYEOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ipfile, port = sys.argv[1], int(sys.argv[2])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(ipfile) as f:
            body = f.read().strip().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        pass

HTTPServer(("0.0.0.0", port), Handler).serve_forever()
PYEOF
nohup python3 /tmp/t-a-dyndns-echo.py "$IPFILE" "$ECHO_PORT" >/tmp/t-a-dyndns-echo.log 2>&1 &
ECHO_PID=$!

# The authoritative nameserver: a real, disposable BIND9 instance,
# authoritative for one throwaway zone, with a real TSIG key generated
# fresh for this run and an allow-update ACL scoped to it -- the same
# RFC2136 mechanism capabilities/public-tls/'s own DNS-01 solver and this
# capability's own cronjob.yaml speak, never a mock DNS server.
cat > "$BIND_DIR/named.conf" <<EOF
options {
    directory "$BIND_DIR";
    listen-on port $BIND_PORT { 0.0.0.0; };
    listen-on-v6 { none; };
    allow-query { any; };
    allow-transfer { none; };
    recursion no;
    pid-file "$BIND_DIR/named.pid";
    # Both harmless-but-noisy by default: named's stock config normally
    # points these at /run/named/ and /etc/bind/, both root/bind-owned
    # and unreadable/unwritable by this unprivileged runner user. Neither
    # is needed here -- this test never uses rndc, and the session key
    # is only for nsupdate's own local-session convenience mode, not the
    # real RFC2136 TSIG path this capability's own cronjob.yaml uses.
    session-keyfile "$BIND_DIR/session.key";
};
controls { };

key "$TSIG_KEY_NAME" {
    algorithm hmac-sha256;
    secret "$TSIG_SECRET";
};

zone "$ZONE" {
    type master;
    file "$BIND_DIR/db.zone";
    allow-update { key "$TSIG_KEY_NAME"; };
};
EOF

# REAL BUG, found live via this script's own first CI run: an NS record
# naming a name INSIDE the zone it delegates ("ns.$ZONE") needs a glue A
# record for that same name, or BIND's default check-integrity refuses
# to load the zone at all ("has no address records (A or AAAA)") --
# nothing ever queries ns.$ZONE directly in this test, but the zone
# can't load without it regardless.
cat > "$BIND_DIR/db.zone" <<EOF
\$TTL 300
@ IN SOA ns.$ZONE. admin.$ZONE. ( 1 3600 900 604800 300 )
@ IN NS ns.$ZONE.
ns IN A 127.0.0.1
host IN A $IP_INITIAL
EOF

# REAL BUG, found live via this script's own first CI run: Ubuntu's
# bind9 package ships an AppArmor profile (usr.sbin.named) confining the
# named binary to a fixed set of paths (/etc/bind/, /var/lib/bind/,
# /var/cache/bind/, ...) -- it does NOT include /tmp, so named failed
# outright ("open: .../named.conf: permission denied") despite completely
# ordinary Unix file permissions; the process's own uid genuinely owned
# and could read the file, AppArmor's mandatory access control simply
# doesn't consult ownership at all. Unloading this one profile (never a
# system-wide AppArmor disable) is the direct, structural fix -- `|| true`
# since a non-Ubuntu runner, or one without AppArmor at all, has nothing
# to unload here.
if [ -f /etc/apparmor.d/usr.sbin.named ]; then
    sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.named 2>/dev/null || true
fi

nohup named -c "$BIND_DIR/named.conf" -g >"$BIND_LOG" 2>&1 &
NAMED_PID=$!

nameserver_up=""
i=0
while [ "$i" -lt 20 ]; do
    if dig @127.0.0.1 -p "$BIND_PORT" +short +time=2 +tries=1 "$ZONE" SOA >/dev/null 2>&1; then
        nameserver_up=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ -z "$nameserver_up" ]; then
    echo "FAIL  T-A-dyndns: the ephemeral nameserver never came up -- see $BIND_LOG"
    cat "$BIND_LOG" 2>/dev/null || true
    exit 1
fi
echo "ephemeral nameserver up (pid $NAMED_PID) on port $BIND_PORT, echo endpoint up (pid $ECHO_PID) on port $ECHO_PORT"

# ---------------------------------------------------------------------------
log "T-A-dyndns: Phase 2/5: bootstrap/install.sh -- the real, unmodified installer"
export SCRAP_ESCROW_CONFIRMED=1
cd "$REPO_ROOT"
if ! sudo -E env HOME=/root sh bootstrap/install.sh; then
    echo
    echo "FAIL  T-A-dyndns: bootstrap/install.sh exited non-zero -- see the 'Step N/7'"
    echo "      marker above for which layer of the documented bootstrap sequence failed."
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
    ok T-A-dyndns/kustomizations-ready-baseline "every Flux Kustomization is Ready before dyndns is enabled"
else
    fail T-A-dyndns/kustomizations-ready-baseline "not Ready: $not_ready"
fi

NODE_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

# ---------------------------------------------------------------------------
log "T-A-dyndns: Phase 3/5: enable dyndns live -- exactly the documented two-file copy"
BARE_REPO=/var/lib/scrap/repo.git
LIVEDIR=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR"
LIVE_CLUSTER_DIR="$LIVEDIR/clusters/example"

mkdir -p "$LIVE_CLUSTER_DIR/capabilities"
cp "$REPO_ROOT/capabilities/dyndns/cluster-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/dyndns.yaml"
cp "$REPO_ROOT/capabilities/dyndns/cluster-secrets-kustomization.yaml" \
    "$LIVE_CLUSTER_DIR/capabilities/dyndns-secrets.yaml"

sed -i "s|^\(  DYNDNS_HOSTNAME: \).*|\1\"$RECORD\"|" "$LIVE_CLUSTER_DIR/instance-config.yaml"
sed -i "s|^\(  DYNDNS_NAMESERVER: \).*|\1\"${NODE_IP}:${BIND_PORT}\"|" "$LIVE_CLUSTER_DIR/instance-config.yaml"
sed -i "s|^\(  DYNDNS_TSIG_KEY_NAME: \).*|\1\"$TSIG_KEY_NAME\"|" "$LIVE_CLUSTER_DIR/instance-config.yaml"
sed -i "s|^\(  DYNDNS_IP_LOOKUP_URL: \).*|\1\"http://${NODE_IP}:${ECHO_PORT}/\"|" "$LIVE_CLUSTER_DIR/instance-config.yaml"

# Root-only (the operational age key install.sh generated lives at
# /etc/scrap/age/, mode 600) -- same reasoning t-a-offsite-backup.sh's
# own EDIT_SCRIPT gives for using a temp script file, not an inline
# `sudo sh -c` string, to avoid a nested-quoting hazard around the secret.
EDIT_SCRIPT=$(mktemp)
cat > "$EDIT_SCRIPT" <<EOF
set -eu
cd '$LIVE_CLUSTER_DIR/secrets'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops --set '["stringData"]["TSIG_SECRET"] "$TSIG_SECRET"' dyndns/dyndns-credentials.sops.yaml
EOF
if ! sudo sh "$EDIT_SCRIPT"; then
    echo "FAIL  T-A-dyndns: could not set TSIG_SECRET in the live secret"
    rm -f "$EDIT_SCRIPT"
    exit 1
fi
rm -f "$EDIT_SCRIPT"

( cd "$LIVEDIR" && git add -A && git -c user.email=t-a-dyndns@localhost -c user.name="T-A-dyndns" \
    commit -q -m "T-A-dyndns: enable dyndns against the ephemeral nameserver" && \
    git push -q origin main )
rm -rf "$LIVEDIR"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization capabilities --with-source >/dev/null
# dyndns(-secrets) are newly-created nested Kustomizations as of the
# commit above -- same reasoning t-a-public-tls.sh's own identical
# comment gives for the short sleep before reconciling brand-new-by-name
# objects.
sleep 5
flux reconcile kustomization dyndns --with-source >/dev/null 2>&1 || true
flux reconcile kustomization dyndns-secrets --with-source >/dev/null 2>&1 || true
flux reconcile kustomization dyndns --with-source >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "T-A-dyndns: Phase 4/5: postconditions"

# 4a. Both new Kustomizations (and everything else) reach Ready. Same
# retry-loop shape t-a-alert-heartbeat.sh's own identical comment
# explains (a whole-tree reconcile can transiently flip an unrelated
# Kustomization's own Ready condition while Flux re-evaluates it).
not_ready=""
i=0
while [ "$i" -lt 12 ]; do
    not_ready=$(kc get kustomizations -A -o json | jq -r '
        .items[] |
        (.status.conditions // [] | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
        select($ready != "True") |
        "\(.metadata.namespace)/\(.metadata.name) (ready=\($ready))"
    ')
    [ -z "$not_ready" ] && break
    sleep 5
    i=$((i + 1))
done
if [ -z "$not_ready" ]; then
    ok T-A-dyndns/kustomizations-ready "every Flux Kustomization is Ready, including dyndns(-secrets)"
else
    fail T-A-dyndns/kustomizations-ready "not Ready: $not_ready"
fi

# 4b. Structural ground truth: the CronJob and its own Namespace exist,
# applied by this capability's own Kustomization, and it makes no
# Kubernetes API call of its own.
cj_name=$(kc get cronjob -n dyndns scrap-dyndns -o jsonpath='{.metadata.name}' 2>/dev/null || true)
automount=$(kc get cronjob -n dyndns scrap-dyndns -o jsonpath='{.spec.jobTemplate.spec.template.spec.automountServiceAccountToken}' 2>/dev/null || true)
if [ "$cj_name" = "scrap-dyndns" ] && [ "$automount" = "false" ]; then
    ok T-A-dyndns/cronjob-exists "the scrap-dyndns CronJob exists in its own dyndns namespace, applied by capabilities/dyndns/'s own Kustomization, with automountServiceAccountToken: false"
else
    fail T-A-dyndns/cronjob-exists "expected the scrap-dyndns CronJob with automountServiceAccountToken=false, got name='$cj_name' automount='$automount'"
    kc describe cronjob -n dyndns scrap-dyndns 2>&1 | sed 's/^/      /' || true
fi

query_record() {
    dig @127.0.0.1 -p "$BIND_PORT" +short +time=3 +tries=2 "$RECORD" A | tail -n1
}

# 4c. POSITIVE: a manually triggered run genuinely updates the A record
# to the current public IP, confirmed by an independent dig query this
# script issues itself against the nameserver directly -- never inferred
# from the Job's own exit status alone.
echo "$IP_ONE" > "$IPFILE"
POS_JOB="t-a-dyndns-pos-$(date +%s)"
kc create job -n dyndns "$POS_JOB" --from=cronjob/scrap-dyndns >/dev/null
pos_result=$(wait_for_job dyndns "$POS_JOB" 24)
echo "      --- dyndns job log (positive: IP changed to $IP_ONE) ---"
kc logs -n dyndns "job/$POS_JOB" 2>&1 | sed 's/^/      /' || true
pos_record=$(query_record)
if [ "$pos_result" = ok ] && [ "$pos_record" = "$IP_ONE" ]; then
    ok T-A-dyndns/update-applies "a triggered run with a genuinely changed public IP sent a real RFC2136 update -- the nameserver's own fresh answer now reads $pos_record, confirmed independently, not inferred from job status alone"
else
    fail T-A-dyndns/update-applies "expected the job to succeed and the record to become $IP_ONE (job result=$pos_result, record=$pos_record)"
fi

# 4d. UNCHANGED-IP PATH: a second triggered run with nothing changed
# makes no update attempt at all -- proving the "only update if the IP
# actually changed" logic is genuine, not merely documented. Checked via
# the job's own log text (it must say so) and that the record is still
# exactly what it was, never touched again.
UNCHANGED_JOB="t-a-dyndns-unchanged-$(date +%s)"
kc create job -n dyndns "$UNCHANGED_JOB" --from=cronjob/scrap-dyndns >/dev/null
unchanged_result=$(wait_for_job dyndns "$UNCHANGED_JOB" 24)
unchanged_log=$(kc logs -n dyndns "job/$UNCHANGED_JOB" 2>&1)
echo "      --- dyndns job log (unchanged IP) ---"
echo "$unchanged_log" | sed 's/^/      /'
unchanged_record=$(query_record)
if [ "$unchanged_result" = ok ] && [ "$unchanged_record" = "$IP_ONE" ] && echo "$unchanged_log" | grep -q "no update needed"; then
    ok T-A-dyndns/skips-when-unchanged "a triggered run with the public IP unchanged genuinely sent no update (the job's own log says so, and the record is still $unchanged_record)"
else
    fail T-A-dyndns/skips-when-unchanged "expected the job to succeed, log 'no update needed', and record unchanged at $IP_ONE (result=$unchanged_result, record=$unchanged_record)"
fi

# 4e. NEGATIVE CONTROL: a deliberately wrong TSIG secret, with a
# genuinely different IP presented to the job, must fail visibly AND
# leave the record untouched -- not merely a stale-looking success. Same
# "verified, not assumed" standard capabilities/dyndns/README.md's own
# "why the update is verified, not merely sent" section describes.
echo "$IP_TWO" > "$IPFILE"
LIVEDIR3=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR3"
EDIT_SCRIPT2=$(mktemp)
cat > "$EDIT_SCRIPT2" <<EOF
set -eu
cd '$LIVEDIR3/clusters/example/secrets'
export SOPS_AGE_KEY_FILE='/etc/scrap/age/operational.agekey'
sops --set '["stringData"]["TSIG_SECRET"] "deliberately-wrong-tsig-secret-not-real"' dyndns/dyndns-credentials.sops.yaml
EOF
sudo sh "$EDIT_SCRIPT2"
rm -f "$EDIT_SCRIPT2"
( cd "$LIVEDIR3" && git add -A && git -c user.email=t-a-dyndns@localhost -c user.name="T-A-dyndns" \
    commit -q -m "T-A-dyndns: negative control -- deliberately wrong TSIG secret" && git push -q origin main )
rm -rf "$LIVEDIR3"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization dyndns-secrets --with-source >/dev/null 2>&1 || true
# The Secret's own new value must actually be live before triggering the
# job -- poll rather than assume the reconcile above already settled it.
i=0
secret_updated=""
while [ "$i" -lt 12 ]; do
    live_secret=$(kc get secret -n dyndns dyndns-credentials -o jsonpath='{.data.TSIG_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)
    [ "$live_secret" = "deliberately-wrong-tsig-secret-not-real" ] && { secret_updated=1; break; }
    sleep 3
    i=$((i + 1))
done
if [ -z "$secret_updated" ]; then
    fail T-A-dyndns/negative-setup "the deliberately-wrong TSIG secret never became live -- can't run the negative control without it"
fi

NEG_JOB="t-a-dyndns-neg-$(date +%s)"
kc create job -n dyndns "$NEG_JOB" --from=cronjob/scrap-dyndns >/dev/null
neg_result=$(wait_for_job dyndns "$NEG_JOB" 24)
echo "      --- dyndns job log (negative control: wrong TSIG secret) ---"
kc logs -n dyndns "job/$NEG_JOB" 2>&1 | sed 's/^/      /' || true
neg_record=$(query_record)
if [ "$neg_result" = fail ] && [ "$neg_record" = "$IP_ONE" ]; then
    ok T-A-dyndns/rejects-wrong-credential "a triggered run with a deliberately wrong TSIG secret genuinely failed (Job status Failed), and the nameserver's own record is still $neg_record -- the wrong-credential update was genuinely rejected, not silently accepted or partially applied"
else
    fail T-A-dyndns/rejects-wrong-credential "expected the job to FAIL and the record to remain $IP_ONE (result=$neg_result, record=$neg_record)"
fi

# 4f. Revert: confirm T1 -- the objects this capability owned are gone,
# nothing else is affected.
LIVEDIR4=$(mktemp -d)
git clone -q "$BARE_REPO" "$LIVEDIR4"
rm -f "$LIVEDIR4/clusters/example/capabilities/dyndns.yaml" \
      "$LIVEDIR4/clusters/example/capabilities/dyndns-secrets.yaml"
( cd "$LIVEDIR4" && git add -A && git -c user.email=t-a-dyndns@localhost -c user.name="T-A-dyndns" \
    commit -q -m "T-A-dyndns: revert -- delete dyndns's files" && git push -q origin main )
rm -rf "$LIVEDIR4"

flux reconcile source git flux-system >/dev/null
flux reconcile kustomization flux-system --with-source >/dev/null
flux reconcile kustomization capabilities --with-source >/dev/null 2>&1 || true

reverted=""
i=0
while [ "$i" -lt 24 ]; do
    cj_exists=$(kc get cronjob -n dyndns scrap-dyndns -o name 2>/dev/null || true)
    ns_exists=$(kc get namespace dyndns -o name 2>/dev/null || true)
    ks1_exists=$(kc get kustomization -n flux-system dyndns -o name 2>/dev/null || true)
    ks2_exists=$(kc get kustomization -n flux-system dyndns-secrets -o name 2>/dev/null || true)
    if [ -z "$cj_exists" ] && [ -z "$ns_exists" ] && [ -z "$ks1_exists" ] && [ -z "$ks2_exists" ]; then
        reverted=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$reverted" = 1 ]; then
    ok T-A-dyndns/reverts-cleanly "deleting dyndns's files pruned the CronJob, its own Namespace, and both Kustomization objects -- T1 holds"
else
    fail T-A-dyndns/reverts-cleanly "expected the CronJob, the dyndns Namespace, and both Kustomizations to be gone after reverting"
fi

kill "$NAMED_PID" 2>/dev/null || true
kill "$ECHO_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
log "T-A-dyndns: result"
if [ "$status" -ne 0 ]; then
    echo "T-A-dyndns FAILED -- see the FAIL markers above for which postcondition(s) failed."
    exit 1
fi
echo "T-A-dyndns PASSED -- a real RFC2136 update genuinely repoints an A record against a real ephemeral authoritative nameserver, confirmed independently, not inferred from job status; the unchanged-IP path genuinely sends no update; a deliberately wrong TSIG credential is genuinely rejected and the record stays untouched; the capability reverts cleanly -- all verified live, never a mock."
