# tests/profiles/lib.sh -- shared mechanics for tests/profiles/*.sh.
#
# Sourced by each profile script (". \"$SCRIPT_DIR/lib.sh\""), never run on
# its own. Holds only genuinely shared plumbing: ok/fail output shape, the
# instance-config reader, prerequisite installation, a kubectl-under-sudo
# shorthand, and the create-job/poll-for-terminal-state pattern every
# profile needs at least once. What each profile is actually proving stays
# in that profile's own script -- factoring THAT out would blur which
# script is responsible for which claim. Anything specific to one
# profile's own subject matter (identity login mechanics, restic path
# translation) stays local to that script, even if it looks reusable in
# the abstract -- see tests/profiles/t-b-standard.sh's own login helper
# for why that one deliberately isn't here.
#
# Every caller must `set -eu` itself, and define REPO_ROOT and
# INSTANCE_CONFIG before sourcing this file.

# REAL BUG, root-caused via the §T-A-destructive-restore investigation
# (see the commit this comment first shipped in, and the two that
# followed it correcting it, for the full writeup -- this is the third
# and structurally final version). Under `sudo -E kubectl`, HOME stays
# the invoking user's ("runner" in CI) but the process runs as root --
# and a newer kubectl's "kuberc" preferences feature tries to read
# $HOME/.kube/kuberc unconditionally, fails with "permission denied"
# (root can't read another user's file there), and -- confirmed live,
# reproduced repeatedly -- `kubectl wait` specifically can then fail
# its own argument parsing right afterward ("error: pod, type/name or
# --filename must be specified") despite a perfectly valid resource
# type and selector, SOMETIMES without even returning a nonzero exit
# code (confirmed live: one run's scale-down wait hit this and still
# reported success, having genuinely waited for nothing). That
# unreliable exit code is what sank the second attempt at this fix
# (overriding HOME=/root for the sudo'd process): even verified-correct
# on its own, an explicit `if kc wait; then ... else ...` check can't
# detect a failure kubectl itself doesn't reliably surface. Trying to
# out-guess exactly which kubectl code path does or doesn't touch
# kuberc isn't a sound foundation for a fix.
#
# This version removes the actual precondition for all of the above:
# root privilege was never needed for kubectl itself -- only to read
# the k3s-generated kubeconfig (0600, root-owned). setup_kubeconfig()
# below copies it once to a path this user owns, so kc() runs kubectl
# as this same unprivileged user throughout: HOME is genuinely this
# user's own home, matches the effective UID, and kuberc's own file
# read (if it even fires) targets a path this process can actually
# read -- not a workaround for a specific kubectl behavior, but the
# removal of the mismatch that made any of those behaviors reachable.
kc() { kubectl "$@"; }

# Copies the root-owned k3s kubeconfig to a location this user owns and
# points KUBECONFIG at it -- see kc()'s own comment for why. Call once,
# right after KUBECONFIG would otherwise have been set to the raw
# /etc/rancher/k3s/k3s.yaml path.
setup_kubeconfig() {
    sudo cp /etc/rancher/k3s/k3s.yaml /tmp/t-profile-kubeconfig
    sudo chown "$(id -u):$(id -g)" /tmp/t-profile-kubeconfig
    chmod 600 /tmp/t-profile-kubeconfig
    export KUBECONFIG=/tmp/t-profile-kubeconfig
}

log() { echo; echo "=== $*"; }
ok()   { echo "ok    $1: $2"; }
fail() { echo "FAIL  $1: $2"; status=1; }

# Minimal, dependency-free extraction from an instance-config.yaml --
# matches bootstrap/preflight/check-ports.sh's own style for
# reserved-ports.yaml, since a genuinely fresh host may not have a real
# YAML parser available this early in the sequence.
cfg_value() {
    awk -v k="$1" '$0 ~ "^  "k":" {
        sub("^  "k": *", ""); gsub(/"/, ""); print; exit
    }' "$INSTANCE_CONFIG"
}

# apt_install <package> -- REAL BUG, found live: a DR-acceptance CI run
# (tests/dr/authentik-postgres-restore.sh) hung for the ENTIRE 40-minute
# job timeout with zero diagnostic output whatsoever -- confirmed from
# the raw log: exactly one line ("Phase 0/5: environment prerequisites")
# printed, then nothing until GitHub's own "operation was canceled" kill.
# Traced to the very first statement install_prereqs() below can reach --
# a bare `sudo apt-get update -qq`, with no timeout anywhere on it. A
# stalled mirror or a network blip on the runner turns into total silence
# for the whole CI budget instead of a fast, clear failure. This function
# is shared by every profile script (T-A, T-B, and this DR rehearsal), so
# fixed here once, for all of them: apt-get itself gets a bounded
# retry/timeout via its own Acquire:: options, and the whole call is
# additionally wrapped in `timeout` as a hard backstop in case even that
# somehow doesn't bound it. A genuine failure now costs at most 150s and
# says why, instead of silently consuming the entire job.
apt_install() {
    pkg="$1"
    apt_opts="-o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20"
    if ! timeout 150 sudo apt-get $apt_opts update -qq; then
        echo "FAIL  install_prereqs: apt-get update did not complete within 150s -- likely a stalled mirror or network issue on this runner, not a SCRAP defect" >&2
        exit 1
    fi
    if ! timeout 150 sudo apt-get $apt_opts install -y -qq "$pkg" >/dev/null; then
        echo "FAIL  install_prereqs: apt-get install $pkg did not complete within 150s -- likely a stalled mirror or network issue on this runner, not a SCRAP defect" >&2
        exit 1
    fi
}

