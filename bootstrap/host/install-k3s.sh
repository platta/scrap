#!/bin/sh
# Installs a pinned k3s server. --disable=traefik is load-bearing: SCRAP
# manages its own Traefik via Flux (platform/ingress/), and k3s bundling a
# second, un-GitOps'd Traefik would mean two reconcilers fighting over the
# same Gateway API resources. See platform/ingress/README.md.
#
# Version pinned exactly, matching platform/ingress/'s own Kubernetes
# assumptions -- verified against this exact version during this
# repository's own scratch validation, not a guess.
#
# REAL DEFECT, found via independent review of PLAT-37's own UPS work and
# confirmed against upstream Kubernetes documentation
# (kubernetes.io/docs/concepts/cluster-administration/node-shutdown/):
# kubelet's Graceful Node Shutdown feature gate has been enabled by
# default since Kubernetes v1.21, but the feature itself does nothing
# unless shutdownGracePeriod/shutdownGracePeriodCriticalPods are
# explicitly set to non-zero values -- both default to 0, which the
# upstream docs state plainly does NOT activate the functionality. Before
# this fix, this script installed k3s with neither configured, so
# capabilities/ups/'s own SHUTDOWNCMD (a real `shutdown -h`, per
# docs/decisions/0013-ups-shutdown-authority.md) reached a kubelet with no
# pod-eviction-on-shutdown behavior armed at all -- stateful workloads got
# whatever k3s's own service-stop sequence happened to do, never the
# priority-ordered, grace-period-respecting termination ADR-0013 requires
# and capabilities/ups/README.md promises. This is a property of THIS
# host's k3s/kubelet configuration, independent of whether the ups
# capability is ever enabled -- any operator-initiated `shutdown -h` on
# this single-node stack benefits from it, not just a UPS-triggered one.
#
# shutdownGracePeriod=30s / shutdownGracePeriodCriticalPods=10s matches
# the exact worked example in the upstream docs above (20s for ordinary
# pods, the remaining 10s reserved for critical pods) -- a documented,
# non-arbitrary starting point, not a guess.
set -eu

K3S_VERSION="${K3S_VERSION:-v1.36.3+k3s1}"

if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "k3s is already active on this host -- refusing to reinstall over a running cluster."
    echo "If you intend to rebuild from scratch, uninstall first: sudo /usr/local/bin/k3s-uninstall.sh"
    exit 1
fi

# The upstream docs' own caution: Debian's `unattended-upgrades` package
# ships a systemd-logind drop-in capping the delay any inhibitor lock can
# hold shutdown for (InhibitDelayMaxSec) at a value that can be lower than
# whatever shutdownGracePeriod is configured above -- if that ceiling is
# lower, systemd proceeds with the actual shutdown once it's reached
# regardless of whether kubelet's own grace period has elapsed, silently
# truncating the window this fix exists to provide. Rather than assume
# this host's distribution default is high enough (unverified, and this
# repository's own instructions require evidence over assumption), set it
# explicitly to a value that comfortably covers the configured
# shutdownGracePeriod above, so the two are never in tension regardless of
# what the distribution shipped.
echo "Writing /etc/systemd/logind.conf.d/90-scrap-graceful-shutdown.conf (InhibitDelayMaxSec=45s, covering kubelet's own 30s shutdownGracePeriod)..."
mkdir -p /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/90-scrap-graceful-shutdown.conf <<'EOF'
# Written by bootstrap/host/install-k3s.sh -- see that script's own
# comment for why this exists alongside kubelet's --kubelet-arg
# shutdown-grace-period settings.
[Login]
InhibitDelayMaxSec=45
EOF
systemctl restart systemd-logind

# REAL SECURITY DEFECT, found via an independent review, confirmed by
# direct inspection: this line USED to also pass
# --write-kubeconfig-mode=644, making /etc/rancher/k3s/k3s.yaml -- a
# credential granting full cluster-admin access -- world-READABLE on
# this host, with no comment or reasoning given for why. Checked every
# place this file is actually read: bootstrap/install.sh and
# bootstrap/postflight.sh both run entirely as root (every caller
# invokes install.sh under `sudo`), and tests/profiles/lib.sh's own
# setup_kubeconfig() reads it via `sudo cp` -- root, either way. Nothing
# in this codebase ever needs a non-root, unprivileged read of this
# specific file; the loosened mode served no purpose here and directly
# contradicted lib.sh's own comment describing this file as "(0600,
# root-owned)". Removed -- k3s's own default (600, root-only) is what
# every caller already assumes and is now what's actually true.
echo "Installing k3s ${K3S_VERSION} (--disable=traefik, graceful node shutdown armed)..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
    --disable=traefik \
    --kubelet-arg=shutdown-grace-period=30s \
    --kubelet-arg=shutdown-grace-period-critical-pods=10s

echo "Waiting for the node to report Ready..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
node_ready=""
for i in $(seq 1 30); do
    if kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1; then
        echo "Node Ready."
        kubectl get nodes -o wide
        node_ready=1
        break
    fi
    sleep 2
done

if [ -z "$node_ready" ]; then
    echo "Node did not report Ready within the expected window -- check 'kubectl get nodes' and"
    echo "'journalctl -u k3s' for details."
    exit 1
fi

# Verify the graceful-shutdown configuration above actually took, live --
# not just that the install command exited 0. kubelet's own node-shutdown
# manager only registers a real systemd-logind delay inhibitor (mode
# "delay", what "shutdown") for as long as it is running WITH a non-zero
# shutdownGracePeriod -- its absence is exactly the silent-no-op failure
# mode this fix exists to close (a wrong or ignored --kubelet-arg would
# leave the node reporting Ready with no error, masking the defect).
echo "Verifying kubelet's graceful node shutdown manager is genuinely armed (a live systemd-logind delay inhibitor for shutdown)..."
i=0
inhibitor_found=""
while [ "$i" -lt 15 ]; do
    if loginctl list-inhibitors --no-legend 2>/dev/null | awk '/shutdown/ && /delay/' | grep -q .; then
        inhibitor_found=1
        break
    fi
    sleep 2
    i=$((i + 1))
done
if [ -n "$inhibitor_found" ]; then
    echo "ok: a real 'shutdown'/'delay' inhibitor is held -- kubelet's graceful node shutdown is live, not just configured on paper."
    loginctl list-inhibitors
else
    echo "kubelet never registered a 'shutdown'/'delay' inhibitor lock -- graceful node shutdown is NOT"
    echo "actually active despite the --kubelet-arg flags above. Check 'loginctl list-inhibitors' and"
    echo "'journalctl -u k3s' for details; this must not be silently ignored, since it means"
    echo "docs/decisions/0013-ups-shutdown-authority.md's clean-termination requirement does not hold"
    echo "on this host."
    exit 1
fi
