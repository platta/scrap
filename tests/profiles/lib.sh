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
        sudo apt-get update -qq
        sudo apt-get install -y -qq age >/dev/null
    fi
    if ! command -v sops >/dev/null 2>&1; then
        SOPS_VERSION=v3.9.4
        curl -sfLo /tmp/sops.deb "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops_${SOPS_VERSION#v}_amd64.deb"
        sudo dpkg -i /tmp/sops.deb >/dev/null
        rm -f /tmp/sops.deb
    fi
    if ! command -v ss >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq iproute2 >/dev/null
    fi
    if ! command -v nc >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq netcat-openbsd >/dev/null
    fi
    if ! command -v jq >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq jq >/dev/null
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
