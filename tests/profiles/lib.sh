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
# (see the commit this comment shipped in for the full writeup): under
# `sudo -E`, HOME stays the invoking user's ("runner" in CI) but the
# process runs as root -- and a newer kubectl's "kuberc" preferences
# feature tries to read $HOME/.kube/kuberc unconditionally, fails with
# "permission denied" (root can't read another user's file there in
# this environment), and -- confirmed live, reproduced 3/3 -- `kubectl
# wait` specifically then fails its OWN argument parsing right
# afterward ("error: pod, type/name or --filename must be specified"),
# even though a perfectly valid resource type and selector were given.
# That failure was silently swallowed by this project's own `|| true`
# on every `kc wait` call, so neither the scale-to-zero wait nor the
# scale-back-up wait was ever actually happening -- the two pods raced
# on the same PVC, and restic's genuinely-correct restore lost the race
# against the still-terminating old pod often enough to look like a
# nondeterministic test flake.
#
# First attempt at a fix (KUBECTL_KUBERC=false, kubectl's own documented
# feature-gate) was verified against a vanilla upstream kubectl v1.36.0
# binary locally and DID suppress the kuberc read there -- but did NOT
# suppress it live, 3/3 again, against this environment's actual
# k3s-bundled kubectl ("v1.36.3+k3s1"). k3s vendors its own build; this
# project doesn't control or fully know that build's exact feature-gate
# wiring, so this fix doesn't depend on it at all. Overriding HOME to
# root's own (which the process is actually running as) addresses the
# real structural mismatch directly: kubectl finds no kuberc file at
# /root/.kube/kuberc (root's own home has none, and never will unless
# something puts one there), which is a normal, silent, error-free case
# for every kubectl build, upstream or vendored -- not a feature this
# project has to trust stays implemented a particular way.
kc() { sudo -E env HOME=/root KUBECTL_KUBERC=false kubectl "$@"; }

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