# Installs exactly what bootstrap/preflight/check-prerequisites.sh's own
# FAIL messages already tell a real operator to run, plus the handful of
# extra tools a *test harness* (not the platform itself) needs to drive
# its own checks -- nc for P4's raw-TCP round trip, jq for parsing
# Authentik's flow-executor JSON in T-B. check-prerequisites.sh itself
# fails loud rather than auto-installing, correctly, since a real operator
# should decide what lands on their own host; auto-installing here is a
# test-runner concern, not a platform one.
install_prereqs() {
    if ! command -v age-keygen >/dev/null 2>&1; then
        apt_install age
    fi
    if ! command -v sops >/dev/null 2>&1; then
        SOPS_VERSION=v3.9.4
        if ! curl -sfL --connect-timeout 15 --max-time 120 \
            -o /tmp/sops.deb "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops_${SOPS_VERSION#v}_amd64.deb"; then
            echo "FAIL  install_prereqs: could not download sops within 120s -- see the curl error above" >&2
            exit 1
        fi
        sudo dpkg -i /tmp/sops.deb >/dev/null
        rm -f /tmp/sops.deb
    fi
    if ! command -v ss >/dev/null 2>&1; then
        apt_install iproute2
    fi
    if ! command -v nc >/dev/null 2>&1; then
        apt_install netcat-openbsd
    fi
    if ! command -v jq >/dev/null 2>&1; then
        apt_install jq
    fi
}

# Poll a Job's .status.{succeeded,failed} up to $3 iterations, 5s apart
# (default 24 -> 2 minutes). Echoes "ok", "fail", or "" (timed out,
# neither set yet) to stdout -- callers capture it with $(...). Doesn't
# print logs itself: callers decide what diagnostic context matters for
# the specific claim they're checking.
wait_for_job() {
    ns="$1"; job="$2"; iterations="${3:-24}"
    result=""
    i=0
    while [ "$i" -lt "$iterations" ]; do
        s=$(kc get job -n "$ns" "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
        f=$(kc get job -n "$ns" "$job" -o jsonpath='{.status.failed}' 2>/dev/null || true)
        [ "${s:-0}" -ge 1 ] 2>/dev/null && { result=ok; break; }
        [ "${f:-0}" -ge 1 ] 2>/dev/null && { result=fail; break; }
        sleep 5
        i=$((i + 1))
    done
    echo "$result"
}

# wait_for_pod_gone / wait_for_pod_ready <namespace> <label-selector>
# [iterations, default 12 -> 60s] -- REAL BUG, root-caused via the
# T-A-destructive-restore investigation: `kubectl wait --for=delete` /
# `--for=condition=Ready` intermittently failed their OWN argument
# parsing in this environment ("error: pod, type/name or --filename
# must be specified") despite syntactically valid, correct invocations
# -- reproduced repeatedly, independent of an earlier, separate HOME/
# kuberc issue this project also found and fixed (fixing that one did
# NOT fix this one; they only looked related because they'd often
# co-occur). `kubectl wait` carries a lot of internal machinery this
# project doesn't need and evidently can't fully trust here; `kubectl
# get`, one of the simplest kubectl subcommands, has shown no
# comparable failure anywhere in this whole investigation. Polling it
# directly for the actual condition (no pods left / a pod reporting
# Ready) is the real synchronization boundary either check needs -- not
# a workaround for kubectl's own unreliability, but the removal of a
# dependency on the one subcommand that's proven unreliable here.
# Echoes "ok" or "fail" to stdout, same convention as wait_for_job.
wait_for_pod_gone() {
    ns="$1"; selector="$2"; iterations="${3:-12}"
    i=0
    while [ "$i" -lt "$iterations" ]; do
        # REAL BUG, found live via an independent review: piping
        # `kc get pods ... | wc -l` loses kubectl's OWN exit status --
        # the pipeline's exit code is wc's (always 0), not kubectl's. A
        # failed kubectl invocation (API server hiccup, RBAC error,
        # transient network issue) produces empty stdout on its own
        # `2>/dev/null`-discarded failure, which `wc -l` then reports as
        # "0 lines" -- indistinguishable from "kubectl succeeded and
        # genuinely found nothing". That let a real API failure
        # green-light "pod gone" and, downstream, a restore proceeding
        # while a pod might still actually own/use the PVC -- precisely
        # the race this helper exists to prevent. Fixed by running
        # kubectl directly in the `if` condition (no pipe to wc at all):
        # its own exit status is what gates the "ok" path now, so a
        # failure is treated as inconclusive (retry), never as
        # confirmation.
        if output=$(kc get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null); then
            if [ -z "$output" ]; then
                echo ok
                return 0
            fi
        fi
        sleep 5
        i=$((i + 1))
    done
    echo fail
}

wait_for_pod_ready() {
    ns="$1"; selector="$2"; iterations="${3:-12}"
    i=0
    while [ "$i" -lt "$iterations" ]; do
        ready=$(kc get pods -n "$ns" -l "$selector" \
            -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        [ "$ready" = "True" ] && { echo ok; return 0; }
        sleep 5
        i=$((i + 1))
    done
    echo fail
}
